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
| **SSH 到 iPad** | `ssh -p 2222 root@192.168.64.1`（NAT 网关即 iPad；22/2222 都通；密码见用户消息，勿写入会入库的文件——本条注意：密码只保留在会话上下文，文档里写"密码问用户"） |
| iPad 上关键路径 | App: `/var/jb/Applications/VirtualMac.app` → `/private/preboot/.../procursus/Applications/`；payload: `/var/root/VirtualMac/payload/`；VM 数据: `/var/mobile/Media/VirtualMac/`（`Sequoia.bundle/`、`Settings.plist`、`Diagnostics/`） |
| 网络 | 客机经 NAT 出网；飞牛 NAS 中转 `~/Library/CloudStorage/飞牛同步-HomeNAS/` |
| 工具 | Xcode/clang/brew；`ldid`/`dpkg-deb`/`sshpass`/`expect`；IDA Pro 9.2 + ida-pro-mcp（Instance1-3 被别的项目占用；需要时让 Instance4 @13340，由用户加载二进制）；`dyldex`/`ipsw-a2sb` 在 `VirtualMac/build/toolchain/`；**iPad 探针**：iOS 版二进制须放 `/var/jb` 前缀下 + ldid 签 `iokit-user-client-class`(IOGPU/AGX 系列)+`platform-application`+`get-task-allow`，否则 MTLCreateSystemDefaultDevice 返回 nil / 被 AMFI 杀 |
| 陷阱 | **无 `timeout` 命令**（用 `nc -G`/ssh `ConnectTimeout`/后台任务）；无 fakeroot/Theos；macOS 15 的 `dyld_info`/`ld` 读不了重建件（chained fixups）→ 用 `llvm-objdump` + `-Wl,-ld_classic` |

### 🔴 iPad 侧红线（用户授权规则，2026-10-02 更新）
- **唯一硬门槛 = 不得制造 panic/一波带走宿主+VM+macPad 的风险**。除此之外用户已默认放行：拉文件、跑用户态探针（Metal/IOKit 查询等）、scp 上传小工具到 `/var/jb` 前缀、往 `/tmp` 写诊断文件等都允许。
- 仍禁止（=panic 风险）：launchctl 重启系统服务、kill 系统进程、sysctl -w、nvram 写、注入/挂钩运行中进程、内核态操作、全文件系统 find。**往 VMM/PG 等运行中进程注入 hook 也属于此类，须先问**。
- 效率约定（非安全线，但别浪费）：iPad 上不做大文件下载（诊断 zip ~1.1GB/个，只拉需要的条目）、不在 iPad 上编译。

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
- **GPU 已知大事（详见 docs/GPU-NATIVE-RESEARCH.md §G-K）**：payload=macOS 13.2.1 Ventura 提取（PG 13.0.34 / VZ 104.7.1），客机 Metal 插件 40.7.1(15.6)。客机**每日 gpuRestart 风暴**（`submitEvent:INCOMPLETE` 签名）；OpenGL 全靠客机 shim `OpenGLPVGCompat.dylib`。**IDA 已全解 Ventura PGFIFO**：`processFifo`@0x100021594 分发 32 命令（0x37=CmdExecIndirect2），opid>0x40 或未识别→`faultAtOffset`（@0x10001bdd8，condvar 停车等 quiesce）= 一条 fault 冻整条通道。guest 15.6 词表含 Ventura 没有的 0x41-0x44，但协商诚实（feature 位门控 + binaryVersion clamp≤43 + deserializerVersion 出料）→ 新 opcode 正常不发；**楔死头号嫌疑 = 宿主 iPadOS16.3 AGXMetal 跑不动合法内容**（completedHandler status==5→fault，与 metalshim 补 BC 同类）。guest kext 存档 `.diag/guest-kext-15.6.1/`。**Reims vGPU**（steelbrain，LGPL3，`.diag/reims-vgpu/`）= 同协议 Rust 重实现，opcode 表与 IDA 结果逐条一致→可作规格书/oracle。
- **能力协商差异（§K，2026-10-02 下午纠正）**：Ventura `writeDeviceInfo` 字段止于 16，guest 现代字段缺失。但 **`MTLArgumentBuffersTier1=0`、`Tier2=1`**：guest 原值 0 是 tier1，iPad 实测 1 是 tier2，并非完全没有 argbuf；此前据此声称 Chromium/Electron/Matlab 根因已定位的结论撤回。`mtl-caps-dump` 已打印枚举名称。**旧 c137b13 deb 的默认能力表尚未安全验收**：key37=Apple9 不在 M1 实测 Apple1–7 集合，key33=4095 的 12 个协议位没有全部端到端证明；不能当已验证满血包。保守新包中扩展默认关闭：新 preference `PVGDeviceInfoCapsExperimental`（仅 NSNumber true 可启用）、新 env `PVG_DEVICEINFO_CAPS_EXPERIMENTAL`（仅精确 `1`）；旧 key/env 不再启用，关闭时不传 extra。实验表本身尚未完成协议验证，不应自行开启。
- **Godot 已复现并定点修复（§L）**：4.1.1、`book-buster/Scenes/tittleScreen/pre-titleScreen.tscn`、GPUParticles2D，已安装 PVG GL shim 时稳定崩在 `glpLLVMCGSwitchStatement +176`。失败 shader 是 `switch(align_mode)` 四独立 case（首 case 空），不是已证明的 fallthrough。新 `OpenGLPVGCompat.m` 仅在识别固定枚举和 case block/终止 break 后等价转成 if/else，未知 shader 原样放行；不关闭 GPU/粒子/校验。最终构建 3 次独立 60 帧+GPU 截图、exit0；最终版关闭开关恢复同栈 crash/exit134。回退 `VIRTUAL_MAC_OPENGL_PARTICLE_SWITCH_LOWER=0`。保守修复包已输出 `VirtualMac/build/release/VirtualMac_1.2.3_598e6cda24.deb`（源 598e6cd，version `2:1.2.3+84.598e6cda24`），包内提取的 guest 库又通过 3 次独立实景读回；未安装/重启，实际渲染只验证 arm64，其他架构仅构建。安装前必须先正常关闭 VM，preinst 会终止 VMM；保留当前可启动旧包作为回退，不把未验的 c137 包视为安全基线。
- MATLAB 定位（`~/Desktop/Patch/MATLAB`）：CEF 被迫 `--disable-gpu`、Java2D 全关、figure OpenGL 曲线不显示+MSAA 毁管线（OpenGLPVGCompat 只覆盖简单场景：谎报 supportsFamily:Apple7+清 FSAA+Rosetta 顶点内联）。
- vmmhook.m = VMM 进程兼容层：`hv_*` 全套 interpose、USB HCI swizzle（restore 桥服务端）、xpc/IOService/IOSurfaceCreate 改写、VMM 内存放宽至 2×physical（GPU 重载相关的真实约束）。
- 已知疑点：客机 `system_profiler SPDisplaysDataType` 输出空；App `makeConfiguration` 有字典下标 SIGSEGV 历史崩溃（9/20，vmfix1 在装）；vzboot.m 输入类注释与运行日志矛盾。

