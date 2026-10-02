# SUPER HANDOVER：VirtualMac GPU 主线接手手册

> 最新更新：2026-10-02 22:53 后，iPad 重启、重新越狱，用户已安装 build88 并重新进入客机。
> 接手对象：Codex CLI 或任何其他供应商的 coding agent；本文不依赖 Devin/Qoder 的私有记忆、会话或工具。
> 项目根：`/Users/ciscohe/Desktop/VirtualMacOniPad`。先读本文和根 `AGENTS.md`，再按下文索引查源码/证据。
> 本文替代原 2026-10-01 的旧交接状态；旧文档的“当前战线是 USB”“先调用 SearchMemory”“仍使用旧 vmfix2 包”不再适用于当前任务。
> 文档是可核对的上下文，不是全知保证。时间点、源码/安装件/运行件、能力声明/执行/性能必须分开。用户最新指令和实际源码/日志优先。

## 0. 接手者首先必须知道的十件事

1. 你运行在 **iPad M1 上的 macOS 虚拟机客机**，不是实体 Mac。iPad 重启会使客机断电、会话终止。
2. 当前主线是 **VirtualMac 原生虚拟 GPU 的兼容性、真实能力与稳定性**，不是 USB 或 macPad 移植。
3. 最新完整交付包是 **build88**，用户已安装。客机 GuestTools build、GL hash/signature 和新能力门控已经轻量核对；**88 本次启动后的宿主日志、Godot 实景和长期稳定性尚未验收**。
4. 88 是 86/87 的全部既有修复 + 一项真实新增的 Vulkan/MoltenVK 能力一致性修复；不是把所有 Metal 功能全部打开。
5. **Argument buffers 仍是 tier1**。已定位协议门控：不是漏开 key33。不能改 getter 为 YES 或把协议从43强抬到207冒充修复。
6. Godot OpenGL 的特定 GPU 粒子 shader 崩溃已经定位、复现、修复、负对照及重复验证。不能保证所有 Godot 游戏都正常，也不能再笼统说“完全不是 VirtualMac 的问题”。
7. 88 的 Vulkan 修复来自真实 getter `supportsRenderPassWithoutRenderTarget=NO`，动态收窄不完整的 Mac2 声明；不是关 rasterization、绕过 assert 或按应用名写死 NO。
8. 84 是保守回滚包，86/87 也保留。安装 deb 前 **必须正常关 macOS、确认 VM 停止**；preinst 会终止 VMM。不要回滚/覆盖 VM 磁盘。
9. **禁止修改/commit/push 原 `~/Desktop/book-buster`**。已有 `.godot/uid_cache.bin` 与 `Scenes/SplashScreen/logo_splash_screen.tscn` 两个 dirty 文件是用户原有变更。测试只在本仓库 `.diag/` 隔离副本进行。
10. 用户当前 Devin weekly quota 几乎用完，要求尽快交接。不要重新跑全部历史测试、盲目下载大件或一上来构建新包；先做必要的新启动验收，再选择一条有证据的新研究任务。

## 1. 最新实际状态：重启与88安装

### 1.1 用户刚报告的事件

- 用户称隔壁 **macPad 项目做了一些操作后，虚拟机满载卡死，强制关闭也无法关闭**，因此重启 iPad、重新越狱，重新进入 VM。
- 用户顺便安装了88，要求轻量检测并迅速完成 handover。
- **这是用户报告的时间关联，不是根因证明**。没有取得卡死前采样、完整宿主日志或 panic 报告，不能归因于 macPad、86/88、GPU 或某个 patch。
- 不得操作 macPad 来“复现”，不得把旧86的无panic结论推广到这次卡死。

### 1.2 这次启动已经轻量核验的结果

| 项目 | 当前实测 |
|---|---|
| 客机 boot time | `2026-10-02 22:47:19`（`sysctl kern.boottime`） |
| 核对时 uptime | 约6分钟；load averages `4.13 14.74 9.94`，仅快照，不是GPU归因 |
| `/Library/VirtualMac/.build` | `88-46e1996c7b58fd11` |
| 已安装 GL SHA256 | `4bf929ed591f080ae2c459d5c7d2ee507556e4579dcc6db76e4b9aba33617ca2`，与88包内一致 |
| `codesign --verify --strict` | 通过 |
| 当前 GPU 统计 | `recoveryCount=0`、`lastRecoveryTime=0` |
| 显式加载安装库后的只读查询 | Mac2=0、legacyMac2=0、targetless=0、argbuf=0(tier1) |
| 设备/数组/observer寿命探针 | 50轮跨 autorelease-pool 通过，无GPU绘制/压力工作 |

原生查询清空 `DYLD_INSERT_LIBRARIES` 后：Apple1–5、Mac1/2、Common1–3；readWriteTextureSupport=2、PullModelInterpolation=YES；argbuf=0(tier1)、samplers96；dynamic libraries/function pointers/raytracing/barycentric仍NO。

**原生无shim的Mac2=YES与加载88兼容库后的Mac2=NO并不矛盾**：前者是Apple原始声明，后者是已安装库的动态一致性处理。记录查询环境，不能混用。

### 1.3 尚未核验的项目

