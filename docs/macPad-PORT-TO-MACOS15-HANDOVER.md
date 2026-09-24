# macPad → macOS 15.6.1 移植：Super Handover（施工图）

> 读者：接手者（人类或 AI）。本文 = **实测数据 + 施工顺序 + 验收标准**，照做即可，不需要重新摸现状。
> 生成：2026-09-24 · 生成环境：`VirtualMac2,1`（macOS **15.6.1 / 24G90**，8 核 / 10GB，宿主 iPadOS **16.3** + Dopamine）
> 仓库：本仓（fork `zenkernelsam/macPad`，upstream `DCMMC/macPad`）。**动手前先读仓库 `AGENTS.md`（补丁纪律 + 证据纪律，load-bearing）**。

---

## 0. TL;DR（先看这个）

| 结论 | 说明 |
|---|---|
| **可行** | 版本耦合点是**有界集合**：约 **28 条字节签名 + 66 处 `memcmp` + 12 个 Mach-O UUID 闸门 + 48 个目标路径**（全仓 ~60.8k 行） |
| **最大坏消息** | 补丁用 **UUID 严格闸门**（`macws_macho_uuid_matches`）。**已实测**：15.6.1 的 `AGXMetal13_3` arm64e UUID = `B303B4E8-5F17-39B8-8505-326AAF870F39`，**不在**源码 12 个 UUID 中 → **12 个闸门在 15.6.1 上预期全数失效，必须逐条重推** |
| **最大好消息** | ① 宿主（M1 + iPadOS 16.3）与作者验证矩阵**一致**；② **iOS 侧代码不用移植**（MacWS 守护 / ChrootProxy / `launchdchrootexec`）；③ 本机同时具备 **15.6.1 与 13.2.1 两套共享缓存**，可做对照 |
| **推荐路径** | 先跑 §3 的**命中率探针**（约 30 分钟，纯本机）→ 用数字决定：全量 port / 只做"最小可启动(MVB)" / 退回 13.4 |
| **为什么难（先破除误解）** | **不是内核问题**：chroot 共享宿主 **iOS 16.3 内核**，换 macOS 版本**不动内核**。真正原因是：①**用户态二进制字节级变化**→ 12 个 UUID 闸门全失效 + 28 条签名大量失效（机械但量大）；②**图形栈实现演进**（Metal→Skia Graphite、AGX/IOGPU ABI、IOSurface 布局/压缩、SkyLight/WindowServer 管线）→ 部分补丁点在 15.x **根本不存在**，要**重新设计**；③macOS 15 的**密封系统卷/Cryptexes** 使 rootfs 准备流程未验证 |

---

## 0.5 我方现状：iPad 上跑 macOS 的两条路线

> 目的：先建立**全局图景**，避免把"VirtualMac 那套（**虚拟机**）"和"macPad 这套（**chroot**）"混为一谈。

### A. 硬件 / 宿主（"两台机器"其实是**同一个 iPad**）

| 项 | 值 |
|---|---|
| 设备 | iPad Pro 11" M1（`iPad13,11`），**16GB** RAM |
| 宿主系统 | iPadOS **16.3 (20D47)** + **Dopamine 3.0.2（rootless）** |
| 越狱形态 | rootless（`RootHide jailbreak root: (none)`），路径形如 `…/dopamine-IWpVUH/procursus/` |

### B. 路线 1（**当前在用**）：VirtualMacOniPad — 硬件虚拟机