### 2026-10-02 晚间更新：84基线与实验增强配置

- 用户已安装84并反馈Godot正常；客机 `.build=84-513cc8ea9272d5f3`、GL SHA/signature核对一致。未做性能基准，不声称零损耗。
- 用户当次明确接受实验包可能导致宿主panic/整机重启，要求审核后重建；不延伸为主动安装、重启或运行中VMM注入授权。保留84作为回滚基线，不在book-buster commit/push。
- 当前源码的新实验 profile=`host-clamped-v1`：App缺省on，新preference false可关，VMM仍仅精确env1；旧4095/Apple9参考表不直接发送。宿主family最高Apple7，shader flag逐getter查询，协议/资源位不全开；AIR/serializer保持原值，known sample-position路径不开。实际应用/性能仍待首启验收。
- c137代码的 `_PGDevice+0x1F0` 是 `_rootTaskBase`指针，不是页内offset；hv_vm_map得到物理页后从offset0扩展。新增reply owner修复容量0下溢；extra只能收窄，不能追加或扩大能力。规则以新headers为准，旧参考表不是可直接发送的能力表。研究§N/WORKLOG晚间条目含证据与测试。
- 实验包已交付release+飞牛VirtualMacOniPad_iOS：`VirtualMac_1.2.3_341fb8f146_GPUExperimental.deb`，build86/version `2:1.2.3+86.341fb8f146.gpuexp`，SHA256 `4b5adc68ccc156cb340be92115d7703676171bed8a2a2d7b4f2704829ba9b3c1`。包内GL又通过3次60帧GPU场景读回；当前仍是84宿主，不证明新profile执行。未安装/重启，NAS远端同步待确认。预期GuestTools `.build=86-7c3f1508d5328f78`；源码来源341fb8f，不随后续文档提交变化。

### 2026-10-02 21:03 首启：用户已安装86，客机与宿主扩展启动验收通过