- 本次88宿主 dpkg/App build、VMM启动profile、实际字段与augmentation计数；需要新启动日志。
- 当前 GUI/正常启动的 Godot 是否自动继承目标 shim，而非仅诊断进程显式加载。
- **安装后的88** OpenGL/Vulkan实际场景；过去测试是在86宿主上加载候选/解包88库。
- 重启前卡死的根因、有没有宿主panic、功耗、长时间稳定性、性能收益。
- MATLAB/Chromium/Electron/Qoder及其他具体应用的真实GPU功能。
- NAS远端同步完成状态；本地飞牛目录的文件已经hash核验。

## 2. 环境与安全边界

### 2.1 环境地图

| 项目 | 内容 |
|---|---|
| 客机 | `VirtualMac2,1`，macOS15.6.1(24G90)，8vCPU/10GB |
| 宿主 | iPad Pro11 M1，iPad13,11，iPadOS16.3(20D47)，Dopamine3.0.2 rootless，16GB |
| SSH | `root@192.168.64.1`，端口22曾通过密码认证；2222也有历史记录，先检查真实可用端口 |
| 凭据 | **本文没有密码**。需要时向用户索取或使用其安全提供的认证，不保存到脚本/文档/Git，不打印secret |
| App | `/var/jb/Applications/VirtualMac.app`（rootless实际目标在preboot/procursus下） |
| 宿主payload | `/var/root/VirtualMac/payload/` |
| VM数据 | `/var/mobile/Media/VirtualMac/Sequoia.bundle/` 等；不要修改或复制覆盖 |
| 本地飞牛 | `/Users/ciscohe/Library/CloudStorage/飞牛同步-HomeNAS/VirtualMacOniPad_iOS/` |
| 工具 | Xcode/clang、dpkg-deb、ldid、codesign、llvm-objdump、sshpass/expect、taskpolicy |
| IDA | IDA9.2；Instance1–3为别的项目所占，Instance4曾用于本项目，需先确认当前二进制与实例状态 |

- 宿主 iPad 只读取证为默认边界。用户允许过小型用户态查询探针、必要的小文件传输和临时诊断文件，但不等于允许任意宿主操作。
- **禁止未经明确审批**：重启/kill系统服务、sysctl写、nvram写、内核操作、向运行中VMM/PG注入或hook、全文件系统扫描、可能使宿主panic的实验。
- 用户曾接受一次审计后的实验包风险，**不能推广为主动安装、重启、运行中注入或任意新风险步骤授权**。
- 安装包前正常关闭VM。不可从正在运行的这台客机直接执行宿主安装来中断自己。
- 不读取/改写其他应用状态数据库；不要重试 `state.vscdb` 一类“内存迁移”。
- 默认编译5 jobs，`NUM_JOBS=5`、`CMAKE_BUILD_PARALLEL_LEVEL=5`、`taskpolicy -b`。GPU测试串行，不与macPad的GPU/编译重载并行。
- 无系统 `timeout`；用工具自带timeout、Python subprocess超时或后台进程。没有fakeroot/Theos，不要假设已装。
- 需要agent并行时先征得用户同意/遵守当前CLI规则；本文不要求不可用的私有工具或特定vendor。

### 2.2 仓库边界与Git

- 只写当前 `VirtualMacOniPad`。`VMGPU/` 是黄金基线，只读。macPad、Patch与原book-buster只读，除非用户另有针对性授权。
- 不提交第三方二进制、反汇编、抓取shader/AIR/SPIR-V、VM镜像、密钥或大诊断包；取证保存在ignored `.diag/`。
- 保留用户dirty文件。禁止checkout/reset/stash/restore来制造“干净基线”，不得force push/改Git配置/绕过hook。
- 提交只stage明确任务路径，commit英文ASCII；按本项目用户规则，提交后立即push `origin main`。认证/权限失败时停下告知，不改安全配置。
- 新CLI自身配置若确有需要，遵守当前CLI配置规则；本文只是项目文档，不要求给Codex写全局配置。

## 3. 源码、提交与交付包

### 3.1 当前源码

交接核对时：

```text
HEAD = origin/main = bb005a7dfea749e26aae42e43ed2d43e83441dff
```

这是真正的88功能源码提交，已推送。关键历史：

| 提交 | 含义 |
|---|---|
| `5906e1b` | 旧GPU mappedAddressForOffset/映射校验修复，背景见专项文档 |
| `c137b1306a` | 旧默认全开deviceInfo实验表，未完成端到端验收 |
| `b87c465` | Godot限定粒子shader修复及相关记录（不是build87） |
| `598e6cda24` | build84保守Godot修复包，实验扩展默认off |
| `341fb8f146` | 宿主裁剪profile、回复地址/容量修复，build86 |
| `867ea956075ec98879876b6055d58dd471b1cd22` | 文档提交；build87功能配置与86一致 |
| `bb005a7dfea749e26aae42e43ed2d43e83441dff` | 88新增Mac2能力一致性修复与CPU回归 |

交接开始时 dirty：`AGENTS.md`、`docs/WORKLOG.md` 是**包后交付记录**；三个untracked探针可执行件 `VirtualMac/vz/development/probes/mtl-caps-dump{,-ios,-ios64e}`，不要误stage。本文更新后handover文档也会dirty。

提交号与build号相关但不等同：App build使用Git提交总数。后续仅文档commit也会递增计数；**不会改变已构建88的来源**。不要为了永远保持数字88去amend/reset已推送历史。

### 3.2 包清单

两处交付目录：`VirtualMac/build/release/` 与本地飞牛 `VirtualMacOniPad_iOS/`。没有覆盖旧包。