- **形态**：用 **Apple Virtualization.framework** 开**硬件虚拟化 VM**（宿主进程 `com.apple.Virtualization.VirtualMachine`）；GPU 走 **ParavirtualizedGraphics(PG) + MetalSerializer**，把客机 Metal 转发到 iPad 真 GPU（**有翻译损耗**，这是它 GPU 偏慢的原因）。
- **客机**：**macOS 15.6.1（Sequoia, 24G90）**，**8 vCPU / 10GB**，显示 1920×1200@2x，MetalBC / OpenGL 加速 / VideoToolbox 均开启，网络 NAT；VM 包名 `Sequoia.bundle`。
- **仓库（就在本机桌面）**：`~/Desktop/VirtualMacOniPad`（fork `zenkernelsam/VirtualMacOniPad`，upstream `nfzerox/VirtualMacOniPad`），应用版本 1.2.3。
- **我们在此仓库做过的事（重要：说明本机工具链与经验都已具备）**：
  1. **修过 VM 崩溃 bug**：`vz/host/pvg_trace.m` 中 `mappedAddressForOffset` 回退到 Apple 原生 `base+offset` → A 类（Metal 断言 `Corrupted library`）/ B 类（`memmove` 越界）崩溃；已改为 `create=YES` + 已映射区间覆盖校验 + 安全失败。
  2. **修过 macOS 15 构建兼容**：重建二进制的 chained fixups 不被 `dyld_info`/`ld` 解析 → 改用 `llvm-objdump --macho --exports-trie`、链接加 `-Wl,-ld_classic`；**a2sb 符号缓存必须使用**（否则重建的框架不忠实 → App 启动即闪退）。
  3. 产出过 `VirtualMac_1.2.3_046abc6e0a.deb`（`2:1.2.3+608.vmfix2`），笔记见该仓库 `docs/VM-crash-fix-and-build-notes.md`。
- **对本任务的直接价值 / 陷阱**：
  - ✅ 本机**就是 macOS 15.6.1** ⇒ §3 探针所需的 **15.6.1 共享缓存就是本机系统缓存**（真实目标版本，不是近似）。
  - ⚠️ 但 **VM 的宿主是 iPad**，客机（本机）经 NAT 出网；若要 **SSH 到 iPad**（如作者用的 `172.20.10.3:2222`），**需先验证路由**，否则改用飞牛 NAS 中转。

### C. 路线 2（**本交接的目标**）：macPad — chroot

- **形态**：**chroot 进 macOS rootfs + dyld interposition**，共享 **iOS 16.3 内核**，用**原生 CPU/GPU 驱动**（无 hypervisor、无 GPU 翻译）⇒ 理论性能更好、隔离更差。
- **需要**：**macOS 13.4 rootfs**（作者验证组合）；我们手头只有 **13.2.1** 的 IPSW；**15.6.1 rootfs 未准备**。
- **目标**：把硬编码补丁从 13.4 适配到 **15.6.1**（见 §1–§7）。

### D. 本机可用工具（都在这台 15.6.1 客机里）

| 工具/资源 | 状态 |
|---|---|
| Homebrew / clang / Xcode | `/opt/homebrew`、`/usr/bin/clang`、`/Applications/Xcode.app` ✅ |
| `ldid` / `dpkg-deb` | `/opt/homebrew/bin/{ldid,dpkg-deb}` ✅；**`fakeroot` 缺**（构建 macPad 才需要） |
| Theos | **未安装**（构建 macPad 才需要） |
| IDA Pro + MCP | **IDA Pro 9.2 已装** + `ida-pro-mcp`（`decompile`/`disasm`/`xrefs_to`/`find_bytes`/`py_eval`…） |
| dyld 抽取 / ipsw | `~/Desktop/VirtualMacOniPad/VirtualMac/build/toolchain/{venv/bin/dyldex, bin/ipsw-a2sb}` |
| 现成镜像 | `UniversalMac_13.2.1_22D68_Restore.ipsw`(12G)、`UniversalMac_11.6_20G165_Restore.ipsw`(13G)、`iPad_Spring_2021_14.5_18E199_Restore.ipsw`(4.9G) |
| 环境陷阱 | **无 `timeout`**（未装 coreutils）；`fakeroot` 缺失 |

---

## 1. 硬编码在哪、有多少（实测）

### 1.1 代码规模（`libmachook/`，含 `.m/.x/.c`，合计 ≈ 60,826 行）

| 文件 | 行数 | 字节签名数组 | memcmp | UUID | 目标路径 | 备注 |
|---|---|---|---|---|---|---|
| `mac_hooks.m` | 23,491 | 18 | 53 | 13 | 36 | 主文件：`loadImageCallback` 里逐镜像打补丁 |
| `Metal_hooks.x` | 23,291 | 5 | 10 | 6 | 53 | Metal/GPU 栈（ObjC++） |
| `AppInputBridge.m` | 11,337 | 5 | 3 | 0 | 5 | 输入桥 |
| `MacWSFinalCompositePublisher.m` | 839 | 0 | 0 | 0 | 1 | 合成发布 |
| `exec_hooks.c` / `jit.m` / `os_log_hooks.m` / `DNSBridge.c` / … | <1k | 0 | 0 | 0 | 少量 | 非版本耦合 |
| **合计** | **60,826** | **28** | **66** | **19（12 去重）** | **100（48 去重）** | |

