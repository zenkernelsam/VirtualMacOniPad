# VirtualMacOniPad：VM 崩溃修复 & macOS 15 构建踩坑笔记

> 适用：本 fork（HEAD = `046abc6` "Update 1.2.3"），目标设备 iPad Pro 11" M1 / iPadOS 16.3。
> 目的：记录"Qoder CN 导致虚拟机崩溃"的根因与修复，以及在一台 **macOS 15.6.1** 上从零构建 deb 的全部坑与绕过方法。
> 读者：未来的自己 / 其他 Agent（不依赖 Qoder 记忆系统也能复原全部经验）。

---

## 0. 结论速览

- **崩溃根因（A/B 两类同源）**：`vz/host/pvg_trace.m` 里被项目接管的 `-[PGTask mappedAddressForOffset:length:]`（`SegmentedMappedAddressForOffset`）在分段任务翻译失败时**回退到 Apple 原生 `base+offset`**（基于"缩小前"的预约），返回了错误/未映射的宿主地址。
- **修复**：该钩子改用 `create=YES` + 返回前做"已映射宿主区间"覆盖校验 + 无法满足时安全失败（抛 PG 同款异常），不再回退裸 `base+offset`。
- **构建最大坑**：在 macOS 15 上，重建出的 Mach-O 的 chained fixups 会被 Apple 的 `dyld_info`/`ld` 拒绝；且 `vz/uncache.py` 的符号解析**必须用 `.a2s` 缓存**才能与官方逐字节一致，否则会重建出"坏框架"导致 **App 点启动 VM 立刻闪退**。
- **产物**：`VirtualMac/build/release/VirtualMac_1.2.3_046abc6e0a.deb`（`Version: 2:1.2.3+608.vmfix1`）。

---

## 1. 问题与现象

- 客机 macOS 里运行 **Qoder CN（Electron/Chromium）**：CPU 满载，随后 **虚拟机崩溃**（`VZErrorDomain Code=1 "The virtual machine stopped unexpectedly."`）。
- 诊断包（App 内 Settings > Export Diagnostics）分析后定位到宿主进程 **`com.apple.Virtualization.VirtualMachine` 的 `PGFifoThread`** 崩溃。

---

## 2. 根因分析（A 类与 B 类同源）

### 2.1 两类崩溃签名

| 类别 | 异常 | 栈顶（宿主） |
|---|---|---|
| **B** | `EXC_BAD_ACCESS / SIGSEGV` | `_platform_memmove` ← `ParavirtualizedGraphics +0x8e84/+0x8394` ← `Metal.framework` 管线描述符反序列化 |
| **A** | `EXC_CRASH / SIGABRT` | `abort` ← `MTLReportFailure` ← `MTLCompilerFunctionRequest::serializedRequest`（断言原文见 `vmm.stderr.log`：**`serializedRequest:418: failed assertion 'Corrupted library'`**） |

两者共同调用链（PGFifoThread）：
```
PG+0x21c38 → +0x20604 → +0xba40 → +0x8550 → +0x8d24
  → MetalSerializer+0x1008c(反序列化) / +0x100b8(编译)
  → -[PGTask makeFunction:]  @ PG+0x8db4
```

### 2.2 反编译结论（IDA，ParavirtualizedGraphics UUID 732073AB-…）

- **Apple 原生 `-[PGTask mappedAddressForOffset:length:]`（0x100007d00）**：
  1. `sub_1000079A0(offset,length, self+40)`：若 `offset+length > taskLength` → 抛 `NSException "Address out of range for task"`。
  2. 若区间未映射 → 回调 `mapMemoryInternalAtOffset:` **按需映射**（该映射经由我们包装的 map 回调，落到正确 segment）。
  3. **无条件 `return self[+32] + offset`**（`self+32`=base）。
- **项目替换**：`pvg_trace.m` 用 `SegmentedMappedAddressForOffset` 接管，先调原生（拿"按需映射"副作用），**丢弃其返回值**，改返回 `TranslatedTaskAddress(..., create=NO)`；失败则**回退 `nativeAddress`（=`base+offset`）**。

### 2.3 机制（为什么 A/B 都崩）

分段（被缩小的）任务里，真实预约只有 256MB / 2GB，且 overflow segment 是**懒创建**的。当 `create=NO` 找不到 segment 时回退的 `base+offset`：
- 落在**未映射区** → `memcpy` 越界 → **B（SIGSEGV）**；
- 恰好落在**已映射区但数据错** → 拷出损坏的 metal library → 宿主编译器断言 **A（`Corrupted library`）**。

即：**A/B 是同一 bug 的两种表现**。

---