| 文件 | 用途/状态 |
|---|---|
| `VirtualMac_1.2.3_a983c775b6.deb` | 旧预提交构建，来源标记不齐，不推荐；未证明必然无法运行 |
| `VirtualMac_1.2.3_c137b1306a.deb` | 旧全开实验表，不推荐恢复默认全开；飞牛曾复制 |
| `VirtualMac_1.2.3_598e6cda24.deb` | **84保守回滚基线**，用户安装过且Godot正常 |
| `VirtualMac_1.2.3_341fb8f146_GPUExperimental.deb` | **86**，安装后guest与host扩展启动验收完成 |
| `VirtualMac_1.2.3_867ea95607_GPUCombinedFull.deb` | **87**，完整重构建但功能与86一致，未获安装反馈 |
| `VirtualMac_1.2.3_bb005a7dfe_GPUCombinedFull88.deb` | **88最新完整增强包，用户现已安装** |

精确指纹：

| 项目 | 84 | 87 | 88 |
|---|---|---|---|
| 版本 | `2:1.2.3+84.598e6cda24` | `2:1.2.3+87.867ea95607.gpucombined` | `2:1.2.3+88.bb005a7dfe.gpuvulkan` |
| 预期GuestTools | `84-513cc8ea9272d5f3` | `87-477fc0fc695d8790` | `88-46e1996c7b58fd11` |
| deb字节 | 20860496 | 20857004 | 20857348 |

```text
84 deb SHA256:
59a5130ab76bab424dda26d74907d9358ed4a2d52603ac5850d965f967d38307
86 deb SHA256:
4b5adc68ccc156cb340be92115d7703676171bed8a2a2d7b4f2704829ba9b3c1
87 deb SHA256:
847bba626efb7d1daf95782c35f6ee79f16d6d6c039e56351bfb6f57838812fd
88 deb SHA256:
33258ae583c9e14c8b7b8373fbc7c3d027235fb7bc75f20f9426730cadde9811

86 GuestTools:
86-7c3f1508d5328f78
86 GL SHA256:
28b4f670311bfc5292e776f23f16e3e1fbb5db5b83d007874255f69d189e0150
87 GL SHA256:
08aaeb5014a27e2ce3d8a5063e6d4be67243e173b9f0408c9cbbf39e05da0529
88 GL SHA256:
4bf929ed591f080ae2c459d5c7d2ee507556e4579dcc6db76e4b9aba33617ca2
```

88包签名、trustcache、来源、App/VMM/Metal编译输出hash、三架构GL与不包含VM数据已核验。93个Mach-O最低平台/系统版本检查与stage audit通过。**iPadOS14.5完整ABI audit因缺DSC而跳过**，不能说支持列表全实测通过。

构建期间有既存dynamic_lookup/UIKit deprecation及工具shadow-framework缺符号警告。构建exit0不等于所有媒体功能可运行；不要忽略真正新增错误，也不要把所有旧warning都当本次GPU故障。

## 4. GPU架构与真实缺口

### 4.1 数据路径

```text
客机应用（Metal，或OpenGL→AppleMetalOpenGLRenderer，或Vulkan→MoltenVK）
  → 客机AppleParavirt Metal插件/驱动
  → PVG命令、GPU资源映射、Metal序列化
  → 宿主VMM + Ventura ParavirtualizedGraphics/MetalSerializer
  → iPadOS16.3原生AGXMetal/M1
```

- payload来自macOS13.2.1：PG13.0.34、VZ104.7.1；客机Metal插件40.7.1(macOS15.6)。代差是核心研究背景。
- Ventura PGFIFO分发最高opcode0x40；客机有0x41–0x44，但正常通过feature/binaryVersion/serializer协商避免发送。`faultAtOffset`会停车等待quiesce，可能楔住通道，而非每次产生崩溃报告。
- **宿主GPU支持某API，不证明PG传输、资源生命周期、序列化器和客机编码链全支持它。** 不能只返回YES。
- 历史每日gpuRestart风暴有`submitEvent:INCOMPLETE`签名；AGX拒绝合法序列化内容是疑点，不是已经排他的根因。
- Reims vGPU是同协议的独立Rust重实现，可作协议/decoder oracle；不是把它替换进VMM就自动改善性能。静态规格仍需用本机15.6.1/13.2.1二进制核对，不能把macOS26分支的版本表套到这里。

### 4.2 既有修复不能丢

- `pvg_trace.m` 的分段GPU任务地址转换、已映射区间覆盖校验和安全拒绝；旧`base+offset`回退有真实崩溃背景。
- `metalshim.m` 的BC纹理兼容路径。
- Guest OpenGL启用、Apple7 GLD profile、冗余default raster sample count和已知不兼容自定义sample position处理、Rosetta顶点内联等。
- Godot限定shader等价转译。
- deviceInfo回复地址和容量修复、宿主裁剪策略。
- 88完整Mac2声明一致性处理。

不要把“84关闭deviceInfo扩展”解释为关闭了以上所有GPU修复。

## 5. Godot故障：两条独立因果链

### 5.1 OpenGL GPU粒子shader崩溃

- Godot版本：`/Applications/Godot.app/Contents/MacOS/Godot`，4.1.1官方版。
- 项目：原 `~/Desktop/book-buster`；测试副本 `.diag/godot-vulkan/book-buster-test`。
- 标题场景：`res://Scenes/tittleScreen/pre-titleScreen.tscn`（拼写就是tittleScreen）。20个节点，1个GPUParticles2D节点，配置1000粒子。
- 原PVG加速GL、粒子开启，稳定崩在：