### 1.2 字节签名（前 14 条，臂 64 序言型；**普遍很短 → 精度靠 UUID/路径闸门**）

| # | 文件 | 变量名 | 长度 | 前 8 字节 | 所在函数 |
|---|---|---|---|---|---|
| 1 | Metal_hooks.x | `mac_key_prologue` | 8B | `d1 a9 a9 a9 91 aa 39 34` | `macws_install_stray_input_consume_diagnostic` |
| 2 | Metal_hooks.x | `slate_key_prologue` | 8B | `d1 a9 a9 a9 a9 91 aa aa` | 同上 |
| 3 | Metal_hooks.x | `slate_key_up_prologue` | 8B | `d1 a9 a9 a9 a9 91 aa aa` | 同上 |
| 4 | Metal_hooks.x | `submit_prologue` | 14B | `d1 50 a9 10 a9 20 a9 30` | `macws_install_stray_submit_flags_diagnostic` |
| 5 | Metal_hooks.x | `surface_lock_prologue` | 14B | `d1 12 a9 e0 a9 f0 a9 10` | 同上 |
| 6 | Metal_hooks.x | `expectedPrologue` | 6B | `d5 d1 a9 a9 a9 a9` | `macws_install_quartzcore_update_image` |
| 7 | mac_hooks.m | `expectedPrologue` | 9B | `d5 d1 40 a9 20 a9 30 91` | `MacWSSkyLightCursorABIValid` |
| 8 | mac_hooks.m | `expected` | 12B | `d5 a9 a9 a9 91 f9 b4 aa` | （分支内） |
| 9 | mac_hooks.m | `expected` | 12B | `d5 a9 a9 91 b9 71 54 aa` | （分支内） |
| 10 | mac_hooks.m | `expected_prologue` | 16B | `6d 70 a9 10 a9 20 a9 30` | （分支内） |
| 11 | mac_hooks.m | `expected_capture_adapter` | 10B | `39 71 54 aa 39 e2 37 a9` | （分支内） |
| 12 | mac_hooks.m | `expected` | 7B | `f0 91 b9 94 aa aa 94` | `macws_optimize_stray_steam_overlay_debug_label` |
| 13 | mac_hooks.m | `clientGetter` | 3B | `f9 c8 d6` | `macws_iosurface_protection_abi_ready` |
| 14 | mac_hooks.m | `source_builder_platform_returns` | 5B | `0e 0e 0e 0e 0e` | （分支内） |

> 说明：另有 ≤3 字节的数组未列出；`memcmp(candidate, expected, …) == 0` 是统一写法（共 66 处）。

### 1.3 UUID 闸门（去重 12 个；已知映射）

| UUID | 线索（目标/函数） |
|---|---|
| `CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC` | **QuartzCore**（`macws_install_quartzcore_frame_info_hook`、`Vbl_FrameTime`） |
| `2B44B850-7D19-34F3-AB8E-A3B93016A96D` | **IOKit/IOGPU**（`IOConnectTrap1`） |
| `DF041B53-4BAA-3668-8781-43DE39FA8905` | **IOGPU**（`IOConnectCallMethod`） |
| `727C250E-554D-3921-A5B3-48DAE6195B79`、`2BAB169C-42DA-36E3-955A-F30B709EC2AD` | **Metal/XPC**（`xpc_connection_cancel`） |
| `49124C96-…`、`944AFB88-…`、`4C4C4442-…`、`529F4E8F-…`、`388DEE66-…`、`CE2B5551-…`、`9485C742-…` | 待补（多为 Metal/AGX/其他系统框架） |

**实测对照**：15.6.1 的 `AGXMetal13_3.bundle` arm64e UUID = `B303B4E8-5F17-39B8-8505-326AAF870F39` → **不在上表** ⇒ 该簇必须重推。

### 1.4 目标二进制（去重 48 条，举要）

