# AGENTS.md — VirtualMacOniPad 接手者速查（压缩后恢复用）

> **如果你是刚被压缩/重启的 Agent**：先读本文件，再按需读 `docs/` 下的专项文档。本文件 = 任务规范 + 环境事实 + 当前战线 + 文档索引。

## 0. 我是谁 / 当前任务

- 项目：让 iPad 原生跑 macOS。本仓库 = **虚拟机路线**（Apple Virtualization.framework + PG/MetalSerializer 转发 GPU）。姐妹项目 `~/Desktop/macPad` = chroot 路线。
- **当前战线**：①外设直通盘点（已产出 `docs/PERIPHERAL-PASSTHROUGH-AUDIT.md`）；②**主线研究：VM 原生 GPU 优化**——目标是接近真 Mac 上 Virtualization.framework 的 GPU 体验。已知痛点：Matlab、Devin(Electron GPU)、Qoder CN 等需 `--disable-gpu` 或崩溃。研究记录写 `docs/GPU-NATIVE-RESEARCH.md`。
- 进度日志：`docs/WORKLOG.md`（每完成一步追加，压缩后从这里恢复进度）。

## 1. 十条行为准则（load-bearing，逐条遵守）

1. **取证先行**：改代码前先检索建立事实，禁止盲改。
2. **证据优先**：任何结论附逐字证据（崩溃报告/寄存器/反编译/命令输出）。"进程还活着"不算成功。
3. **禁止症状式补丁**：NOP 逃逸/改分支强走/全局 bypass assert/白名单 return 常数/填零防崩 —— 只算 diagnostic 且必须显式标注。
4. **先计划后施工**：多步任务先 todo；大工程先给可测第一步+数字闸门。
5. **并行加速**：大量取证/读文档先派 subagent 并行挖，主 Agent 保留抽验与落地。
6. **编译限流**：默认 ncpu×70%（8→5），`NUM_JOBS`/`CMAKE_BUILD_PARALLEL_LEVEL` 限子构建；`QOS=background` 用 `taskpolicy -b`。
7. **Git 纪律**：只 `git add <明确路径>`；commit message 英文 ASCII；**commit 后立即 `git push origin main`**；绝不 force push。
8. **写入边界**：只写当次指定子项目；`~/Desktop/Patch` 等其他仓库只读。`VMGPU/` = 黄金基线**只读**。
9. **破坏性操作零容忍**：删除挪废纸篓/挪一边，不用 rm；改用户数据前备份+回滚脚本；先算代价。**iPad 上只能只读取证**（见 §2 红线）。
10. **交付习惯**：实测数据+决策闸门+可回滚方案+中文 Markdown+已推送。先结论后依据，用表格，不吹不空谈。

沟通：中文交流，术语保留原文。直接、给数字、给权衡、不确定标"待确认"。

## 2. 环境事实

| 项 | 值 |
|---|---|
| 我跑在 | `VirtualMac2,1` macOS 15.6.1 (24G90)，8核/10GB —— **就是 iPad 上的虚拟机客机** |
| 宿主 iPad | iPad Pro 11" M1 (iPad13,11)，iPadOS 16.3 (20D47) + Dopamine 3.0.2 rootless，16GB |
| **SSH 到 iPad** | `sshpass -p cisco ssh -p 2222 root@192.168.64.1`（NAT 网关即 iPad；22/2222 都通；密码见用户消息，勿写入会入库的文件——本条注意：密码只保留在会话上下文，文档里写"密码问用户"） |
| iPad 上关键路径 | App: `/var/jb/Applications/VirtualMac.app` → `/private/preboot/.../procursus/Applications/`；payload: `/var/root/VirtualMac/payload/`；VM 数据: `/var/mobile/Media/VirtualMac/`（`Sequoia.bundle/`、`Settings.plist`、`Diagnostics/`） |
| 网络 | 客机经 NAT 出网；飞牛 NAS 中转 `~/Library/CloudStorage/飞牛同步-HomeNAS/` |
| 工具 | Xcode/clang/brew；`ldid`/`dpkg-deb`/`sshpass`/`expect`；IDA Pro 9.2 + ida-pro-mcp（Instance1-3 被别的项目占用；需要时让 Instance4 @13340，由用户加载二进制）；`dyldex`/`ipsw-a2sb` 在 `VirtualMac/build/toolchain/` |
| 陷阱 | **无 `timeout` 命令**（用 `nc -G`/ssh `ConnectTimeout`/后台任务）；无 fakeroot/Theos；macOS 15 的 `dyld_info`/`ld` 读不了重建件（chained fixups）→ 用 `llvm-objdump` + `-Wl,-ld_classic` |