```text
glLinkProgramARB_Exec → gleLinkProgram → ShLink → glpLinkProgram
→ glpLLVMCGTopLevel → ... → glpLLVMCGSwitchStatement +176
EXC_BAD_ACCESS/KERN_INVALID_ADDRESS，0x10
```

- 普通CLI直接启动可能没有继承shim，实际用Apple Software Renderer；那不是有效GPU对照。
- 仅诊断实例关闭粒子后60帧通过；不能把关粒子当交付修复。
- 抓到vertex shader中的 `switch (align_mode)` 四个独立case，首case为空；**不是已证实的fallthrough**。
- 正式实现只匹配固定uniform/输出/枚举、case顺序、brace block、末尾break，等价改成if/else；未知shader原样放行。并非通用GLSL parser，不能泛化成任意switch转译。
- 关闭 `VIRTUAL_MAC_OPENGL_PARTICLE_SWITCH_LOWER=0` 恢复同栈exit134；启用最终库连续3次60帧与GPU读回成功；普通indexed VBO/uniform读回正确、GL error0。
- 改写在shader提交/编译阶段，不是每帧CPU改shader。没主动减粒子或画质；**未有数据证明性能完全无损**。
- 项目资源/UID/空shader-global及退出资源未释放warning仍存在，不要当成全部修复，也不要全部归咎GPU。

### 5.2 Vulkan/MoltenVK无附件渲染不匹配

- Godot4.1.1 macOS构建静态链接MoltenVK1.2.0。曾因bundle没Frameworks猜测“缺动态loader”，已纠正；不要重复无依据安装Vulkan SDK。
- 原生guest `supportsFamily(Mac2)=YES`，但 `supportsRenderPassWithoutRenderTarget=NO`。
- MoltenVK1.2.0以Mac2推断 `renderWithoutAttachments=true`，导致原生Metal validation `No valid pixelFormats set`、exit-6。
- 最早诊断只将Mac2固定NO，让MoltenVK走原生dummy attachment fallback，RGB/3D/粒子可读回；该硬编码诊断库**不是正式修复**。
- 88正式版本：在三个Metal设备工厂入口，依运行时`APVFeatures`类型识别PVG，验证BOOL返回及q/Q参数ABI；仅在native声明为true且原生getter明确NO时收窄Mac2和等价legacy feature set10005。
- 缺getter、未知ABI、其他family/feature-set原样放行；非APV不处理；GL既有Apple7 profile保留。没有改descriptor/rasterization、关粒子或跳过Metal校验。
- 工厂 `MTLCreateSystemDefaultDevice`、`MTLCopyAllDevices`、`MTLCopyAllDevicesWithObserver` 返回必须保持 **NS_RETURNS_RETAINED +1**；observer初始列表/通知在转交前处理device，不改变原observer生命期。
- 关闭 `VIRTUAL_MAC_METAL_FAMILY_COMPAT=0` 恢复原pixelFormats崩溃，因果对照成立。
- 这会收窄一组不完整声明；可能同时让依Mac2推断的swizzle/heaps走fallback。不是新增所有Metal功能；未测其他应用、全部MoltenVK版本或性能。

## 6. deviceInfo扩展：已经恢复什么、还没开什么

### 6.1 84→86→88的策略

- 旧c137参考表默认尝试Apple9、SupportFlags2024=4095、AIR2.7等，未有完整验证。
- 84用新preference `PVGDeviceInfoCapsExperimental` 默认off；旧key/env不能自动启用，不传遗留extra。
- 86/87/88 App默认启用 `host-clamped-v1`，显式新preference=false可关；VMM新env `PVG_DEVICEINFO_CAPS_EXPERIMENTAL`仅精确`1`可启用。没有持久化默认值破坏84回退。
- 旧源码参考数组仍存在，**不是当前默认发送表**；`PVGDeviceInfoProfile.h`逐getter查询裁剪，`PVG_DEVICEINFO_EXTRA`仅允许收窄，不允许加key/扩大能力/提高serializer。
- 未经请求不要改开关；重启后的88实际profile需新host日志确认，不能复用旧文件。

### 6.2 两个回复bug已经修正

1. `_PGDevice` 的 `_rootTaskBase` 是宿主指针，旧代码误作guest页内偏移会提前退出。通过既有hv_vm_map找同一guest物理页，从页首offset0扩展。
2. 页尾容量0时 `capacity-1` 下溢，可能越界。owner级reply代码检查页界限、必要哨兵、容量与未知输入；CPU ASan/UBSan覆盖全部16385个页偏移。

### 6.3 86宿主实际发出的12个字段

```text
profile=host-clamped-v1 pairs=12 serializer=unchanged
23=1      TileShaders
25=1      RasterOrderGroups
28=5      Apple5 | Texture2DMultisampleArray（dynamic stride bit未开）
29=1024   MaxComputeThreads
30=32768  MaxComputeLocalMemory
31=32768  MaxComputeTGMemory
32=16     ComputeTGMemoryAlign
33=224    ArgumentBuffers | SIMDReduction | Float16BCubicFiltering
34=8      GPUCoreCount
35=2048   MaxTextureLayers
37=1007   HostGPUFamily上限Apple7
40=256    MinLinearTextureAlign
caps augmented keyLimit=42 count=2048 existingApplied=12 dropped=0
```