- 用户安装86并启动新客机；`.build=86-7c3f1508d5328f78`，安装GL SHA256与包内一致、严格签名通过，HostConfiguration的OpenGLAllowed/Acceleration均true。先前“未安装/仍84”只描述构建交付时点。
- 本次只做客机能力查询、IORegistry/日志取证和一轮60帧Godot实景，不改开关、不重启、不注入运行中VMM。证据 `.diag/build86-first-boot-acceptance/`，复现脚本 `.diag/accept-build86-current.py`。
- 原生Metal探针清空DYLD_INSERT_LIBRARIES：Apple1–5/Mac1–2/Common1–3，readWriteTextureSupport=2、PullModelInterpolation=YES；argumentBuffers仍0(tier1)，dynamic libraries/function pointers/raytracing仍no。与早先K节快照有部分变化，不能代替84/86受控性能对照，也不能称全部扩展生效。
- Godot明确加载已安装86 GL库、PVG加速路径；20节点/1个GPU粒子节点，60帧1152×648、nonblack=8692、PNG成功、exit0，已查看完整标题画面。项目资源/UID及退出资源警告仍存在。IORegistry recoveryCount在测试前后均0；不是长期稳定性或FPS证明。
- 用户提供认证后通过22端口取得本次日志；原问题只是BatchMode未提供密码，不是SSH不可用。VMM确认host-clamped-v1/pairs=12、serializer=unchanged、key33=224、key37=1007、caps augmented keyLimit=42 count=2048 existingApplied=12 dropped=0；扩展实际生效。日志在上述证据目录，凭据不保存到文件。当前/Retired/Panics列表未见本次新panic或VMM崩溃；有非致命wakeups报告（225/s、Action taken:none），旧版也有同类，不能称所有问题解决。用户要求优先构建完整合并包到飞牛，沿用已审核86配置，不另开未验能力。
- 重新反汇编当前guest arm64e插件：supportsArgumentBuffers@0x1b838确实要求一处+0x31==1与另一处+0x80 bit5同时成立。Tier1不能仅据此判key33没发或profile全关；哪道门未满足待取证。

### 完整合并87交付（86配置不变）

- 用户quota有限，要求验收后立即编完整包；已独立重建 `.diag/gpu-combined-build`，功能代码与86一致，源码HEAD867ea956075ec98879876b6055d58dd471b1cd22（后一个提交仅记录），App build87/version `2:1.2.3+87.867ea95607.gpucombined`。不强开未验能力，不承诺满血/性能。
- `VirtualMac_1.2.3_867ea95607_GPUCombinedFull.deb` 已复制release和飞牛VirtualMacOniPad_iOS，两处SHA256 `847bba626efb7d1daf95782c35f6ee79f16d6d6c039e56351bfb6f57838812fd`、20,857,004 bytes一致；84回滚包仍完整。NAS远端同步未核验。
- 包内容/签名/trustcache/来源及93个最低平台版本检查通过，14.5完整ABI仍缺DSC；包内GL在86宿主3次60帧实景通过，GPU recoveryCount仍0。87 App/VMM未安装，预期GuestTools `87-477fc0fc695d8790`、GL SHA256 `08aaeb5014a27e2ce3d8a5063e6d4be67243e173b9f0408c9cbbf39e05da0529`。证据 `.diag/gpu-combined-build/verification-receipt.json`、packaged-gl-results.json。
- 86正常可继续使用，不需仅为重打包立即重装87；若安装必须正常关闭VM。未改开关、重启或操作VM磁盘，本轮文档更新尚未commit/push；不要将其误认为缺少功能源码提交，包来源HEAD此前已推送。

### 88新增增强与紧急交付（已构建、核验并复制到飞牛）

- 用户明确选择研究新增增强而非仅换编号，随后quota剩5%要求立即构建交付。Tier2已定位为APVFeatures.supportsArgumentBuffers门控，当前false，207档才开启而Ventura最高43；不强升协议/serializer或假报Tier2。
- 新增完整Mac2 gate：只对运行时APVFeatures类型的设备，在识别原生BOOL getter ABI且supportsRenderPassWithoutRenderTarget=false时收窄Mac2及legacy ordinal10005。未知ABI/缺getter/其他声明保持，GL Apple7 profile保留；三个Metal工厂返回+1与observer语义保持。进程开关VIRTUAL_MAC_METAL_FAMILY_COMPAT=0可关闭，未改全局env或宿主。
- CPU red/green、严格warnings、ASan/UBSan、既有shader回归及MRC/NSZombie50轮跨pool工厂/observer寿命通过。原生baseline/关闭新修复均pixelFormats校验exit-6；新库Vulkan RGB/3D/粒子3次30帧、Vulkan标题3次60帧、GL标题3次60帧通过，最终PNG已查看。仅arm64实景；三架构构建签名完成。
- 源码与回归已提交推送bb005a7dfea749e26aae42e43ed2d43e83441dff；独立build88 exit0（5 jobs/background），93个最低平台版本/stage audit及包内容、签名、trustcache、来源通过，14.5完整ABI缺DSC跳过。已复制 `VirtualMac_1.2.3_bb005a7dfe_GPUCombinedFull88.deb` 到release与飞牛；20,857,348 bytes、SHA256 `33258ae583c9e14c8b7b8373fbc7c3d027235fb7bc75f20f9426730cadde9811`，84两处完整，86/87未覆盖，NAS远端待确认。预期GuestTools88-46e1996c7b58fd11，GL SHA4bf929ed591f080ae2c459d5c7d2ee507556e4579dcc6db76e4b9aba33617ca2。
- 实际deb提取库再抽测Vulkan RGB/3D/粒子30帧（差0、白像素584），GL/Vulkan实际标题各60帧、PNG读回、exit0（nonblack8700/8704）；证据 `.diag/gpu-vulkan-build/packaged-render-check/` 和verification-receipt.json。未安装/重启，App/VMM整包首启待验，不伪装全部Metal/所有应用/性能已验证；先正常关VM再安装。book-buster仅原有两个dirty文件，未修改/提交/推送。本段包后记录尚未提交，不影响已推送的功能源码。