### 🔴 iPad 侧红线（用户特别强调）
- **只能只读**：cat/ls/find(限定深度)/ps/unzip -l|unzip -p(单文件)。宿主上跑着本 VM（`com.apple.Virtualization.VirtualMachine` PID 变动，~275% CPU）+ macPad 项目也在动内核文件——**任何可能 panic iPadOS 的操作都会一波带走当前会话**。
- 禁止：launchctl kickstart/unload、kill 系统进程、sysctl -w、nvram 写、注入运行中进程、全文件系统 find、大文件下载（诊断 zip ~1.1GB/个，只拉需要的条目）、在 iPad 上编译。

### 🔄 iPad 重启后的恢复（2026-10-01 发生过一次）
- iPad 重启 = **本客机断电，当前会话死**。重启后 Dopamine 需重新越狱（semi-untethered），respring 后 OpenSSH 才恢复；然后用户启动 VirtualMac App → 客机启动 → 新 CLI 会话。
- 新会话第一步：读 `docs/WORKLOG.md` 末尾"iPad 重启后的续会话行动清单"，按序执行（先验 SSH，立刻拉 `/tmp/vmm.stderr.log` `/tmp/pvg-trace.log`）。
- sshd 挂死的历史症状：`kex_exchange_identification: Connection reset by peer`（TCP 可连、banner 前被重置）。用户侧 launchctl kickstart 报 EPERM——终端里须先 `su` root；实在不行重启 iPad 是正解。
- 清理 iPad 文件前：先把有价值证据拉回本机 `.diag/`（已 gitignore），再删。

## 3. 已确认事实速查（2026-10-01 盘点）

- VM 配置 = `Sequoia.bundle/VirtualMac.plist`（非 App 的 Settings.plist）：8 vCPU / 10GB / 512GB 盘 / 2732×2048@264ppi NativeRetina / NAT / MacKeyboard+MacTrackpad / virtio audio in+out / **VideoToolbox 强制注入**（`original-supported=0`）/ **OpenGLAccelerationEnabled=1、MetalBCSupportEnabled=1**（自有扩展，非 Apple 键）/ GuestTools virtio socket :505050（QGA 式 JSON）。
- payload `Virtualization.framework` **含 macOS 15 代 USB 类**：`VZUSBMassStorageDeviceConfiguration`、`_VZUSBDevice`、`_canAttachUSBDevices`/`_attachUSBDevice:error:` 等 153 个 ObjC 类——能不能在 iPadOS 16.3 跑通待 IDA 取证（Instance4）。
- 运行期设备表（VirtualMac.log 逐字）：`_VZMacKeyboardConfiguration`、`VZMacTrackpadConfiguration`、virtio audio、`native VideoToolbox accelerator`、NAT、`_VZGraphicsDevice`+`_VZFramebuffer`（PVG 原生显示）、virtio socket。**无任何 USB 运行时设备**。
- 注入面：`VZHostCompat.dylib`（App 内）+ `vzxpchook`（VMM XPC 内，rebind IOSurface/confstr/sysctlbyname/sandbox_extension/xpc_connection_*）+ `VZKeyboardPassthrough.dylib`（TweakInject）。详见审计文档。
- App 端遗留 bug：两次 `makeConfiguration` 内 `NSDictionary` 下标 SIGSEGV@0x10（9/20，vmfix1 已装）——与 PG 修复无关的另一只虫子，见 `.diag/20260920-121651/crash-reports/`。
- Guest 侧 NVRAM 启动参数含 `-arm64e_preview_abi`；GuestTools guest agent 协议是 QGA 风格 JSON（virtio socket :505050）。
- **GPU 已知大事（详见 docs/GPU-NATIVE-RESEARCH.md §G/§H）**：payload=macOS 13.2.1 Ventura 提取（PG 13.0.34 / VZ 104.7.1），客机 Metal 插件 40.7.1(15.6)。客机**每日 gpuRestart 风暴**（`submitEvent:INCOMPLETE` 签名）；OpenGL 全靠客机 shim `OpenGLPVGCompat.dylib`。**IDA 已全解 Ventura PGFIFO**：`processFifo`@0x100021594 分发 32 命令（0x37=CmdExecIndirect2），opid>0x40 或未识别→`faultAtOffset`（@0x10001bdd8，condvar 停车等 quiesce）= 一条 fault 冻整条通道。guest 15.6 词表含 Ventura 没有的 0x41-0x44，但协商诚实（feature 位门控 + binaryVersion clamp≤43 + deserializerVersion 出料）→ 新 opcode 正常不发；**头号嫌疑 = 宿主 iPadOS16.3 AGXMetal 跑不动合法内容**（completedHandler status==5→fault，与 metalshim 补 BC 同类）。guest kext 存档 `.diag/guest-kext-15.6.1/`。
- vmmhook.m = VMM 进程兼容层：`hv_*` 全套 interpose、USB HCI swizzle（restore 桥服务端）、xpc/IOService/IOSurfaceCreate 改写、VMM 内存放宽至 2×physical（GPU 重载相关的真实约束）。
- 已知疑点：客机 `system_profiler SPDisplaysDataType` 输出空；App `makeConfiguration` 有字典下标 SIGSEGV 历史崩溃（9/20，vmfix1 在装）；vzboot.m 输入类注释与运行日志矛盾。