这是旧86首启日志的真实值。字段到达不等于所有私有getter/协议门都开启，不等于shader执行或性能证明。

### 6.4 仍关闭/未添加/未打通的内容

| 类别 | 当前处理与原因 |
|---|---|
| key17 BufferFromIOSurface、19 SharedTextures | 不额外开启，资源/传输契约未证明 |
| key18 AIR2.7、key10 serializer升级 | 不提高，编译器/序列化契约未证明 |
| key21 programmable sample positions | 已知serializer不匹配，不开启 |
| key24 Imageblocks、26 MemoryOrderAtomics、27 LargeMRT | 本机查询没有可接受YES，未追加；不证明M1硬件一定无能力 |
| key28 dynamic attribute stride | 本机未开对应bit |
| key33 bits0–4 | LargeUserTasks/LargeKernelTasks/CommandBufferJump/RangeBuffer/SharedMemoryHeap始终不默认开启 |
| key33 bits8–9 | SIMDShuffleAndFill/ConditionalLoadStore查询未取得可接受YES；本机未开 |
| key33 bits10–11 | ComputeCompressedTextureWrite/SharedTexturePlacement不默认开启 |
| key36 predicated nesting、41 texture write rounding | 未追加，相关getter/执行契约不明确 |
| key37 Apple9 | 错误M1声明，裁剪到Apple7，不是待恢复优化 |
| amplification/rasterization-rate/2025 fields | 不添加未经验证路径 |
| dynamic libs/function pointers/raytracing/barycentric | 原生guest仍NO；不属于“Godot把已实现硬件功能关掉了” |

### 6.5 Argument buffers的枚举与协议真相

- **MTLArgumentBuffersTier1=0，Tier2=1**。以前把0解释成无argbuf、1解释成tier1的结论已撤回。
- 宿主M1查询为Tier2，guest现在为Tier1。
- guest getter同时要求 `APVFeatures.supportsArgumentBuffers` 与SupportFlags2024 bit5。
- 只读运行时确认APVFeatures该成员false；本机15.6.1版本表在**207这一档**才开启，Ventura最高43。不照搬Reims其他OS分支的62等数字。
- 即便key33 bit5送到guest，第一道门仍不满足。**不能盲加38/39、把getter改YES、把binaryVersion抬207或把serializer改8**。
- 要真做Tier2，需要恢复207新增的wire/resource/encoder契约并证明host执行，或在已实现协议上做契约完整的兼容路径；不一定是短期可行工作。
- key38/39是否有消费者的结论来自现有对照研究，仍需本机二进制验证；不要据此声称发送就能启用Tier2。

## 7. 证据与工具索引：不要重复做历史工作

所有 `.diag/` 证据是本机ignored资料，克隆仓库不会自动带走。若换机器，用户需另行复制必要证据；不把大目录/二进制commit。旧包核验receipt中的 `installed=false` 是打包时点的记录，不要改写它来冒充首启验收；当前88轻量验收另存下表新目录。

| 路径 | 用途 |
|---|---|
| `.diag/build88-first-boot-acceptance/receipt.json` | 当前重启后88安装件/hash/signature/只读门控/原生caps轻量验收；host与绘制未验 |
| `.diag/build86-first-boot-acceptance/` | 旧86 guest caps、GL场景PNG/log、IOReg、host VirtualMac/VMM logs、receipt、argbuf静态分析 |
| `.diag/accept-build86-current.py` | 旧86实际安装GL验收runner；路径/期待值固定，不能当88新启动脚本直接复用 |
| `.diag/collect-build86-host.py` | 小型host日志只读采集，默认输出旧86目录，不要覆写旧证据 |
| `.diag/godot-vulkan/` | GL故障捕获、诊断库、最小render-check、scene-check、隔离book-buster-test |
| `.diag/build88-render-check/` | 候选88库的baseline/fixed/disabled/gl/vulkan-scene结果与PNG |
| `.diag/inspect-guest-argument-gates.m` | runtime字段/类型的只读查询，复杂bitfield NSGetSizeAndAlignment会拒绝，不能猜offset读取 |
| `.diag/metal-family-live.m` / 对应可执行件 | 只读family与MRC设备/数组/observer寿命探针，不提交GPU工作 |
| `.diag/gpu-vulkan-build/verification-receipt.json` | 88来源、版本、hash、GuestTools标记、解包shim路径 |
| `.diag/gpu-vulkan-build/packaged-render-check/` | 实际88 deb库的抽测fixed/gl/vulkan-scene |
| `.diag/gpu-vulkan-package-check/guest-check/Library/VirtualMac/OpenGLPVGCompat.dylib` | 实际88包提取库 |
| `.diag/gpu-combined-build/` | 87构建/核验/GL回归 |
| `.diag/gpu-enhanced-build/` | 86构建/核验/GL回归 |
| `.diag/guest-kext-15.6.1/` | 本机guest kext及反汇编，只读、本地，不入库 |
| `.diag/reims-vgpu/` | 协议oracle，阅读其nested AGENTS/CLAUDE；不修改、不把第三方bytes/disasm入Git |

上一轮测试数字：