## 3. 修复（`vz/host/pvg_trace.m`，编入 payload 的 `LaunchServicesCompat.dylib`）

三处改动（A + B + C）：

1. **A：`mappedAddressForOffset:` 翻译改用 `create=YES`**（与 `addressForOffset:` 对称），保证返回的是**正确 segment** 的地址。
2. **C：新增按 segment 的"已映射宿主区间"追踪**（合并区间 + 二分查询）；`TranslatedTaskAddress` 返回前校验"该地址后 `length` 字节确已映射"。
3. **B：翻译失败且属分段任务时抛 `NSException`（`VirtualMacPGFifoUnmappedRange`）**，交给 PGFifoThread 既有异常恢复；**不再返回裸 `base+offset`**。
   - 新增追踪在 `MapSegmentedTaskRange` / 包裹的 map 回调里记录，销毁任务时释放。

关键点：`SegmentedAddressForOffset`（CPU 可见地址）保持不变以避免影响对象表建立；只有崩溃路径 `mappedAddressForOffset:` 变严格。

---

## 4. 构建环境（macOS 15）踩坑与修复

> 本机：macOS 15.6.1，Xcode 在 `/Applications/Xcode.app`（`xcode-check` 默认指向 CommandLineTools）。

### 4.1 Xcode / SDK / Metal 工具链
- 用 `./setup.sh --non-interactive --skip-dependencies --xcode /Applications/Xcode.app`；`--xcode` 会设 `DEVELOPER_DIR`，否则 `xcrun --sdk iphoneos` 找不到 SDK。
- **Xcode 16+ 需先下载 Metal 组件**，否则 `metal` 缺失、`pvg_display.metallib` 编译失败：
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

### 4.2 chained fixups：Apple 工具链读不了"重建件"
重建出的 Mach-O 带 chained fixups，**macOS 15 的 `dyld_info` 与新版链接器 `ld`（ld-prime）都拒绝**（报 `chained fixups, imports_count (N) exceeds max of 0`），但该二进制在 iPad 上能被 dyld 正常加载。
- **校验导出符号**：改用 `xcrun llvm-objdump --macho --exports-trie`
  （已改 `scripts/build-ipad-videotoolbox.sh`，原用 `dyld_info -exports`）。
- **链接"重建二进制"**：clang 追加 `-Wl,-ld_classic`（经典链接器能读）
  （已改 `scripts/build-ipados14-hypervisor.sh` 的 LibSystem14 与 Hypervisor facade 两处）。

### 4.3 a2sb 符号缓存：**必须用缓存**（否则重建出坏框架 → App 启动即闪退）
- `vz/uncache.py` 的 `a2s_batch` 调 `ipsw dyld a2sb`。**带 `--cache` 与不带 `--cache` 结果不同**（`LookupSymbol` vs `DirectLookupSymbol`），会改变重建出的 Mach-O。
- 实测：Virtualization 框架 `--cache` → blob=16336、`__text` 与官方**逐字节一致**；无 `--cache` → blob=16472、`__text` **不一致** → 官方 App 能启动，我们的**点启动即闪退**（崩在 `Virtualization.framework` 的 objc 字典取值）。
- 但首次建整份 `.a2s` 缓存极慢（可达**数小时**，且是**每个 DSC 各一份**）。
- **折中（已采用）**：`uncache.py` 改为"**缓存文件存在就用 `--cache`，否则退回直查**"。→ macOS 22D68 的缓存务必保留（决定随包 payload 的忠实性）；Big Sur / iPadOS14 走直查（它们只是 iPadOS14 槽，16.3 运行期用不到）。

### 4.4 版本号（能被 dpkg 覆盖升级）
`build-ipad-deb.sh` 版本 = `2:1.2.3+<commit_count>.<hash>`；本 fork 是浅克隆（`commit_count=55`）< 已装 `607` → 装不上。
- 不提交代码的解法：重跑打包时用 `VZ_SKIP_REBUILD=1 VZ_PACKAGE_VERSION=2:1.2.3+608.vmfix1`。

---

## 5. 验证方法（今后避免再踩坑）

1. **重建忠实性**：逐字节比对 `__text` 段（别只看哈希/签名）：
   ```python
   # otool -l 取 __text 的 offset/size，再 cmp 两文件该区间
   ```
   与官方 payload（设备上 `/var/root/VirtualMac/payload/`）一致即忠实。
2. **修复确已入包**：`dpkg-deb -x` 解包后，对 `LaunchServicesCompat.dylib` 跑
   `strings | grep -E "VirtualMacPGFifoUnmappedRange|refusing unmapped"`。
3. **trustcache 一致**：`ldid -h <dylib>` 的 CDHash 必须与该文件在
   `var/jb/usr/share/VirtualMac/trustcache.txt` 中的条目一致。