### 2026-10-02 22:53后最新状态：iPad重启，88已安装，正式交接

- 用户报告macPad操作期间VM满载卡死且无法强关，随后重启iPad、重新越狱并安装88。时间关联不是根因证明；未取得卡死前采样/新host报告，不能归因macPad或GPU/88。此前“88未安装”只描述包构建/抽测时点。
- 当前guest boot=22:47:19，`.build=88-46e1996c7b58fd11`，安装GL SHA4bf929ed591f080ae2c459d5c7d2ee507556e4579dcc6db76e4b9aba33617ca2及严格签名通过；recoveryCount/lastRecoveryTime=0。显式加载安装库的只读查询Mac2/legacyMac2=0、targetless=0、argbuf0(tier1)，50次跨pool工厂/observer寿命通过。原生清空注入仍Mac2=YES/Apple1–5、RW texture2/PullInterpolationYES、动态库/函数指针/光追/barycentricNO，环境不同不是矛盾。
- 88这次启动的新App/VMM日志、实际profile/字段、Godot实景/正常GUI注入和长期稳定性仍待验收。不要复用旧86日志冒充新启动，不跑压力/运行中VMM注入，重启前卡死待取证。原book-buster仍只有原来的两个dirty文件，未写入/提交/推送。
- 自足接手手册已重写 `docs/AGENT-SUPER-HANDOVER.md`（含最新状态、精确包/库指纹、源码/证据地图、已纠正结论、操作边界、P0/P1/P2任务、验证命令及Codex启动prompt）。新Agent先读本文和该手册；不要求Devin/Qoder私有记忆工具，不去启动旧USB/macPad路线。
- 88功能源码来源仍bb005a7dfea749e26aae42e43ed2d43e83441dff；handover后文档提交计数可能超过88，不代表交付包换版本，不要重打相同包或改写已推送历史。`.diag`为本地ignored证据，换机器须另取必要证据。

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

### Godot 粒子 shader 回归验证

```bash
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -DGL_SILENCE_DEPRECATION \
  -framework CoreFoundation -framework Foundation -framework IOKit \
  -framework Metal -framework OpenGL \
  VirtualMac/scripts/tests/opengl-particle-shader-test.m -o /tmp/opengl-particle-shader-test
/tmp/opengl-particle-shader-test
bash VirtualMac/scripts/development/build-opengl-guest-compat.sh
```

GL 回归必须显式加载目标 guest shim，且日志确认 `Apple Paravirtual device`，不能将 `Apple Software Renderer` 当 GPU 成功；GPU 测试串行，保留 PNG 读回和 shader/error 日志。尚未安装的测试库不要写进全局 launchctl 环境。

### deviceInfo CPU回归验证

```bash
clang -Wall -Wextra -Werror -fsanitize=address,undefined VirtualMac/scripts/tests/deviceinfo-reply-test.c -o /tmp/virtualmac-deviceinfo-reply-test
/tmp/virtualmac-deviceinfo-reply-test
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework Metal VirtualMac/scripts/tests/deviceinfo-profile-test.m -o /tmp/virtualmac-deviceinfo-profile-test
/tmp/virtualmac-deviceinfo-profile-test
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation VirtualMac/scripts/tests/deviceinfo-policy-test.m -o /tmp/virtualmac-deviceinfo-policy-test
/tmp/virtualmac-deviceinfo-policy-test
```

> 最高优先级：**用户当下指令 > 代码/配置 > 文档/记忆**。发现文档与现实不符 → 以证据为准并更新文档。