| 条件 | 结果 |
|---|---|
| 86安装后GL标题 | 60帧1152×648、nonblack8692、exit0、recovery0 |
| 87实际deb GL库，在86宿主 | 3×60帧，8700/8698/8698、exit0 |
| 88候选库Vulkan基础 | 3×30帧、RGB误差0、3D中心绿色、粒子白像素507/510/561 |
| 88候选库Vulkan标题 | 3×60帧、8697/8705/8706、exit0 |
| 88候选库GL标题 | 3×60帧、8699/8698/8703、exit0 |
| 88 baseline / 关闭新family修复 | 两者都恢复pixelFormats校验崩溃、exit-6 |
| 实际88 deb库基础抽测 | 30帧、RGB误差0、中心绿、白像素584 |
| 实际88 deb库GL/Vulkan标题 | 各60帧、8700/8704、PNG成功、exit0 |

两条标题最后PNG人工查看过。GPU读回是测试oracle，进程存活/打印设备名不能替代。新安装88还没有复跑绘制测试。

**负对照会生成预期Godot崩溃报告**：不要把本轮baseline/disabled报告当成“正常88又崩了”。注意时间、加载库、开关和进程命令。

## 8. 源码阅读入口与验证命令

### 8.1 源码地图

| 文件 | 责任 |
|---|---|
| `VirtualMac/vz/host/pvg_trace.m` | PGFIFO、GPU映射/覆盖、deviceInfo method hook与日志 |
| `VirtualMac/vz/host/PVGDeviceInfoReply.h` | 受界限约束的回复owner，容量/哨兵/覆盖规则 |
| `VirtualMac/vz/host/PVGDeviceInfoProfile.h` | 宿主查询及字段裁剪，不以设备名强猜能力 |
| `VirtualMac/vz/host/PVGDeviceInfoPolicy.h` | preference/env启用契约 |
| `VirtualMac/vz/host/VirtualMacApp.m` | App配置、profile默认选择、传给VMM的环境 |
| `VirtualMac/vz/host/vmmhook.m` | host兼容层/hv映射/内存等；研究前确认真实Owner |
| `VirtualMac/vz/host/metalshim.m` | BC等宿主Metal兼容 |
| `VirtualMac/vz/guest/OpenGLPVGCompat.m` | GL路径、shader转译、88native family/legacy一致性、Metal工厂ownership |
| `VirtualMac/scripts/tests/metal-family-compat-test.m` | 88CPU owner级回归 |
| `VirtualMac/scripts/tests/opengl-particle-shader-test.m` | 限定shader识别/等价转译/未知输入放行 |
| `VirtualMac/scripts/tests/deviceinfo-*-test.*` | reply/profile/policy回归 |

遵循已有库/代码风格，不随意新增依赖、修改安全策略或伪造成功。默认不增加/删掉代码注释；必要变更先确认当前规则。

### 8.2 轻量版本/安装核对（可以首先做）

```bash
cd /Users/ciscohe/Desktop/VirtualMacOniPad
git status --short
git log -4 --oneline
cat /Library/VirtualMac/.build
shasum -a 256 /Library/VirtualMac/OpenGLPVGCompat.dylib
codesign --verify --strict /Library/VirtualMac/OpenGLPVGCompat.dylib
sysctl kern.boottime
```

用当前CLI的读文件工具替代cat也可以。不要创建/写入密码文件。IOReg只查询目标class和PerformanceStatistics，避免巨大树输出。

只读新库探针（本机已有可执行件，先确认存在）：

```bash
DYLD_INSERT_LIBRARIES=/Library/VirtualMac/OpenGLPVGCompat.dylib \
VIRTUAL_MAC_OPENGL_DEBUG=1 .diag/metal-family-live complete
```

原生caps对照需清空注入环境。现有untracked `mtl-caps-dump` 可执行件打印0未必带枚举名称，要按SDK解释为tier1；源码与可执行件版本可能不同，不拿日志格式当能力变化。

### 8.3 CPU回归（只在改相关代码后重跑）

```bash
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -DGL_SILENCE_DEPRECATION \
  -framework CoreFoundation -framework Foundation -framework IOKit \
  -framework Metal -framework OpenGL \
  VirtualMac/scripts/tests/metal-family-compat-test.m -o /tmp/metal-family-compat-test
/tmp/metal-family-compat-test

clang -fobjc-arc -fblocks -Wall -Wextra -Werror -DGL_SILENCE_DEPRECATION \
  -framework CoreFoundation -framework Foundation -framework IOKit \
  -framework Metal -framework OpenGL \
  VirtualMac/scripts/tests/opengl-particle-shader-test.m -o /tmp/opengl-particle-shader-test
/tmp/opengl-particle-shader-test

clang -Wall -Wextra -Werror -fsanitize=address,undefined \
  VirtualMac/scripts/tests/deviceinfo-reply-test.c -o /tmp/deviceinfo-reply-test
/tmp/deviceinfo-reply-test

clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework Metal \
  VirtualMac/scripts/tests/deviceinfo-profile-test.m -o /tmp/deviceinfo-profile-test
/tmp/deviceinfo-profile-test

clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  VirtualMac/scripts/tests/deviceinfo-policy-test.m -o /tmp/deviceinfo-policy-test
/tmp/deviceinfo-policy-test
```

按当前CLI要求先验证输出父目录，避免覆盖已有用户文件。sanitizer可加到family回归，已有结果通过。不要为了通过测试降warning等级或绕过ABI检查。

### 8.4 构建与打包