- **GPU/图形**：`/System/Library/Extensions/AGXMetal13_3.bundle/…/AGXMetal13_3`、`PrivateFrameworks/AGXCompilerCore`、`PrivateFrameworks/IOGPU`、`Frameworks/Metal`、`Frameworks/QuartzCore`（含 `Resources/default.metallib`）、`Frameworks/CoreGraphics`、`Frameworks/IOKit`
- **桌面/系统**：`CoreServices/Dock.app`、`System Settings.app`、`Preview.app`、`Maps.app`、`CoreServices/iconservicesagent`
- **App 特例**：`Visual Studio Code.app/…/Electron`、`Steam.app`、`Geekbench 6.app`、`MacWSCatalystLauncher.app/PlugIns/SettingsExtensionProxy.appex`

---

## 2. 关键机制（为什么"改版本=大工程"）

1. `libmachook/mac_hooks.m` 注册 `dyld_register_func_for_add_image(loadImageCallback)`：**每个镜像加载时**，按**硬编码字节序**在该镜像里定位补丁点。
2. 定位通常需要**三重匹配**：镜像路径（48 条）+ **Mach-O UUID**（12 个）+ **函数序言字节**（28 条）。
3. 命中后按**硬编码动作**改写（NOP / 改分支 / 重定向 stub / 填返回值），**全部假定 macOS 13.4 的二进制布局**。
4. 另有一层 **iOS↔macOS 服务桥**（`*ChrootProxy`、`macws*` 守护）——**与 macOS 版本无关**（宿主恒为 16.3），**不用移植**。

### 2.1 复杂度到底来自哪（澄清一个常见误解）

- **不是"内核版本相差太多"**：chroot **共享宿主 iOS 16.3 内核**；换 macOS 版本 ≠ 换内核。
- **主要工作量 = 字节级重定位**：补丁靠"路径 + UUID + 序言字节"三重匹配，而 **UUID 每次编译都会变**、函数序言/指令常被重排 → 12 个 UUID 闸门**必全失效**，28 条签名要逐条在 15.6.1 里重新定位等价点。
- **最大不确定性 = 图形栈"实现"演进**（不是 API 版本号）：Metal 走 Skia Graphite、AGX/IOGPU 的 ABI、IOSurface 布局/压缩、SkyLight/WindowServer 合成管线 → 旧 hook 点可能**消失**，需要**另找思路**而非改字节。
- **次要但脆**：App 特例（Dock / Settings / ExtensionKit / Preview / Maps）内部实现变化。
- **独立风险**：**macOS 15 rootfs 准备**（密封系统卷 + Cryptexes + dyld 变化）与 13.x 流程不同，**未验证**。

---

## 3. 第一步（必做，约 30 分钟，纯本机）：命中率探针

目的：把"要重推多少条"变成**数字**。

```bash
DSC15=/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
DSC13="$HOME/Desktop/VirtualMacOniPad/VirtualMac/build/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e"
DYLDEX="$HOME/Desktop/VirtualMacOniPad/VirtualMac/build/toolchain/venv/bin/dyldex"

# 1) 从两套缓存里抽出同一批目标镜像（示例：Metal / QuartzCore / IOKit）
for lib in /System/Library/Frameworks/Metal.framework/Versions/A/Metal \
           /System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore \
           /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit ; do
  nm=$(basename "$lib")
  "$DYLDEX" -e "$lib" -o "/tmp/15-$nm" "$DSC15"
  "$DYLDEX" -e "$lib" -o "/tmp/13-$nm" "$DSC13"
done

# 2) UUID 对照（这就是 12 个闸门的命中表）
for f in /tmp/1*-*; do printf "%-22s " "$(basename "$f")"; /usr/bin/dwarfdump --uuid "$f" | grep arm64e; done

# 3) 字节签名扫描（把 §1.2 的每条签名抠成 hex，对 15.6.1 镜像 grep）
#    printf 'd1a9a9a991aa3934' 之类，用 xxd + grep -c 统计命中
# 4) AGX 簇（磁盘上有，直接读）
/usr/bin/dwarfdump --uuid /System/Library/Extensions/AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3
```

> 注意：本机**没有 `timeout`**（无 coreutils）；`dyldex` 对 macOS 15 缓存格式的兼容性**未验证**（若失败，改用 `ipsw dyld extract` 或从 13.x 侧先建立基线）。
> **产出**：一张"签名/UUID × {13.2.1, 15.6.1} 命中表" → 直接决定工期（见 §6）。

---

## 4. 移植方法论（按这个顺序，别横着来）