---

## 6. 常用命令清单（复现）

```bash
cd ~/Desktop/VirtualMacOniPad/VirtualMac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 全量（下载/校验镜像 + 抽取 + 构建 + 打包）
./setup.sh --non-interactive --skip-dependencies --xcode /Applications/Xcode.app

# 只重建框架 + 打包（跳过镜像校验，较快）
bash scripts/build-frameworks.sh && bash scripts/build-ipad-deb.sh

# 仅重新打包并提升版本号
VZ_SKIP_REBUILD=1 VZ_PACKAGE_VERSION="2:1.2.3+608.vmfix1" bash scripts/build-ipad-deb.sh
```

---

## 7. 关键回归与教训（务必记住）

- **教训 1**：`uncache.py` 去掉 `--cache` 会让**重建框架不忠实** → App 点启动 VM **立刻闪退**。判断依据应是 **`__text` 逐字节比对**，而不是"构建没报错"。
- **教训 2**：判断二进制是否有问题，**不要只信 `dyld_info`/`ld`**（它们读不了重建件），要用 `llvm-objdump`/`nm`/`otool` 交叉验证。
- **教训 3**：Google/Apple 的 `MTLReportFailure` 是 `noreturn`（直接 abort），无法改为"不崩"；只能在进入闭源 Metal 之前**让非法数据提前失败**。
- **教训 4**：本仓库 `payload/` 不入库（`.gitignore`），随包二进制由构建期从 Apple 镜像抽取；判断"某次崩溃是否与本次改动相关"时，务必与**设备上的官方 payload** 对比。

---

## 8. 待办 / 回滚

- **设备侧冒烟**：装本 deb（`2:1.2.3+608.vmfix1`）→ 运行 Qoder CN 复现。
  - 不再崩溃 = 成功；若日志出现 `VirtualMac PVG: refusing unmapped mappedAddressForOffset`（或 `TASK_ADDRESS_UNMAPPED`）= 守护生效（把"整机崩溃"降级为"单资源失败"），属良性。
  - 若仍崩：导出新诊断，对比是否仍命中 `PGFifoThread`（A/B）。
- **回滚**：随时可重装作者版 1.2.3（Sileo 源）。
- **今后可选**：把"核心修复"与"构建工具链兼容修复"拆成两个 commit，便于作者更新后 merge/取舍。

---

## 9. 改动文件清单（本 fork）

| 文件 | 作用 |
|---|---|
| `VirtualMac/vz/host/pvg_trace.m` | **核心修复**（A+B+C） |
| `VirtualMac/scripts/build-ipad-videotoolbox.sh` | 导出校验改用 `llvm-objdump` |
| `VirtualMac/scripts/build-ipados14-hypervisor.sh` | 链接加 `-Wl,-ld_classic` |
| `VirtualMac/vz/uncache.py` | a2sb 改为"有缓存用缓存、无则直查" |
| `.gitignore` | 忽略临时分析目录 `.diag/` |

> 注：`uncache.py` 只影响构建，**不随 deb 发布**；它是"忠实重建"的关键开关。

---

## 10. 修订记录

### v2（`vmfix2`，经 CodeReview 子代理审查后）

在 `vmfix1` 基础上修了两处（均为子代理审出、本机验证）：

1. **严重**：`SegmentRecordMappedRange` 的区间合并里，`memmove` 移位条件由 `removed > 0` 改为 `count > mergeEnd`。
   - 原条件在"新区间插入某区间**之前且不相邻**（`removed==0`）"时不会右移尾巴 → 覆盖已有条目并留下**未初始化槽位** → 破坏"有序且互不相交"的排序不变式。
   - 后果：二分查询既可**假接受**（放行一个并未映射的宿主区间 → 复现原崩溃），也可**假拒绝**（丢失真实已映射区间 → 误抛异常）。
2. **行为一致性**：`TranslatedTaskAddress` 新增 `requireCovered` 参数：
   - `addressForOffset:`（`SegmentedAddressForOffset`）传 `NO` —— 保持"命中 segment 即返回"的旧语义，不影响对象表建立；
   - `mappedAddressForOffset:`（`SegmentedMappedAddressForOffset`）传 `YES` —— 做"已映射区间覆盖"校验。
3. `uncache.py`：缺 `.a2s` 缓存回退直查时**打印醒目 WARNING**，避免把"非忠实重建"误当成功。

本机验证：`pvg_trace.m` `-fsyntax-only` 通过；重建后 `Virtualization` / `ParavirtualizedGraphics` / `Hypervisor` / `MetalSerializer` 的 `__text` 与官方**逐字节一致**。