- 正规链：`VirtualMac/scripts/build-ipad-vm.sh`、`build-ipad-app.sh`、`build-ipad-deb.sh`，具体用法见根AGENTS和构建专项文档。
- 本轮完整独立构建脚本：`.diag/build-gpu-vulkan.sh`；5jobs/background，复用提取framework/既有辅助组件，重建VMM、Metal、App、GuestTools。
- 它拒绝覆盖已有 `.diag/gpu-vulkan-build`，且硬要求Git count=88。**不要直接重跑它**：目录已存在；文档commit后count也变了。下一包用新的独立输出目录/来源版本，保留88。
- 核验 `.diag/verify-gpu-vulkan-deb.py`；从deb提取payload、检查源码/版本、编译库hash/signatures/trustcache、GuestTools三架构、无VM数据。也拒绝覆写已有核验目录。
- 导出 `.diag/export-gpu-vulkan-deb.py`；原子排他创建目标，不覆盖，核对hash和84回滚。
- 实景脚本 `.diag/test-build88-render.py`、`.diag/test-gpu-vulkan-packaged.py` 固定旧目标目录，很多目录已存在，会拒绝重用。新首启必须换新证据目录、明确安装库，而不是改旧历史测试结果。
- 构建guest兼容库：`VZ_OPENGL_GUEST_BUILD=<新的目录> taskpolicy -b bash VirtualMac/scripts/development/build-opengl-guest-compat.sh`。
- framework重建必须用已有a2sb缓存保持忠实；macOS15 dyld_info/ld读不了部分重建chained-fixups，使用llvm-objdump与已有`-Wl,-ld_classic`流程。不重下载12/13GB IPSW、不重建无关组件。
- Xcode16+ MetalToolchain可能独立安装；先检查，不直接启动大下载。

## 9. 新启动宿主日志与卡死取证

### 9.1 先分清时间线

旧86验收在21:03启动之后；当前88客机boot=22:47:19，且宿主发生过强制重启。`/tmp`旧日志可能已消失。`.diag/build86-first-boot-acceptance/`是保留下来的旧证据，不是当前宿主状态。

旧86host曾确认：profile12字段成功、无新panic/VMM崩溃；有225/s wakeups，`Action taken:none`，旧版也有同类。**不能用这条历史结论说明本次重启无异常**。

### 9.2 新88验收优先取最小内容

取得认证后只读：

- `dpkg-query` 的com.mac.virtual版本、App Info.plist/build信息。
- `/tmp/VirtualMac.log`、`/tmp/vmm.stderr.log`（旧采集每份限制2MB；不要无限tail巨大文件）。
- 最新段的profile、actual key/value、`caps augmented ...`、VM启动/GuestTools ready信息、GPU故障消息。
- 已知CrashReporter/Panics目录的近期条目列表；仅取与卡死/重启时间相关的小报告。不要全盘扫描。

不要把`guest_did_panic`等RPC handler注册名当作panic事件；看事件时间/调用记录/报告内容。

不要因 `BatchMode=yes` 无密码认证失败就说SSH不通；网络、banner、认证是三层。登录失败不改sshd/认证配置。无法认证就请用户导出两份小日志到飞牛。

App的Export Diagnostics可有约1.1GB zip。先列条目并只提取需要的logs/crash reports，避免拉整包。保存新目录如 `.diag/build88-first-boot-acceptance/`，保留旧86。

### 9.3 对刚才卡死的研究闸门

1. 用户可提供macPad当时的命令、时间、CPU/内存/IO/GPU工作负载；该项目只读，不干预运行。
2. 收集时间对应宿主报告/当前日志和客机重启前遗留报告，确认是否有GPU fault、VMM死亡、内存压力/相关Jetsam、调度/IO饥饿或纯用户态卡住。host `vmmhook.m` 有VMM内存放宽到2×physical的兼容逻辑，是实际资源约束研究入口；不要因此直接改限额/VM内存或认定它就是根因。
3. **有归因证据才选路径**；没有证据就标“未定位”，不编新包宣称解决。
4. 若需新风险复现/压力测试，先列具体操作、风险与回滚，并向用户单独请求许可。不要在这台承载会话的客机上进行不可控实验。

## 10. 下一任任务清单与优先级

### P0：88本次启动验收，不改功能

- [ ] 阅读本文/根AGENTS/WORKLOG末尾/研究O节，确认dirty文件、最新用户指令、当前版本。
- [ ] 保存新boot的guest版本/hash/signature、IOReg及查询环境；轻量结果已在§1，避免机械重跑。
- [ ] 取新host App/VMM日志，确认88版本与host-clamped-v1实际字段、augmentation、错误。
- [ ] 原生/注入后的cap分别记录，tier1不算回归；不要误报Mac2差异。
- [ ] 在**隔离副本**上让安装88库跑GL标题60帧；stdout确认PVG加速、转译、粒子保留，PNG读回，exit0，GPU恢复计数不增加。
- [ ] Vulkan优先最小RGB/3D/粒子30帧，正确RGB/中心/粒子读回后才实际标题60帧。必须同步诊断项目renderer配置；原book-buster不要改为Forward+。
- [ ] 3次独立重复可作为间歇问题闸门；正常GUI注入路径至少核对一次。现在只知道显式加载的轻量查询生效。
- [ ] 不为了验收再安装/重启，除非用户希望；截图确认、资源warning与GPU故障分开报告。

### P1：卡死取证与性能基线

- [ ] 先完成§9卡死时间线及关联证据，避免“隔壁项目所以肯定是macPad”的归因。
- [ ] 用户同意后做短时、限定负载的CPU/内存/IO/GPU观察；不要并行压力任务。
- [ ] 选代表场景测加载时间、平均/p95帧时间、分辨率、粒子数量、运行时长及recovery；记录功耗条件/温度可用程度。
- [ ] 原未修复GL场景直接崩，无法做正常FPS对照。性能对照需选能正常运行的基线/独立等价shader，不用“能跑”证明快/无损。