**台账先行**：为每条补丁建一行 `{目标镜像, 函数/符号, 旧签名/UUID, 动作, 该补丁的"为什么"(来自 AGENTS.md/注释), 15.6.1 新签名, 状态}`。没有"为什么"的补丁**不要**照搬。

1. **步骤 0**：跑 §3 探针，填台账"命中"列。
2. **步骤 1｜最小可启动（MVB）**：只 port **WindowServer/SkyLight 启动链**必需的少数补丁 → 目标：能 `run_bash.sh` 进 macOS bash、能出一个窗口。**不达 MVB 之前不碰 App 特例补丁**。
3. **步骤 2｜分簇推进**（每簇独立验收）：
   - 簇 A：SkyLight / WindowServer / Dock / iconservicesagent
   - 簇 B：Metal / QuartzCore / IOGPU / AGX(AGXMetal13_3, AGXCompilerCore) ← **重推量最大**
   - 簇 C：CoreGraphics / IOKit
   - 簇 D：App 特例（VSCode/Electron、Steam、Geekbench、SettingsExtension）← 优先级最低
4. **步骤 3**：回归（`misc/` 里有现成探针：`test_*_contract.py`、`run_aquarium_benchmark_safe.sh`、`vscode-aquarium-runner/`）。

**验收证据（硬要求，照仓库纪律）**：**可见输出**（VNC/像素/窗口）、**计数器前进**、**XPC 往返成功**——**不是**"进程还活着"。症状式补丁（NOP/白名单/全局 bypass）**只能标记为 diagnostic**，不算修好。

---

## 5. 结构性障碍（撞上就别硬撞，仓库已有前例）

- `io_connect_t` **mach port 被内核 GUARD**，无法跨任务传递（AGENTS.md §159）→ 某些 IOKit 借用路径在 chroot 下**结构性不可修**。
- `MTLReportFailure`（`noreturn`）与 tile pipeline 不可用（AGENTS.md §119）。
- 树里仍有一处**全局 `__assert_rtn` bypass**（作者自己标注为 "lazy"，掩盖 `MetalContext.mm:411` 的 composite 栈泄漏）→ **不要把它当既有正确性**。
- `Mempool::grow` NOP 曾被回滚（`4124628`→`098690e`）：**跳过 freelist 初始化会崩得更狠**。

---

## 6. 工期与决定点（拿到 §3 数字后用）

| 15.6.1 命中率 | 判断 | 建议 |
|---|---|---|
| UUID/签名 **>70%** 命中 | 图形栈漂移小 | **值得全量 port**（预计 3–7 天） |
| **30–70%** | 部分重推 | **只做 MVB + 簇 A/B**，App 特例延后（预计 1–2 周） |
| **<30%** | 栈大改 | **放弃 15.6.1**，回到作者验证过的 **13.4 rootfs**（最稳） |

> 另需独立评估：**macOS 15.6.1 rootfs 的准备**（MacWSBootingGuide 流程按 13.x 写，15.x 的密封系统卷/Cryptex 差异**未验证**）。

---

## 7. IDA Pro 逆向清单（必须逐个处理的文件）

> 环境：本机已装 **IDA Pro 9.2** + `ida-pro-mcp`（工具：`decompile` / `disasm` / `xrefs_to` / `find_bytes` / `get_bytes` / `rename` / `set_comments` / `py_eval`）。
> 建议工作流：**每个镜像一个 IDB** → `find_bytes` 搜"旧签名" → 命中处 `decompile`/`disasm` 确认语义 → 产出"新签名 + 依据" → 回填台账。

### 7.1 A 类｜macOS 侧（**必须重推**；来源 = rootfs / macOS 共享缓存）