## 4. 文档索引

| 文件 | 内容 |
|---|---|
| `docs/AGENT-SUPER-HANDOVER.md` | 完整手册（准则/项目地图/踩坑/检查表） |
| `docs/VM-crash-fix-and-build-notes.md` | VM 崩溃修复（PG mappedAddressForOffset）+ macOS15 构建坑（a2sb 缓存必须、chained fixups、llvm-objdump、-ld_classic） |
| `docs/VMGPU-REFERENCE.md` | 黄金基线用法：`__text` 逐字节比对 / UUID / CDHash 核对 |
| `docs/VMGPU-cdhash.tsv` | 基线 UUID/CDHash 清单 |
| `docs/PERIPHERAL-PASSTHROUGH-AUDIT.md` | 外设直通盘点（本轮产出） |
| `docs/SOURCE-AUDIT-REPORT.md` | vz/ 全源码逐行静态审计（架构地图/hook 全表/USB 状态机/entitlement/风险清单） |
| `docs/GPU-NATIVE-RESEARCH.md` | GPU 主线研究记录（本轮起持续更新） |
| `docs/WORKLOG.md` | 逐条进度日志（压缩后先读它） |
| `.diag/` | 本机取证暂存（gitignored，不入库） |

## 5. 构建/验证命令

```bash
cd ~/Desktop/VirtualMacOniPad/VirtualMac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./setup.sh --non-interactive --skip-dependencies --xcode /Applications/Xcode.app   # 全量
bash scripts/build-frameworks.sh && bash scripts/build-ipad-deb.sh                # 重建+打包
VZ_SKIP_REBUILD=1 VZ_PACKAGE_VERSION="2:1.2.3+608.vmfixN" bash scripts/build-ipad-deb.sh  # 仅打包
# 忠实性：__text 逐字节比对（脚本见 docs/VMGPU-REFERENCE.md §3.1）
# 修复入包验证：dpkg-deb -x 后 strings | grep -E "VirtualMacPGFifoUnmappedRange|refusing unmapped"
# trustcache：ldid -h <dylib> vs var/jb/usr/share/VirtualMac/trustcache.txt
```

> 最高优先级：**用户当下指令 > 代码/配置 > 文档/记忆**。发现文档与现实不符 → 以证据为准并更新文档。