### P2：真正的新增GPU增强，逐契约推进

- [ ] 优先依据实际应用的新崩溃/错误选择工作，而非追逐全部能力YES。
- [ ] 若继续Tier2：恢复207相对于43的feature、opcode、resource/argument-buffer布局、寿命/同步、序列化契约；判断host是否可实现，再决定可行路径。先静态/CPU拒绝测试，不直接提升版本在live VM试。
- [ ] 审计当前已发送而尚未完整执行验证的TileShaders/ROG/SIMD等；写最小shader/readback测试，分字段验证，不扩4095。
- [ ] getter没有可接受YES时先判定是selector/ABI/OS缺失还是明确unsupported，不按M1名字硬开。
- [ ] 88family一致性修复的未知ABI、多设备/代理/observer、GUI不同应用、跨架构等覆盖仍可加强；先复现，别替换成固定NO。
- [ ] MATLAB/CEF/Electron/Chromium各自报错单独定位。原Patch/MATLAB只读；不得撤掉--disable-gpu后凭进程活着说成功。
- [ ] 新包只在有真正新增且验证过的修复时构建；保留88+84回滚、不称“完美满血”。

### 不应立即做

- “全开4095/Apple9/serializer8/协议207”、强改supportsArgumentBuffers、NOP断言、填零blob、关闭粒子/rasterization当正式fix。
- 把Reims整套替入闭源VMM、启动USB直通/macPad重移植、对其他项目进行写入或提交。
- 重建相同功能并只换编号作为“集大成”；过度跑历史测试消耗机器/额度。

## 11. 可交给下一任的启动Prompt

下面这段可直接粘贴给Codex CLI。本文是自足接手入口；无需这轮Devin会话完整历史。

```text
你现在接手 /Users/ciscohe/Desktop/VirtualMacOniPad 的原生虚拟GPU研究。
先完整阅读 docs/AGENT-SUPER-HANDOVER.md 与根 AGENTS.md，然后读取
 docs/WORKLOG.md 的末尾和 docs/GPU-NATIVE-RESEARCH.md 的N/O节。
不要依赖前任vendor私有记忆工具，使用你自己的读文件/搜索/终端工具。

最新状态：用户在2026-10-02因VM满载卡死重启iPad、重新越狱，并安装了build88。
GuestTools=88-46e1996c7b58fd11，GL哈希/严格签名匹配，安装库的只读Mac2 gate生效，
本次recoveryCount=0；88新宿主日志和安装后Godot实景尚未验收。
重启前卡死的根因未确认，不得直接归咎macPad、88或GPU。
88源码来源bb005a7dfea749e26aae42e43ed2d43e83441dff已推送，包已复制飞牛。
Tier2仍受协议门控阻塞：Ventura最高43，guest相关feature在207档才开启；
不要提高协议/serializer、假报能力或恢复Apple9/4095全开。

先只读取证并完成88本次启动验收，保存到新的独立诊断目录。
区分原生与注入查询、声明与执行、包内测试与安装测试、性能与兼容性。
之后按证据选择一个最小、可测的新增强任务，建立回归和数字闸门再改Owner。
不必机械重做所有历史实验；用已有日志、测试和代码作为起点。

只写VirtualMacOniPad；VMGPU黄金基线及macPad/Patch只读。
绝不能修改/commit/push原Desktop/book-buster，它有用户原有dirty文件。
不得重启服务/系统、注入运行中VMM/PG、改内核或做可能panic的实验，除非用户
针对具体行动重新许可。普通GPU测试串行、构建5 jobs/background。
不保存或打印SSH密码；需要认证就问用户，不改认证配置。
安装deb必须先正常关VM，不能覆盖VM磁盘；保留84/88回滚包。
保留工作树变更和第三方本地证据，不盲stage、不reset/stash、不force push。

第一条回复请简述已核对的当前状态、尚缺的证据，以及本轮最小计划；
不要只复述手册或再次询问历史中已经明确的目标。用中文交流，给证据和边界。
```

## 12. 其他文档与背景资料

- 根 `AGENTS.md`：行为、当前短摘要、常用命令；早期段落保留时点，不能忽略后来的更新。
- `docs/WORKLOG.md`：逐步记录，最新末尾与本文最新状态优先。
- `docs/GPU-NATIVE-RESEARCH.md`：主研究；G–K含旧代差/协议假设，L为Godot，N为审计profile，O为88。旧K的枚举/根因推论已纠正，不再沿用。
- `docs/VM-crash-fix-and-build-notes.md`：GPU映射旧crash和a2sb/chained-fixups构建坑。
- `docs/VMGPU-REFERENCE.md`、`VMGPU-cdhash.tsv`：黄金基线、__text忠实性和签名/trustcache。
- `docs/SOURCE-AUDIT-REPORT.md`：host源码架构/兼容hook审计。
- `docs/PERIPHERAL-PASSTHROUGH-AUDIT.md`：USB等外设盘点，非当前研究优先级。
- macPad自己的AGENTS及porting文档属于另一项目；不再要求去运行旧“命中率探针”。

如果接手时源码、版本、时间或用户指令变化，先保全证据并更正文档。不要用这份手册覆盖新事实。