| 优先级 | 二进制 | 位置 | IDA 要做什么 |
|---|---|---|---|
| ★★★ | `QuartzCore` | 共享缓存 | 旧 UUID `CF853BBD-01B6-3F46-ADA1-EC70FD2DC9DC`；定位 `macws_install_quartzcore_frame_info_hook` / `Vbl_FrameTime` 对应点，重推 `expectedPrologue`(6B) 与 update-image 调用点 |
| ★★★ | `Metal` | 共享缓存 | 重推 `submit_prologue`(14B)、`surface_lock_prologue`(14B)、`mac_key_prologue`(8B)；确认 submit 标志位 / 反射反序列化路径是否仍存在 |
| ★★★ | `IOGPU` | 共享缓存 | 定位 `IOConnectCallMethod` / `IOConnectTrap1` 相关点（旧 UUID `DF041B53-…`、`2B44B850-…`）→ 重定位资源创建路径 |
| ★★★ | `AGXCompilerCore` | 共享缓存 | `setupCompiler:` / variant 查找链（历史坑：`findOrCreate<X>ProgramVariant`） |
| ★★☆ | `SkyLight` | 共享缓存 | `MacWSSkyLightCursorABIValid` 对应点（`expectedPrologue` 9B）+ WindowServer 合成/光标 ABI |
| ★★☆ | `CoreGraphics` | 共享缓存 | 位图/图像 ABI 相关补丁点 |
| ★★☆ | `IOKit` | 共享缓存 | `mach_port_construct` 等（与 IOGPU 簇交叉） |
| ★☆☆ | `default.metallib` | `QuartzCore.framework/Versions/A/Resources/` | 确认 15.6.1 是否仍存在 / 路径是否变化 |

### 7.2 B 类｜iOS 侧（宿主恒 16.3 → **原则上不用 port**，但有一处版本线索要核查）

| 二进制 | 说明 |
|---|---|
| `AGXMetal13_3.bundle/Contents/MacOS/AGXMetal13_3`（**iPad 自带**的 GPU 驱动） | macPad 走"**real iOS AGX kernel driver**"，即把 **iOS 的** AGX bundle bind-mount 进 rootfs → **iOS 16.3 不变 ⇒ 不用 port**。⚠️ 但需**确认 bind-mount 关系**（rootfs 里同名 bundle 是否被 iOS 的覆盖） |
| `macws*` 守护 / `*ChrootProxy` / `launchdchrootexec` | 与 macOS 版本无关，**不改** |

> ⚠️ **版本线索矛盾（务必先查）**：README 写测于 **iPadOS 16.3**，而 AGENTS.md 写 "hardcoded for **iOS 16.5** / macOS 13.4"。**若 iOS 侧签名是按 16.5 推的，则 iOS 侧也要重推**——这是**第二条 port 轴**，别漏。

### 7.3 C 类｜App 特例（最低优先级，最后做）

`Dock`、`iconservicesagent`、`System Settings`、`Preview`、`Maps`、`MacWSCatalystLauncher.app/PlugIns/SettingsExtensionProxy.appex`、Visual Studio Code 的 `Electron`、`Steam`、`Geekbench 6`
→ 每个都要 IDB；多数只是"绕过版本/权限检查"，**先判断 15.6.1 是否还需要**（可能已不需要，直接把补丁删掉更干净）。

### 7.4 IDA 产出物（回填台账）

每条补丁一行：`目标镜像 | 符号/函数 | 15.6.1 地址 | 新签名(hex) | 语义依据(decompile 片段) | 动作 | 状态`

---

## 8. 附录

- **机器**：`VirtualMac2,1` / macOS 15.6.1(24G90) / 8c / 10GB / 宿主 iPadOS 16.3 + Dopamine
- **工具路径**：`dyldex`=`~/Desktop/VirtualMacOniPad/VirtualMac/build/toolchain/venv/bin/dyldex`；`ipsw`=`…/toolchain/bin/ipsw-a2sb`；IDA Pro 9.2 + `ida-pro-mcp`（`py_eval`/`decompile`/`xrefs_to` 等）
- **缓存**：15.6.1 = `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`（2.7G）；13.2.1 = `~/Desktop/VirtualMacOniPad/VirtualMac/build/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e`（1.6G）
- **13.4 备选镜像**：本机另有 `UniversalMac_13.2.1_22D68_Restore.ipsw`（12G）与 `UniversalMac_11.6_20G165_Restore.ipsw`（13G）
- **待办**：把 §1.3 未定映射的 UUID 补全；把 §3 探针结果回填成表；把台账落到 `docs/porting/patch-ledger.tsv`

---

### 变更纪律（来自本仓 `AGENTS.md`，务必遵守）
1. 不写症状式补丁；如写了，**必须标注为 diagnostic**。
2. 每个"为什么坏了"的结论都要有**逐字证据**（崩溃报告/寄存器/lldb 记录）。
3. 先在**正确的层**修；定位不到根因就继续找，不要往下 NOP。
