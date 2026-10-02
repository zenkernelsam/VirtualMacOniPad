# WORKLOG — 逐条进度日志（压缩后先读本文件 + AGENTS.md）

## 2026-10-01（会话 1：接手 + 盘点 + GPU 研究启动）

### 完成
- [x] 读三份交接文档（SUPER-HANDOVER / VM-crash-fix-and-build-notes / VMGPU-REFERENCE）
- [x] 复述十条准则、区分战线已知/未知（见会话首轮回复）
- [x] **SSH 通道打通**：`ssh -p 2222 root@192.168.64.1`（NAT 网关=宿主 iPad；22/2222 双通；密码问用户，勿入库）
- [x] 定位 iPad 侧关键路径：payload `/var/root/VirtualMac/payload/`；VM 数据 `/var/mobile/Media/VirtualMac/`；App 在 `/var/jb/Applications/VirtualMac.app`（→ preboot procursus）
- [x] 拉取诊断证据到 `.diag/20260920-121651/`（最新诊断包的小文件：manifest/Settings/logs/plist/2 份 VirtualMac.ips）
- [x] 黄金基线普查：`Virtualization.framework`（13.2.1 提取）**含 USB 类**（见审计文档 §4）
- [x] 客机 GPU 实况取证：`AppleParavirtGPU` IOAccelerator、`AppleParavirtDisplay` 2732×2048、`OpenGLPVGCompat.dylib` 已注入
- [x] 写 `AGENTS.md`（仓库根，压缩恢复用）
- [ ] `docs/PERIPHERAL-PASSTHROUGH-AUDIT.md`（编写中，等 vz/host 盘点 subagent 报告合并）
- [ ] `docs/GPU-NATIVE-RESEARCH.md`（骨架+首批证据）
- [ ] iPad 诊断包清理：3×~1.1GB zip，价值文件已抽取 → 待用户确认后删（**先备份证据再删，已获原则同意**）
- [ ] commit + push（随文档完成执行）

### 关键新事实（详见审计文档）
1. payload = **macOS 13.2.1 (22D68) Ventura 提取**，服务 15.6.1 客机 → 版本错配是 GPU 问题温床
2. `OpenGLPVGCompat.m` 头注释逐字：*"the Ventura-era serializer rejects GLD's defaultRasterSampleCount hint and custom FSAA sample locations"*
3. App 端 `makeConfiguration` 两次字典下标 SIGSEGV（9/20，vmfix1 在装）——非 PG 另一只虫子
4. 运行期无 USB 外设；输入设备实际走 `_VZMacKeyboardConfiguration`/`VZMacTrackpadConfiguration`（App 日志逐字）；vzboot.m 备用路径用 `VZUSBKeyboardConfiguration`+`VZUSCScreenCoordinatePointing`（注释称 VZMac* 属 14+，与日志矛盾，待澄清）
5. GuestTools 走 virtio socket :505050，协议=QGA 风格 JSON；guest 启动参数 `-arm64e_preview_abi`

### 追加（GPU 首日取证）
- [x] 客机 GPU 实况：`AppleParavirtDevice` family 探测、BC7 可建、OpenGL shim 前后对比（0→2 加速渲染器）、`/Library/VirtualMac/OpenGLPVGCompat.dylib` 全局注入确认
- [x] **每日 GPU 复位风暴实锤**：20 份 Kernel gpuRestart（9/26 起），`submitEvent:INCOMPLETE` 签名；触发者跨 app（witchontheholyni/GitHub Desktop/WebKit/WindowServer）
- [x] APVFeatures 双层协商面摸清：宿主 Ventura 14 位 vs 客机 38 键 + `binaryVersion` 握手 + `PGSerializerFeatures.supportsOpenGL`（shim 要开的那一位）
- [x] OpenGL shim 机制全解（IOGLBundleName interpose + supportsFamily 谎报 Apple1-7 + 两处 sample-count 归一化 + Rosetta 内联顶点小缓冲）
- [x] vmmhook.m 地图：hv_* 全套 interpose、USB HCI swizzle 组（restore 桥服务端在此）、xpc/IOService/IOSurfaceCreate 改写、VMM 内存 2×physical 放宽
- [x] USB 桥服务端定位：`vmmhook.m:2171-2187` 在 VMM 进程内 bind `/tmp/vz-usb-restore.sock`（chmod 0666）；`installation_usb_shim.m` 是 MobileDevice 侧 shim；`vz/development/probes/usb_bridge_probe.c` 是现成联调探针
- [x] 审计疑点澄清×1：`_VZMacKeyboardConfiguration`/`VZMacTrackpadConfiguration` **确实存在于** Ventura payload（nm 逐字符号）→ vzboot.m 注释"14+ 才有"已过时，非路径矛盾
- [x] 客机活体 `HostConfiguration.plist`：`OpenGLAcceleration=1`、`OpenGLAllowed=1`、`Build=55-02a51a0c7c5808e5`（宿主策略下发正常）

### 阻塞/待用户
- 🔴 **iPad SSH 断**：22:53 起 `kex_exchange_identification: Connection reset by peer`（22/2222 都重置，TCP 可连）。宿主侧拿不到 `/tmp/vmm.stderr.log`/`/tmp/pvg-trace.log`（GPU 复位根因的决定性证据）。用户手动 sshd 重启失败（launchctl EPERM），**决定重启 iPad** → 客机随宿主断电，本会话终止。
- IDA Instance4 @13340 已写入 `~/.config/devin/mcp_config.json`（CLI 需重启生效）；待用户在 IDA 里加载 `VMGPU/Frameworks/ParavirtualizedGraphics.framework`。
- ~~vz/host 盘点 subagent（9e85a372）长跑未归~~ **已完成并整编入 `docs/SOURCE-AUDIT-REPORT.md`**（~5h，扫遍 vz/ host+guest+shims+tweak+install+patches+packaging）。主会话抽验行号一致。新增信息量：fake USB HCI 完整状态机/协议 v2、`VZLocalPolicy.m` 内嵌 Ventura 开发私钥（风险项）、GuestPolicy 钉 guest CSR=0x6f（EXPERIMENT 门控）、`EXPERIMENT_VENTURA_OPENGL` 注释自述 OpenGL 路径半成品未生产启用、compat stubs 清单（DiskArbitration 等 ENOTSUP 占位）、VMM ents 含 `vm.device-access`/AGX user-client/扩展 VA、launchd/Mach/socket 拓扑全表。

### iPad 重启后的续会话行动清单（按序）
1. 用户在 iPad 上重跑 Dopamine 越狱（semi-untethered，必须重打）→ respring 后 SSH 才会回来。
2. 验证 SSH：`ssh -p 2222 root@192.168.64.1 'echo ok'`（22 也试）。
3. **立刻拉** `/tmp/vmm.stderr.log`、`/tmp/pvg-trace.log`、`/var/mobile/Media/VirtualMac/Sequoia.bundle/VirtualMac.log` → 与客机 gpuRestart 时间戳对齐，定位 `submitEvent:INCOMPLETE` 的宿主侧原因（反序列化失败楔死/未知 opcode/宿主 Metal 挂起/内存双计 四选一）。
4. 若日志信息量不足 → 下一步是"诊断级"增强 pvg_trace（把命令 opcode 序列打到文件，重启后对账），标 diagnostic。
5. 顺便按 §"清理"条款处理 iPad 上 3×~1.1GB 旧诊断 zip（先 NAS 备份 manifest，再废纸篓/隔离）。
6. IDA Instance4 就绪后：PG fifo 命令分发反编译（优先 CMD=0x37 对应处理函数）+ `_attachUSBDevice:error:` 的 entitlement 检查路径。

### 深夜追加（不重启，等 subagent）
- [x] **卡死定位收窄**：仅 Exec 通道积压（10-01 22:52 报告四通道排水图：Exec 70cmds/~22KB 未消费 vs Object/Memory 排空）
- [x] 宿主 Cmd* 调度词表 32 条抽全（PGFIFO 方法名即命令处理器；opid→名映射待 IDA 查 dispatch 表）
- [x] 客机侧词表更大：插件含 `PGSerializer*CommandEncoder` 全套（ICB/光追/动态控制流）+ `supportsCmdExecIndirect3`（宿主只有 2）+ `SupportFlags2024` 位域 + `DeserializerVersion` 协商字段
- [x] **根因假设收紧**：客机发宿主不认识的 exec 命令 → Ventura 反序列化 `Invalid FIFO command ... opid=%u` → 通道楔死。验证=SSH 后 grep vmm.stderr.log 的 opid
- [x] 今日复位×8（20:10,21:26,22:17,22:52,23:40+），全部 witchontheholyni 触发（客机 `/private/tmp` 下的游戏，用户自己在测）
- [x] 客机 ioreg 实况：recoveryCount=0（复位后恢复）；`In use system memory=582MB`；WindowServer 是最后提交者；协商态不导出到 ioreg
- [x] 宿主 stderr 文件名确认：`vmm.stderr.log`/`vzxpchook.log`/`pvg-trace.log`（VZDiagnostics.m:609 收集清单逐字）；pvg_trace 会 dump `PGNewDeviceWithDescriptor` 的 descriptor（含协商后 APVFeatures/binaryVersion！）
- [x] 发现宿主侧 `native_bc_texture_support.m`：VMM 进程内给 iPadOS 16.3 的 AGX 注入 16.4 才有的 14 条 BC 格式表项（BC1-7）。客机 BC7 成功靠它
- [ ] 客机 dyld cache 提取失败（框架只有 stub，真身在 cache 但路径不可见）→ 若需要，改从宿主机 IPSW/挂载取

## 2026-10-02（会话 2：iPad 重启后——SSH 恢复，证据链推进）

### 完成
- [x] SSH 恢复验证：22/2222 双通 `cisco`（首次连接曾 `UNIX authentication refused`——respring 未就绪所致，稍后自愈）
- [x] 宿主环境实况：VMM pid 948 跑着本客机（~130%CPU）；VMM env：`PVG_TRACE=1`、`PVG_TASK_RESERVATION_MB=256`/`PVG_TASK_OVERFLOW_MB=2048`/`PVG_LARGE_TASK_RESERVATION_MB=2048`/`PVG_MIN_TASK_RESERVATION_MB=64`/`PVG_METALLIB_FALLBACK=1`、`VMMHOOK_TRACE_VCPU_LIMIT=8`
- [x] **metalshim BC 注入实测成功**（vmm.stderr.log 逐字）：`[metalshim] enabled native BC texture formats in /System/Library/Extensions/AGXMetal13_3.bundle/AGXMetal13_3 after runtime ABI validation`
- [x] **`/tmp/pvg-trace.log` 缺失之谜解开**：`Trace()` 无条件门控 `gDebugLogging`（`VZ_DEBUG_LOGGING`）；VMM env 里没设 → hook 装了但一个字不写。开关=App 设置 `DebugLogging` 键（off/next/always，`VZConsumeDebugLoggingForBoot` 每次开机消费 "next"）
- [x] `systemhook.dylib` 身份澄清：Dopamine 自家注入 shim（`/usr/lib/systemhook.dylib`→basebin 符号链），不是项目组件
- [x] iPad 统一日志死路：`log show --last 2m` 返回 **0 行**（rootless 下 logd store 不可达）→ 宿主侧只有 stderr/trace 文件两条路
- [x] **Exec 压力测试（1,017,882 cmd buffer/90s，0 错误）**：纯 blit+sync 提交完全健康 → 楔死是命令**内容**特异的，非吞吐问题。新探针 `vz/development/probes/metal-exec-stress.m`（已入仓）
- [x] 复活尝试：GitHub Desktop GPU helper（零拷贝光栅开了）+ Godot 都跑着，暂未触发复位——被动捕获已就位（`vmmwatch` 后台 tail vmm.stderr.log）
- ⚠️ **教训记录**：`/tmp` 随重启清空 → 复位前的 vmm.stderr.log/pvg-trace 已永久丢失；以后**重启前先拉 /tmp 日志**

### 下一步（决策点）
1. **拿决定性证据需一次 VM 重启**：App 设 DebugLogging=next → 重启 VM（客机断电）→ 复现 → 拉 pvg-trace.log（含 `PGNewDeviceWithDescriptor` 协商 descriptor dump！）+ vmm.stderr.log
2. 或用户把 witchontheholynight 放回客机跑一会儿，等自然复位看 vmm.stderr.log 是否打印 opid
3. IDA Instance4(:13340) 仍未加载——等用户开：目标是 PGFIFO dispatch 表 → CMD=0x37/0x1e/0x8 映射

## 2026-10-02 — IDA 逆向突破：PGFIFO 分发器全解码 + 楔死闭环定位（Instance4）

- [x] **`-[PGFIFO processFifo]` @ `0x100021594` 全反编译**：PGFifoThread 消费循环 → 12B 头 `{cmdLen,barrierCount,opid,stamp}` → `barrierWait` → `pushStamp` → `switch(opid)` 分发
- [x] **Ventura opid→Cmd 全表解出**（32 项 + deprecated 洞 3/0x1F/0x21/0x23/0x24/0x26/0x27/0x29-0x2F/0x32 → CmdDeprecated；>0x40 → Invalid→fault）：**`0x37=CmdExecIndirect2`、`0x1E=CmdNOP`、`0x39=CmdMapMemory2`、`0x30=CmdDefineChildFIFO`、`0x33=CmdSetObjectList`、`0x8=CmdDisplaySwapMapping`** —— gpuRestart 里卡住的命令全是合法 opcode → 旧假设"未知 opcode 触发 Invalid"**被推翻**
- [x] **`CmdExecIndirect2` @ `0x10001f4b4` 流程解码**：payload={taskID,resCount,cmdBufCount}+24B×res+16B×{off,len}×cmds → `[task runBlock:]`（shared_mutex lock_shared，无 @catch）→ `prepareResources`→`execQueue`→`commandBuffer`→（可选`encodeWaitForEvent`）→ 逐 cmd `mappedAddressForOffset:length:` → **`[task deserializer] decodeSegments:lengths:count:into:`**（`<MTLDeserializer>`，来自 payload 内置 **Ventura MetalSerializer.framework**）→ `addCompletedHandler`+`encodeSignalEvent`+`commit` → `completeResources:…`
- [x] **楔死闭环**：`faultAtOffset:stampValue:` @ `0x10001bdd8` = 置 fault 位 + `setFaultOffset:` + `[device signalFault]` + **condvar 停车等 quiesce** —— 一条 faulted 命令即冻结整条通道（read 指针停、GPUstamp 停、后续全 INCOMPLETE）。最新报告逐字吻合：Display[0] 的 `CmdDisplaySwapMapping`(0x8) `barrier 0: stampIndex=0x1 stampValue=0x33c4b900` 被楔住的 Exec stamp 拖死
- [x] **Fault 触发面全集**：~29 处 `faultAtStampValue:`（每个 Cmd* 自校验 + dispatcher 的 bad-len/bad-opid/deprecated）+ `faultAtOffset:` 直调 3 处（含 `0x10001feac` = ExecIndirect2 的 addCompletedHandler → **宿主 Metal CB 带 error 完成也会 fault→park**）→ 协议层与内容层殊途同归
- [x] `objc_exception_throw` 路径存在但无 @catch → 真触发=VMM abort（与观测不符），降权
- 全细节（地址/表/流程/判别手段）见 `docs/GPU-NATIVE-RESEARCH.md` §G

### 下一步（决策点·已更新）
1. 楔死现场快照（不用重启）：下次复位时 `sshpass ... 'sample <vmm-pid> 3'` → PGFifoThread 停在 `faultAtOffset` condvar = fault 停车实锤
2. diagnostic hook：pvg_trace 包 `faultAtOffset:stampValue:` 记 offset/stamp/返回地址/payload 头 → 定位是哪条 Cmd 的哪段负载
3. 长期方向分叉：协议层补命令 vs payload 代际升级（15.x MetalSerializer/PG）

## 2026-10-02（续）— 客机侧 opcode 词表 + 协商机制取证（不依赖重启）

- [x] **guest kext 提取**：boot kernelcache(Preboot) → `ipsw kernel dec`+`extract` → `com.apple.driver.AppleParavirtGPUIOGPUFamily`（15.0.0, arm64, 396KB, 符号全）→ `.diag/guest-kext-15.6.1/` 存档（含全量反汇编 text.asm）
- [x] **guest opid 词表**：`commandDescriptor` 全部 ~30 调用点回溯 → guest 实际会发 **0x41/0x42/0x43/0x44** 四个 Ventura 不存在的 opcode（详见 GPU-NATIVE-RESEARCH §H 全表）：0x41=deleteHostSharedTextureBacking、0x42=resetRasterizationRateMap、0x43≈CmdExecIndirect3、0x44=setResourceHeap 新变体
- [x] **协商诚实性坐实**：`setResourceHeap` 按 task+0x595 feature byte 二选一（0x44↔0x33 显式降级）；插件含 `supportsCmdExecIndirect3` 协商位；序列化器 `initWithDevice:…:deserializerVersion:` 按宿主自报版本出料；宿主 setBinaryVersion @`0x100011efc` clamp≤43、按版本层叠 feature bitmask（device+1220）
- [x] IDA 补漏：`CmdDeprecated`→fault+signal；`0x10001feac` completedHandler `status==5`(MTLCommandBufferStatusError)→`faultAtOffset` 停车——**宿主 Metal 执行错误同样楔死通道**；`barrierWait`→`[device waitStamps:…]` 内部等待
- [x] **嫌疑收敛**（协商诚实⇒新 opcode 正常不发出）：①宿主 iPadOS16.3 AGXMetal 跑不动合法反序列化内容（metalshim 补 BC 纹理=同类先例）②未门控路径/资源生命周期竞态 ③合法 opid payload 布局漂移 ④某路径忘查 feature 位
- [x] 宿主 stderr 快照存 `.diag/host-logs/`（本次 VM 启动后仅 10 行、无 GPU 相关——os_log 不落 stderr 与预期一致）；自重启以来无新 gpuRestart

### 待办
1. 用户方便时重启 VM → App 开 DebugLogging=next → 复现 → pvg-trace 会有协商 descriptor dump
2. 楔死现场 SSH `sample <VMM pid>`（不需要重启，随时可做）
3. diagnostic hook：`faultAtOffset:stampValue:` 包装记返回地址（pvg_trace 增量，标 diagnostic）
4. 若坐实宿主 Metal 失败 → 枚举 iPadOS16.3 AGX 缺口沿 metalshim 模式逐项补 / 或 payload 代际升级

## 2026-10-02（午）— iPad 重启恢复后：楔死现场自动捕获就位 + guest fault 通路解码

- [x] 重启恢复：SSH 通、VMM pid=571、vmm.stderr.log 干净（10 行）、`pvg-trace.log` 未生成（`DebugLogging=off` 未变——这次重启没开 debug）
- [x] **guest fault 通路**：`AppleParavirtGPU::handleFaultInterrupt` @ `0xfffffe0008cdbda0` —— kernel/os_log 打 `"handleFaultInterrupt: Received fault interrupt"`（**客机 log show/dmesg 可见**），然后逐通道读 `[channel+0x18]` fault code 上报。→ 楔死检测信号比 gpuRestart 报告更早
- [x] iPad 栈采集手段探明：无 `sample`/`lldb`；`stackshot -p <pid>` 可用（输出 kcdata 二进制，18KB/进程，已实测健康 VMM）；`task_for_pid` 在 vzxpchook 里已被证实可用 → 未来可写最小 PC-dump 工具
- [x] **被动捕获已部署**：`vz/development/probes/gpu-wedge-watch.sh` 后台跑（pid 9024，3s 轮询）——新 gpuRestart 一出现即自动抓：报告本体 + tailspin + guest fault log（log show 5m 窗）+ 宿主 `stackshot -p` + vmm.stderr tail → `.diag/wedge-watch/`

### 待办（不变，优先级更新）
1. **等自然楔死**（watching）——或用户跑 witchontheholynight/Matlab 主动复现
2. 用户下次重启 VM 前开 DebugLogging=next → 拿协商 descriptor dump（pvg-trace.log）
3. diagnostic hook（`faultAtOffset:stampValue:` 包装）等坐实现场后再决定要不要写
4. 需要时写 kcdata/stackshot 解码器（python，解 PGFifoThread 的 PC 落点）

### 2026-10-02（续）：Reims vGPU 发现与对照
- 用户指出社区讨论的 "reims vgpu"——已定位 = `steelbrain/reims-vgpu`（LGPL-3.0），clone 至 `/tmp/reims-vgpu`（客机重启后需重拉）。
- 它是 AppleParavirtGPU 协议宿主侧的独立 Rust 重实现（QEMU 设备 + 线格式解码 + Metal/Vulkan 后端；Metal 直连后端代码已存在 ~10.8k 行）。
- opcode 表与 IDA 逆向结果**逐条一致**（≤0x40、0x37=EXEC_INDIRECT2、洞位/非法路径全对上）→ 我们逆向可信。
- 协议新知：0x2d=Monterey DeviceInfo、0x3a=Tahoe DeviceInfo、DefineTask2 首字=(id<<1)|kernel、EXEC_INDIRECT2 三字段头。
- 价值定位：规格书/oracle——`reims-vgpu-wire` 20 个线格式解码模块 = `decodeSegments` 所解字节流的可读版本；core 有串行参考解释器可做楔死字节流对照。
- 换血评估：换 PG.framework→reims 模型为大工程（私有 SPI + LGPL + 同 AGXMetal 后端）；首要用途=对照解码器。详见 GPU-NATIVE-RESEARCH §J。

### 2026-10-02（续2）：能力缺口根因定位——deviceInfo 字段代差
- 客机探针 `probes/mtl-caps-dump`（新增）：客机 PV device 实报 `argumentBuffersSupport=0`、`readWriteTextureSupport=1`、dynlibs/functionPtrs/pullModel/barycentric 全关、无 Metal3 family、counterSets=null。
- 宿主 `writeDeviceInfo`@0x100002a04 反编译：field id 词表止于 16；DeserializerVersion 硬编码 0。客机词表 ~40 字段，ArgumentBuffersTier=38/SupportFlags2024=33/HostGPUFamily=37 等全部 >16 → 客机全读 0。**这就是 Chromium/Matlab 类要 disableGPU 的协议级根因**。
- MATLAB Patch 情报（~/Desktop/Patch/MATLAB）：CEF --disable-gpu、Java2D 全关、figure OpenGL 曲线不显示+MSAA 毁管线（OpenGLPVGCompat 覆盖不足）。定位全部对得上。
- 修复方向成型：宿主 hook writeDeviceInfo 追加字段（vzxpchook/pvg_trace 架构内），前置=iPadOS16.3 AGX 真实能力表，按实上报。
- reims-vgpu clone 移至 .diag/reims-vgpu 持久化。

## 2026-10-02 — deviceInfo 满血补丁落地+deb 构建

- **Reims 协议层当 oracle 拿到 deviceInfo key 全表**（`regs.rs`）：key 1-44 全解码（43=Apple 自家跳号死位）；macOS15 客机 keyLimit=42、macOS26=45；真实宿主服务表确认——argbuf 来自 key33 SupportFlags2024 bit5（非 key38）；key10=SerializerVersion 各 rung 语义明确（≥6=OpenGL 词表）。
- **宿主侧回复管线全解**（IDA Instance4）：`getDeviceInfo:length:dst:` IMP=`sub_100011DF0`（无 xref=仅方法表调）；内部 MTLRangeAllocator map `pfn<<14`+0x4000 → `writeDeviceInfo(dev,keyLimit,count,dst=va+*(dev+0x1F0))` → unmap。writeDeviceInfo 字段门控 `keyLimit>K` 与 Reims 逐位吻合。
- **实现**（`pvg_trace.m`+`vmmhook.m`+`VirtualMacApp.m`）：swizzle getDeviceInfo→orig→hv_vm_map 表换算客机页 VA→追加 key17-41 扩展集（Apple 真实宿主值）→重写哨兵。env 可配：`PVG_DEVICEINFO_CAPS`（总开关）/`PVG_DEVICEINFO_EXTRA`（逐 key 覆写，含 key10）。
- **deb 已构建验证**：安装用 `VirtualMac_1.2.3_c137b1306a.deb`（=commit c137b13，provenance 对齐；同目录 `a983c775b6` 包是同内容预提交版，勿装）。
- 待 VM 重启验证：vmm.stderr 应有 `deviceinfo caps augmented`；客机 mtl-caps-dump 应对照翻表；watcher 盯楔死。**2026-10-02 下午审计更新：先暂停将这个包当作已验证满血版本，见下节。**

## 2026-10-02 下午 — Godot 粒子场景崩溃复现与等价 GL shader 修复

- **必须纠正早先能力结论**：SDK 明确定义 `MTLArgumentBuffersTier1=0`、`Tier2=1`。guest 0 是 tier1，iPad 原探针 1 是 tier2；此前“完全没有 argument buffers”“它就是 Chromium 禁 GPU 的根因”均未成立，撤回。探针已添加枚举名，macOS 运行确认 `0 (tier1)`，iOS arm64e 语法检查通过。
- **deviceInfo 风险审计**：key37=1009/Apple9 不在本机实测支持集合（最高 Apple7）；key33=4095 全开 12 位含协议/资源功能，公开 Metal 属性不能全部证明。尚未收窄默认源码表，未部署；不声称它已经导致新 opcode fault。先完成逐位协议/执行验证，再重建和首启验收，旧 c137b13 包不是已验证满血交付。
- 找到原报告 `Godot-2026-10-02-143146.ips`、`143201.ips`，含 OpenGLPVGCompat、AppleMetalOpenGLRenderer，失败于 `glpLLVMCGSwitchStatement +176`/glLinkProgram。不得拿未注入 shim 的 CLI 软件 GL 当对应加速测试。
- 根据 Godot 最近项目记录，隔离 clone `Desktop/book-buster` 到 ignored `.diag/godot-vulkan/book-buster-test`；原项目两个 dirty 文件保留，仅向副本同步 splash 场景 UID。副本改 renderer、重新导入资源，不修改原项目或原 save 目录；用户尚未确认全部报错场景。
- **实景复现**：pre-titleScreen（20 节点、1 GPUParticles2D，amount1000）+ 原安装 GL shim → 同栈 crash/exit134；诊断关闭粒子 → 60 帧 GPU 截图/exit0。
- **定位 shader**：glLinkProgram 只读取证 hook 捕到 link13 的粒子 copy/transform vertex shader（6420B），`switch(align_mode)` 四个独立 case、首 case 空；不是已经证明的 fallthrough。GLSL/图像/日志全部留 ignored `.diag`，不提交第三方 shader。
- **修复**：客机 `OpenGLPVGCompat.m` 限定源结构、常量和独立 case block/终止 break 后等价转 if/else；不关闭 GPU/粒子，不改数学/资源/校验。未识别输入原样走原 API；开关 `VIRTUAL_MAC_OPENGL_PARTICLE_SWITCH_LOWER=0`。原有其他 shim 行为不变。
- **回归**：`scripts/tests/opengl-particle-shader-test.m` 通过 `-Wall -Wextra -Werror`；x86_64/arm64/arm64e 三架构构建与签名通过。最终结构闸门版本 **3 次独立实景运行，各 60 帧、1152×648 GPU PNG、exit0**；最终新 shim 关闭转译开关恢复原 crash/exit134，负对照成立；普通 indexed VBO+uniform 三角形读回 `(255,0,255,255)`、FBO complete、GL error0，未命中转译。
- Vulkan 另有独立缺陷：MoltenVK1.2.0 由 Mac2 推断 attachmentless 支持，但 guest Metal 拒绝 all-invalid pipeline。诊断只收窄 Mac2 后 MoltenVK 原生 dummy attachment 路径有效（保留 rasterization，writeMask0）；最小 RGB/3D/GPU 粒子读回通过，标题场景也捕获成功。该诊断不写入正式默认。
- **交付边界**：新 guest dylib 位于 `.diag/godot-vulkan/guest-opengl-fixed/OpenGLPVGCompat.dylib`，只在新测试 Godot 中加载，未替换 `/Library/VirtualMac`、未重启/注入宿主 VMM、未重建 deb。UID/空 shader-global/退出资源警告仍在，未测试全游戏、全部 3D 粒子朝向、MATLAB、Chromium；不能称全 GPU 完美修复。
- 下一闸门：用户确认目标场景并扩大实景测试；审计并收窄 deviceInfo 默认表，再整合新 guest shim 到可回滚 deb，受控首启验收。

## 2026-10-02 — 保守 Godot 修复包：源码安全闸门

- 用户授权先整合可验收修复包，不安装、不重启 VM 或宿主。
- `PVGDeviceInfoPolicy.h` 统一 App/VMM 的开关契约；扩展默认 off。App 只读新的 `PVGDeviceInfoCapsExperimental`，旧 `PVGDeviceInfoCaps=YES` 不触发；只接受 NSNumber true。VMM 只读新的 `PVG_DEVICEINFO_CAPS_EXPERIMENTAL`，仅精确字符串 `1` 可启用，unset/空/0/true/YES/2 等均关闭；旧 env 忽略。关闭时清理传入 VMM 的 legacy flag 与 extra，不修改用户原有 preferences。
- 实验参考表仍在源码，但不会在默认启动时追加 Apple9/4095 等字段；表自身的协议/执行支持没有因默认关闭而得到证明，不应自行启用。
- 新 `scripts/tests/deviceinfo-policy-test.m` 通过；Godot 源结构回归再次通过，均使用 `-Wall -Wextra -Werror`。App arm64 与 pvg_trace arm64e iOS14.5-target 语法检查通过，仅既存 UIKit `setScreen:` deprecation warning。
- 独立构建目录 `.diag/godot-conservative-build`：复用框架/辅助组件复制到新目录，源码变动的 VMM 与 App/GuestTools 重新构建，旧输出及 deb 保留。完整构建 exit0；93 个 Mach-O 平台/最低版本检查、package stage audit 通过。缺少 iPadOS14.5 DSC 导致完整 ABI 检查跳过，不能宣称完整跨版本 ABI 验证。
- 安装风险核实：现有 `preinst`/`prerm` 会 killall VMM，`postinst` 会更新 helper job，并向安装器提示 Restart SpringBoard；脚本本身不主动重启。因此必须先正常关闭客机并另行安排安装，不能从正在运行的本 VM 直接执行 dpkg 安装。VM 数据目录不作打包输入；本轮没有调用部署/安装脚本。

### 保守包交付与验收（源 commit 598e6cda2494e341f65cd08a0353b1f7bce65be5）

- 文件：`VirtualMac/build/release/VirtualMac_1.2.3_598e6cda24.deb`；version `2:1.2.3+84.598e6cda24`、App build84、20,860,496 bytes。
- SHA256：`59a5130ab76bab424dda26d74907d9358ed4a2d52603ac5850d965f967d38307`。构建源 commit 固定为 598e6cd；后续文档提交不改变这个包的来源或需要替换它。
- 解包核对：App 中包含新开关与 default-off 状态信息；iPadOS16 与 iPadOS14 VMM hook 使用新 env，包内与编译输出 SHA 相同；App/两个 VMM hook 的 CDHash 与包内 trustcache 匹配；无 VM 数据、无 Apple bootpd/InternetSharing 系统路径替换。
- GuestTools archive 里的 GL 库与编译输出 SHA 相同，arm64/arm64e/x86_64、严格签名通过；库 SHA256 `056c9d015d49777700e6a4b015d60529f88ac93cb3e03a7db98ca2baf6c0882d`。
- **用包内解出的库实测**：GPU 加速 OpenGL、20 节点、1000 粒子的 pre-title 场景，3 次独立 60 帧/1152×648 读回，exit0；非黑采样数 8702、8699、8698。仍有原项目 UID/空 shader-global/退出资源警告，不称全游戏验收。证据 `.diag/godot-conservative-build/scene-run-{1,2,3}.{log,png}`、`.diag/verify-godot-conservative-deb.log`。
- **本轮没有安装、更新现用库或重启**。尚未验证 iPad 上新 App/VMM 首启、GuestTools 自动更新、原工作项目完整运行、MATLAB/Chromium；这几个项目必须安装后验收。

安装前：
1. 先在 iPad 上记录当前 `dpkg-query -W com.mac.virtual` 的版本，保留对应可启动旧 deb；旧 c137 默认扩展未验证，不能盲选作安全回退。
2. 保存所有客机工作，备份重要数据、宿主 VM 配置和 App preferences、客机 `/Library/VirtualMac` 与 GuestTools LaunchAgent。不要盲目复制 512GB 虚拟磁盘；先确认备份空间与成本。本轮不执行这些用户数据操作。
3. 把新包转存到 VM 之外（iPad 本地、NAS 或另一台机器），检查 SHA256。然后从 macOS 正常关机；确认 App 显示 VM 已停止，再由 iPad 端安装。当前客机 CLI 会话会中断，回来从本日志恢复。

安装后：
1. 包版本必须为 `2:1.2.3+84.598e6cda24`；App/VM 启动时 `/tmp/VirtualMac.log` 应有 `[PVGDeviceInfo] experimental=0 (default off)`，不要打开实验扩展。
2. 启动客机并等待 GuestTools 更新，`/Library/VirtualMac/.build` 应为 `84-513cc8ea9272d5f3`（App build + payload SHA256 前8字节）；验证 GL 库 SHA256 与上列一致、`codesign --verify --strict /Library/VirtualMac/OpenGLPVGCompat.dylib` 通过。新启动 Godot 才加载新库，已有进程必须退出重开。
3. 确认 OpenGL 加速日志为 `Apple Paravirtual device` 而非 Software Renderer；重复加载报错场景，核对粒子、画面、shader 错误与新 `.ips`；再扩展其他应用测试。本包未修复 Vulkan attachmentless 问题。

回滚：
- 单个 Godot 转译问题可在新启动的诊断进程设置 `VIRTUAL_MAC_OPENGL_PARTICLE_SWITCH_LOWER=0`，恢复此前 shader 行为（原已知粒子 crash 也会恢复）；不写全局 launchctl 环境。
- App/VM 首启异常时停止尝试；保存日志后，确认 VM 已停止，再重装事先保留的可启动旧包。若旧包含实验能力扩展，必须先安排该版本的扩展关闭，不能把原本的过度能力上报重新带回。
- VM bundle/磁盘不作回滚覆盖，不用恢复旧盘抹掉新数据；客机 GuestTools 的回退由旧 App 启动时重新安装旧 payload 或经备份手动恢复，恢复前另行确认。

## 2026-10-02 晚间 — 已安装84；实验增强包的源码审计与修正

- 用户安装1.2.3(84)，反馈 Godot 看起来正常。客机核对 `/Library/VirtualMac/.build=84-513cc8ea9272d5f3`、已安装 GL SHA256 `056c9d015d49777700e6a4b015d60529f88ac93cb3e03a7db98ca2baf6c0882d`，严格签名验证通过；未测 FPS，不声称性能零损耗。
- 两份旧包已复制飞牛 `VirtualMacOniPad_iOS` 并比对 SHA256；NAS 上传完成状态未核验。用户明确接受宿主 panic/整机重启的实验风险，并要求先审核 Git 中 GPU 补丁、提高成功率后重建。本轮只源码/构建/交付，不安装或重启，不碰 book-buster 原仓库，不向运行中 VMM 注入。
- 审核 5906e1b、046abc6、c137b13、598e6cd、b87c465 的相关改动；保留既有 mappedAddressForOffset 校验、分段映射、BC/OpenGL 和 Godot 修复，不重新引入原始错误地址回退。
- 发现 c137 回复地址错误：`_PGDevice+0x1F0` 为 `_rootTaskBase`，ObjC类型 `^v`。原函数的 `rootTaskBase+temporaryOffset` 是新映射的临时别名；hv_vm_map helper 返回的是客机物理页本身，必须从 offset0写。静态解析及反汇编证据在 `.diag/check-pg-deviceinfo-abi.py`；方法编码 `v28@0:8I16I20I24`、IMP `0x100011df0`。旧扩展可能一直提前退出，不能把旧包视为已验证生效。
- 另复现页尾算术下溢：replyOffset=0x3ffc、count=1 时旧代码 `capacity=0 usable=4294967295`。抽出有界 reply owner，拒绝短尾/越界/必要哨兵缺失，不覆盖原有完整回答；从页首扩展。
- 新 `host-clamped-v1` 默认开，显式新 preference false 可回退；VMM env仍精确1、iPadOS<16拒绝方法hook；不写用户 preference，84回滚缺省仍off。参考表在运行时按宿主查询裁剪，不发送 Apple9、提高AIR/serializer、共享资源/命令跳转等未证协议位。详见研究文档§N。
- 覆写改为只能收窄解析后的 profile，legacy extra无法重开 serializer=8、flags=4095或Apple9；无匹配getter的字段省略。启动常规stderr打印实际profile/key/value，错误不再只依赖debug trace。
- 新策略/profile/ABI回归、ASan+UBSan reply回归（全部16385个页偏移）、Godot shader回归通过；pvg_trace iOS arm64e严格语法检查通过，App仅已有UIKit弃用警告。尚未安装新配置，硬件/传输执行和性能未验证。

### 实验增强包交付（源341fb8f14618345e9008f94e23a6f39c0270e122）

- 独立构建 `.diag/gpu-enhanced-build`，限流5 jobs、taskpolicy background；App/VMM/Metal兼容库/GuestTools重建，框架和辅助组件复制复用，不覆盖旧产物。构建exit0；93个Mach-O平台/最低版本、stage audit通过；14.5完整ABI检查仍因缺少DSC跳过。源码提交341fb8f已推送。
- 交付名 `VirtualMac_1.2.3_341fb8f146_GPUExperimental.deb`，App build86，version `2:1.2.3+86.341fb8f146.gpuexp`，20,858,804 bytes。SHA256 `4b5adc68ccc156cb340be92115d7703676171bed8a2a2d7b4f2704829ba9b3c1`。编译目录原名无GPUExperimental后缀，仅复制交付时加实验标记，字节一致。
- 已复制 `VirtualMac/build/release/` 与 `~/Library/CloudStorage/飞牛同步-HomeNAS/VirtualMacOniPad_iOS/`；两处copy/hash核验通过。两处84回滚包的SHA仍为 `59a5130ab76bab424dda26d74907d9358ed4a2d52603ac5850d965f967d38307`。不覆盖c137；NAS远端同步完成状态未核验。
- 解包检查App default-on profile、新env、两个VMM hook及MetalCompat与编译输出hash一致；App/VMM/Metal库CDHash匹配trustcache，无VM磁盘/数据目录或禁止的Apple系统路径替换。GL arm64/arm64e/x86_64、严格签名通过；包内GL SHA256 `28b4f670311bfc5292e776f23f16e3e1fbb5db5b83d007874255f69d189e0150`，预期GuestTools `.build=86-7c3f1508d5328f78`。
- 包内提取GL库再次通过3次独立标题场景测试：每次60帧/1152×648、GPU粒子保留、exit0；nonblack samples 8704/8700/8702。证据 `.diag/gpu-enhanced-build/scene-run-{1,2,3}.{log,png}`、`verification-receipt.json`、`packaged-gl-results.json`。这些运行使用现有84宿主，不验证新profile执行，不构成FPS或全应用证明。
- 本轮未安装、修改现用GuestTools、启用宿主新profile或重启。新包是审计合并实验增强版，不是4095机械全开或已证明全Metal支持；MATLAB/Chromium/Vulkan问题未全部修复。

安装与回退的最小步骤：
1. 确认飞牛已同步，iPad外部能拿到新实验包和当前84回滚包；保存客机工作与重要数据。正常关闭macOS，确认VM停止，再安装86；不得从运行中的本客机安装。
2. 首启App应记 `[PVGDeviceInfo] experimental=1 profile=host-clamped-v1 (default on)`；若先前显式设置新preference为NO，仍会关。VMM还须出现 `deviceinfo profile=host-clamped-v1`、实际key/value和 `caps augmented ... dropped=0`，不能仅凭开机视为扩展成功；key37不超过1007、key33不能含0..4或10..11位、key10保持原值。
3. GuestTools更新后核对上述build/hash，再新启动Godot。顺手测试实际想改善的应用即可；不预设MATLAB/Chromium必定正常。
4. 若首次启动失败、图形异常或宿主panic，停止反复尝试；先从iPad导出VirtualMac诊断包、App/VMM crash或panic报告，保存 `/tmp/VirtualMac.log`、`/tmp/vmm.stderr.log`（若仍存在；宿主重启可能丢失）。确认VM停止后重装84。不要覆盖VM磁盘或还原旧盘抹掉新数据；旧App恢复GuestTools后应重新得到84的build/hash。

## 2026-10-02 21:03首启 — 用户已安装86，客机初步验收

- 用户报告已安装 `341fb8f146_GPUExperimental` / 1.2.3(86)。本次客机启动时间21:03:20；`.build=86-7c3f1508d5328f78`、安装GL SHA256 `28b4f670311bfc5292e776f23f16e3e1fbb5db5b83d007874255f69d189e0150`，codesign严格验证exit0；HostConfiguration build一致、OpenGLAllowed/Acceleration=true。安装件与交付包相符。
- 从源码重新编译客机Metal探针，执行时清空DYLD_INSERT_LIBRARIES，避免GL shim的family兼容声明混入原生能力查询。结果：readWriteTextureSupport=2、PullModelInterpolation=YES、families Apple1–5/Mac1–2/Common1–3；argumentBuffers=0(tier1)，dynamic libraries/function pointers/raytracing/barycentric仍no，Metal3未报。较研究K节旧快照有部分上报变化；不是完整功能执行或84/86受控性能对照。
- 实景脚本 `.diag/accept-build86-current.py` 只让新启动Godot显式加载已安装86 GL库，不替换系统库、不改全局环境。隔离book-buster标题场景：20节点/1个GPU粒子节点，PVG加速OpenGL、粒子switch转译日志出现；60帧1152×648、nonblack_samples=8692、PNG读回成功、exit0。图片已查看，完整标题和粒子可见。项目自身空资源/UID回退及退出资源未释放警告仍存在，不宣称全游戏无误。
- `.diag/build86-first-boot-acceptance/` 保存 guest-metal-caps.txt、godot-scene.log/png、ioreg-before/after.txt、receipt.json及argument-buffer-gates-arm64e.txt。IORegistry测试前后 recoveryCount=0、lastRecoveryTime=0；本次启动前的旧gpuRestart/Godot报告不能归因于86。启动日志有talagentd/nsattributedstringagent sandbox拒绝，不能直接等同GPU重启。
- 当前guest arm64e插件再反汇编确认：0x1b838先读一处+0x31并要求等于1，再读另一处+0x80的bit5，任一道不满足返回tier1；不能仅凭tier1就判key33未发或实验扩展全关，尚未确定是哪道门未满足。
- 阻塞：`ssh -p2222 -oBatchMode=yes root@192.168.64.1`返回身份认证失败，网络/SSH可达但无可用认证；已请用户恢复认证或导出VirtualMac日志。尚未取得本次App/VMM实际profile/key/value和caps augmented计数，也未核对宿主panic报告，因此完整能力协商仍待验收。不要为此重启iPad/系统服务或改认证配置；诊断zip可能很大，有日志条目时只取需要的条目。
- 暂无必须立即回滚的客机证据，可保留86做普通应用观察并保留84回滚包；不承诺性能提升或长期稳定，不开启更多字段，不把MATLAB/Chromium/Vulkan标为修复。此次没有commit/push，也没有修改原book-buster；它仍有原来的uid_cache.bin与logo场景两个未提交改动。

## 2026-10-02 21:15起 — 宿主验收补齐，完整合并87重新构建交付

- 用户说明SSH交互登录正常并提供认证，要求quota有限时优先完成完整包到飞牛。原失败是BatchMode无密码；22端口登录成功，不改认证配置、重启或运行中注入。密码只经进程环境传递，不保存入文件。SCP多来源第二次认证失败，第一份日志已完整到达；后续SSH流补齐另一份。采集脚本 `.diag/collect-build86-host.py`，只读取已知两份小日志。
- dpkg宿主版本 `2:1.2.3+86.341fb8f146.gpuexp`；VMM stderr证明 `profile=host-clamped-v1 pairs=12 serializer=unchanged`，字段23=1/25=1/28=5/29=1024/30=32768/31=32768/32=16/33=224/34=8/35=2048/37=1007/40=256；`caps augmented keyLimit=42 count=2048 existingApplied=12 dropped=0`。据此确认扩展生效，不再把Tier1解释为全关；其他协商门仍待研究。
- 本次App最新段配置校验成功、VM STARTED、原生PVG帧缓冲接入及GuestTools就绪；guest_did_panic等字符串是注册的RPC handler名，不是panic事件。当前及Retired/Panics报告列表未见本次新panic/VMM崩溃，Panics空。21:06 wakeups报告为225/s、Action taken:none，非崩溃；旧版20:16及更早也有同类，不能凭此判GPU失败或保证功耗正常。
- 用户请求的“完整版”按当前已合并、已审核配置重新构建，不强开未知能力或宣称Tier2/Metal3全打通。源码HEAD `867ea956075ec98879876b6055d58dd471b1cd22`（其功能代码与341fb8f一致，后一个提交仅交付记录），未修改功能源码。独立 `.diag/gpu-combined-build`，脚本 `.diag/build-gpu-combined.sh`，5 jobs/taskpolicy background；重建App/VMM/Metal/GuestTools，复用框架与既有辅助组件，保留旧输出。
- 构建exit0，93 Mach-O平台/最低版本及stage audit通过；14.5完整ABI仍因缺DSC跳过。包内App build87、版本 `2:1.2.3+87.867ea95607.gpucombined`，签名/trustcache/源码版本/重建库hash和无VM数据检查通过。新包App/VMM未安装；86首启的实际profile验收不冒充87已安装运行。
- 从87 deb提取GL库，在当前86宿主上串行3次标题场景均exit0、60帧1152×648、粒子保留、GPU读回；nonblack=8700/8698/8698。最终IORegistry recoveryCount=0/lastRecoveryTime=0。新GuestTools预期 `.build=87-477fc0fc695d8790`，GL SHA256 `08aaeb5014a27e2ce3d8a5063e6d4be67243e173b9f0408c9cbbf39e05da0529`。证据 `.diag/gpu-combined-build/verification-receipt.json` 与 packaged-gl-results.json。
- 已交付 `VirtualMac_1.2.3_867ea95607_GPUCombinedFull.deb` 至 `VirtualMac/build/release/` 和飞牛 `VirtualMacOniPad_iOS`；20,857,004 bytes，SHA256 `847bba626efb7d1daf95782c35f6ee79f16d6d6c039e56351bfb6f57838812fd`，两处核验通过；84回滚包两处仍为 `59a5130ab76bab424dda26d74907d9358ed4a2d52603ac5850d965f967d38307`。NAS远端同步仍由用户确认。87功能配置与86一致，当前86正常可继续使用，不需仅为重新打包立即安装；若安装，必须先正常关闭VM，保留84，不覆盖VM磁盘。
- 本轮未安装、改开关或重启，也未commit/push；首启及交付记录保存在本仓库文档和gitignored证据中，book-buster原仓库没有写入、提交或推送。

## 2026-10-02 21:35起 — 用户选择研究新增增强，随后要求优先交付88

- Tier2的第一道失败门已确认：原生APVFeatures.supportsArgumentBuffers=false，版本207档才开启，Ventura最高43；不强升协议或serializer，不改getter为YES。host-clamped-v1和原12字段保留。
- 新增Mac2完整性处理依据原生supportsRenderPassWithoutRenderTarget=false，而非按app/设备名白名单返回常数。只在APV类型及已识别ABI上收窄Mac2和legacy ordinal10005；保持其他答案、缺getter/未知ABI、GL Apple7 profile，保留三个Metal工厂+1所有权及observer流程。VIRTUAL_MAC_METAL_FAMILY_COMPAT=0可关闭。源码回归新测试为 `VirtualMac/scripts/tests/metal-family-compat-test.m`。
- CPU red/green及ASan/UBSan、已有Godot shader回归通过；MRC跨pool/NSZombie 50次default/copy/observer测试通过，argbuf仍tier1。新库x86_64/arm64/arm64e构建签名通过。
- 仅新Godot进程使用新库，baseline与关闭新修复均exit-6同一pixelFormats校验崩溃；开启时Vulkan最小RGB/3D/GPU粒子3次30帧通过（RGB差0、绿色中心、白粒子507/510/561），实际标题Vulkan3次60帧通过（8697/8705/8706），GL3次60帧通过（8699/8698/8703），两条最终PNG已查看。全部在隔离副本，未动原book-buster、全局环境或宿主，未重启。
- 证据 `.diag/build88-render-check/`、`.diag/inspect-guest-argument-gates.m`、`.diag/metal-family-live.m`；宿主86 profile的验收不等于88 App/VMM已安装验收。用户quota剩5%要求立即打包，停止扩展研究，目标build88完整包到飞牛，保留84/86/87。
- 功能源码、CPU回归和研究/首启记录已提交推送 `bb005a7dfea749e26aae42e43ed2d43e83441dff`（第88个提交），没有在book-buster提交或推送。独立构建exit0，93个最低平台版本及stage audit通过；14.5完整ABI仍缺DSC跳过。继存dynamic_lookup/UIKit deprecation及构建工具shadow-framework missing-symbol警告保留，不能视为全版本运行验收。
- 包版本 `2:1.2.3+88.bb005a7dfe.gpuvulkan`，App build88；App/VMM/Metal与编译输出hash、签名/trustcache、三架构GL、无VM数据检查通过；新getter/关闭开关/兼容代码存在于实际GuestTools库。预期GuestTools `88-46e1996c7b58fd11`、GL SHA256 `4bf929ed591f080ae2c459d5c7d2ee507556e4579dcc6db76e4b9aba33617ca2`。
- 已复制 `VirtualMac_1.2.3_bb005a7dfe_GPUCombinedFull88.deb` 至release与飞牛VirtualMacOniPad_iOS，两处20,857,348 bytes、SHA256 `33258ae583c9e14c8b7b8373fbc7c3d027235fb7bc75f20f9426730cadde9811`相同；84回滚包两处hash仍正确，86/87未覆盖。NAS远端同步未核验。用户已收到交付通知；仍未安装/重启，App/VMM整包首启与其他应用待验收。
- 最后实际deb提取库抽测通过：Vulkan RGB/3D/GPU粒子30帧（RGB差0、中心绿、白像素584）、GL实际标题60帧nonblack8700、Vulkan实际标题60帧nonblack8704，全部PNG读回/exit0。证据 `.diag/gpu-vulkan-build/packaged-render-check/`。原book-buster只读git status仍是已有uid_cache.bin与logo场景两个dirty文件，无写入/提交/推送。交付后这几条metadata记录保存在本地文档，功能源码及源测试已推送。

## 2026-10-02 22:53后 — 用户重启iPad、重新越狱并已安装88；超级handover

- 用户报告macPad工作期间VM满载卡死、强关无效，重启iPad、重新越狱、顺便安装88。未经日志/采样证实原因，不能从时间关联归咎macPad/88/GPU。此后不是旧86启动会话，旧host日志只保留为历史。
- 轻量核对：guest boot22:47:19、核对时uptime6min/load4.13/14.74/9.94；`.build=88-46e1996c7b58fd11`，安装GL SHA256 `4bf929ed591f080ae2c459d5c7d2ee507556e4579dcc6db76e4b9aba33617ca2`、严格signature通过。IORegistry recoveryCount=0/lastRecoveryTime=0。
- 显式加载安装库的只读MRC寿命查询50轮跨pool/default/copy/observer通过，Mac2=0/legacyMac2=0/targetless=0/argbuf0(tier1)。原生清空DYLD_INSERT_LIBRARIES查询Apple1–5/Mac1–2/Common1–3、RW texture2、PullInterpolationYES，动态库/函数指针/光追/barycentric仍NO。未提交GPU绘制/压力工作，未修改开关/全局env/host，未重启。
- 新host dpkg/App/VMM profile/字段/augmentation、安装后Godot实际GPU场景及长期稳定性尚未核验。首要任务交给新Agent；此前包后“未安装”结论仅属于构建/抽测时点。原book-buster只读status依旧两个原dirty文件，无写入/提交/推送。
- 用户额度将尽，明确请求超级handover与Codex CLI启动prompt。重写 `docs/AGENT-SUPER-HANDOVER.md` 为vendor-neutral自足手册，保留旧构建/黄金基线/安全知识，覆盖版本指纹、两条Godot因果链、Tier2协议207vs43、开启/关闭字段、源码和本地证据、构建/回归命令、新boot/卡死取证、P0/P1/P2任务与prompt。文件不含凭据；`.diag`不会随Git克隆自动带走。handover文档提交不会改变88的源码来源与已交付包。
## 2026-10-02 — MATLAB/Devin 目标扩展与 GuestTools readiness 循环取证

- [x] 只读审计 `Desktop/Patch/MATLAB/MATLAB_VM_Fix`：MATLAB 的 CEF JIT `brk #0`、CEF GPU 合成 workaround、Java2D software fallback、figure `Painters+docked` 及 OpenGL 试验结论均有现成证据；确认 figure 离屏 PNG 正常但复杂 VBO+shader+MSAA 屏幕管线失败。
- [x] 只读核对 Devin：`~/.devin/argv.json` 当前开启 `disable-hardware-acceleration`；应用侧判据是 GPU helper 消失，不能用主进程命令行或存活判定 GPU 成功。未修改该文件。
- [x] 新 88 宿主证据 `.diag/build88-post-reboot-20261002-230724/` 显示 `guest menu extra not acknowledged; repair attempt` 已增长至109；客机 `/tmp/VirtualMacGuestTools.ready` 不存在。同期 Jetsam 将 `com.apple.Virtualization.VirtualMachine` 列为最大进程，wakeups 报告为258/s。该时间相关证据不能单独归因 GPU/88/macPad。
- [x] 根因收窄到握手条件：`VirtualMacGuestToolsApp.m` 的 readiness marker 被 `statusItem.button/menu` 条件挡住，而 host configuration/OpenGL policy 已先执行。最小修复是 marker 只依赖 ReadyToken，避免宿主每10秒重复 payload repair；不改变 GPU 声明/协议/应用开关。
- [x] 独立构建 `.diag/guest-tools-ready-fix-build/` 通过，arm64/x86_64 guest tools、tar payload、codesign strict 均通过；未安装、未重启、未改运行中 VMM。
- [ ] 下一次含此改动的包首启验收 readiness acknowledgement、repair计数、wakeups，再进行 MATLAB/Devin GPU compositor 与屏幕像素 A/B。
## 2026-10-02 — IDA 13340 复核 PG 协议边界与 readiness 修复包

- [x] 用户加载 `ida-pro-mcp` Instance4；通过 `http://127.0.0.1:13340/mcp` health 核对：IDB=`VMGPU/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics.i64`，imagebase=`0x100000000`，auto-analysis/Hex-Rays ready。13337–13339 未使用。
- [x] IDA 反编译证据保存 `.diag/ida-13340-gpu-evidence-20261002/`：`writeDeviceInfo @0x100002a04` 逐项读取真实 Metal getter；`setBinaryVersion @0x100011efc` 对请求版本执行 `min(request,43)`；`faultAtOffset @0x10001bdd8` 设置 fault offset、signalFault 后在 condvar 等待；selector xrefs 与 PGFifoThread 初始化也保存。
- [x] 这些二进制证据加强现有决策：不强升 Tier2/207、不伪造 getter/serializer；GPU fault 的停车语义是 PGFIFO 设计事实，不能用进程存活掩盖。
- [x] readiness 修复包完成：`VirtualMac/build/release/VirtualMac_1.2.3_0658b082ec.deb`，版本 `2:1.2.3+89.0658b08.gpuready`，SHA256=`dd3fa1ecbea974996e58a5c799f6a9c3de7857ec476f6f2200a06ba0d130d66c`；包内 GuestTools 与独立修复构建 SHA256 均为 `b2a3cd74fe3b04d03c2718de25b1257c6401a728cace4a5c677ef8e024fa1c95`，codesign strict 通过。
- [x] 89 包已复制到本地飞牛 `VirtualMacOniPad_iOS` 并逐字节 hash 一致；未安装、未重启、未操作运行中 VMM。下一步仍需用户在正常关机后安装，验收 `guest menu extra acknowledged` 不再出现 repair 增长，再做 MATLAB/Devin 的真实 compositor/像素 A/B。
## 2026-10-02 — 89 尚未安装；新增 ReportCrash 诊断边界

- [x] SSH 只读核对：宿主 `/tmp/vmm.stderr.log` 仍为 22:47 的 88 启动，未出现 89 readiness acknowledgement；本次 `dpkg-query` 无版本输出，不能声称 89 已安装。
- [x] 拉取 23:17、23:18、23:21、23:24 的四份小型 `ReportCrash-*.ips`。逐字证据均显示崩溃进程是 iPadOS `/System/Library/CoreServices/ReportCrash`，`SIGABRT` 位于 `dyld4::Atlas::ProcessSnapshot::Serializer::deserialize`，不是 VirtualMac VMM、GuestTools 或 GPU fault；证据保存在 `.diag/post-89-check-20261002/`。
- [ ] 89 仍待用户正常关闭 VM 后安装；安装前不做运行中替换。安装后首要检查 readiness marker、repair attempt 是否停止，以及新的 VMM/GPU 日志。
## 2026-10-02 — 当前 88 客机 OpenGL 复杂离屏基线

- [x] 使用当前客机已构建的 arm64 OpenGL probe，显式加载 `/Library/VirtualMac/OpenGLPVGCompat.dylib`；renderer=`Apple Paravirtual device`、GL=`4.1 Metal`。
- [x] 基础路径连续通过：uniform shader、VBO、indexed/non-indexed draw、FBO、`glReadPixels`，全部 `gl-error=0`、exit0。
- [x] 新增 ignored `.diag/msaa-probe-20261002/`：独立 4x multisample texture FBO + shader/VBO draw + `glBlitFramebuffer` resolve + `glReadPixels`，输出 `msaa-fbo=0x8cd5 draw-error=0x0 blit-error=0x0 read-error=0x0 pixel=255,0,0,255`、exit0。
- [x] 证据把 MATLAB figure 缺口收窄到窗口 drawable/present、上下文复用或 MATLAB 特有多通道状态；不能再把“VirtualMac 不支持 MSAA/FBO”作为根因，也不应因此扩大协议能力表。下一步需做窗口交换与连续多帧生命周期 probe。
## 2026-10-03 — 保持 88；90 版本闸门与 swap hook 静态审计

- [x] 用户选择先保持 88，隔壁项目继续工作；未安装 89、未重启、未碰运行中 VMM。
- [x] 核对 iPad 实际 dpkg：仍为 `2:1.2.3+88.bb005a7dfe.gpuvulkan`；宿主 `VirtualMac.log` 的 readiness repair 已增长至至少 attempt 409。89 readiness 修复没有运行时证据。
- [x] 静态审计 `OpenGLPVGCompat.m` 与 host framebuffer/XPC 代码：guest shim 没有 CGLFlushDrawable/glSwapBuffers/drawable present hook；现有 frame callback/IOSurface ACK 在 host VMM 侧，不应未经窗口像素证据就全局 hook。
- [x] 结论：当前不构建重复或猜测性的 90；90 必须等待 89 首启握手验收和 MATLAB 窗口 present/context 生命周期失败证据。闸门写入 `docs/GPU-APP-COMPATIBILITY.md`。
## 2026-10-03 — NSOpenGLView 窗口路径基线纠错

- [x] 新建 ignored `.diag/window-gl-probe-20261003/`，用 `NSOpenGLView`、真实 window drawable、VAO/VBO、shader、连续 `flushBuffer`、`glReadPixels` 跑 2 秒；142 帧、`failed=0`、exit0。渲染器字符串在 context teardown 后为 null，不能据此判失败。
- [x] 初版探针曾在 core profile 漏绑 VAO，导致 `glEnableVertexAttribArray` 的 `GL_INVALID_OPERATION (0x502)`；已定位为测试程序错误并修正。不能把初版失败误归因 VirtualMac 的 window present。
- [x] 当前没有足够证据构建 90；窗口 drawable 基线也通过，MATLAB figure 的特有失败仍需在 MATLAB 实际进程取得屏幕像素/上下文日志后再改。
## 2026-10-03 — Devin Electron/ANGLE 静态能力映射

- [x] 核对 `/Applications/Devin.app`：Electron Framework 为 arm64，链接 Metal、MetalKit、OpenGL、IOSurface；Chromium 内含 ANGLE WebGL/WebGL2、Metal/Vulkan、CAMetalLayer 与 texture-sharing 相关路径。
- [x] 当前 `~/.devin/argv.json` 仍启用 `disable-hardware-acceleration`。VirtualMac GL shim 只覆盖 GLD，不覆盖 ANGLE Metal compositor/CAMetalLayer/IOSurface texture-sharing；不能据此删除 Devin workaround 或打 90。
- [ ] 下一步若要改变 Devin 默认，必须取得 GPU helper、ANGLE backend、WebView 实际像素的独立 A/B；与 MATLAB CEF/JIT/figure 证据分开。
## 2026-10-03 — GPU 回归复核与 MATLAB batch 边界

- [x] 当前 HEAD 回归：particle shader lowering 严格编译/运行通过；Metal family compatibility 严格 warnings（含 IOKit）通过；deviceInfo reply ASan/UBSan 通过。
- [x] MATLAB R2024a `-batch` 的只读 renderer/隐藏 figure/export 尝试 90 秒无输出、无 PNG，不能替代 GUI GPU 验证，也不足以归因 VirtualMac GPU；未修改 MATLAB 配置或用户文件。
- [x] 本轮无功能源码变化、无 90 包；继续等待真实 MATLAB/Devin GUI 或 89 readiness 首启证据。
## 2026-10-03 — MATLAB CEF JIT 原生能力实测

- [x] 客机只读 probe `.diag/jit-capability-20261003/` 直接调用 `pthread_jit_write_protect_supported_np`，输出 `=0`；符号来自 libSystem。
- [x] 该值与 MATLAB CEF `TS_PROCESS_CRASHED` 的 `brk #0` 条件一致，确认这是 guest hypervisor/JIT capability 边界，不是当前 GPU renderer/MSAA/FBO 缺口。
- [x] 不把 getter 强制返回1加入 VirtualMac；那等价于应用二进制症状补丁，且未证明 JIT 写保护/执行内存契约。90 继续保持证据闸门，不构建。
- [x] 追加 JIT probe：匿名 RWX `mmap` 返回 `errno=13/EACCES`，`pthread_jit_write_protect_np` 切换不崩但不提供执行内存；进一步证明不能只伪造 getter。
- [x] Instance1（macPad iPadOS16.3 kernelcache）只读 Hex-Rays：`_proc_check_map_anon @0xfffffe00092a68c4` 的 MAP_JIT 路径要求 developer mode/device unlocked 并查询 `dynamic-codesigning` entitlement；kernel strings 明确 `MAP_JIT requires sandboxing` / `MAP_JIT requires the dynamic-codesigning entitlement`。这把 MATLAB JIT 缺口从猜测提升为内核证据；Instance2/3 仅用于上下文，未改 IDB。
## 2026-10-03 — 90 候选：GuestTools repair 风暴上限

- [x] 新鲜 iPad 宿主证据：88 仍安装，`guest menu extra not acknowledged; repair attempt` 已到至少 595，且每次 payload current；没有新 GPU fault 字段。
- [x] `VZGuestTools.m` 新增按 guest agent connection generation 的 repair 上限：最多3次 payload repair；超过后每60秒只做 readiness probe，agent reconnect 会重置 generation。这样即使 marker 再次丢失，也不会无限复制 payload/制造 wakeup。
- [ ] 需严格编译、宿主日志静态检查和完整包内容验证后，才交付 90 候选；不安装、不重启、不操作运行中 VMM。

## 2026-10-03 — Devin 隔离硬件模式运行时证据

- [x] 临时 HOME/用户目录启动 Devin，不改用户 `~/.devin/argv.json`；GPU helper 正常创建，命令行无 `--disable-gpu`/`--use-gl=disabled`。
- [x] GPU helper `vmmap` 保存在 `.diag/devin-hwprobe-20261003-c/`，加载 `AppleParavirtGPUMetalIOGPUFamily`、Metal/MetalKit、IOSurface、IOGPU、OpenGL。
- [ ] 尚未取得 WebView/ANGLE 实际像素或 `chrome://gpu` diagnostics；不把 GPU helper 存活当作完全修复。

- [x] Devin CDP 像素闸门完成：`SystemInfo.getInfo` 报 `ANGLE_METAL`、Apple Paravirtual device、gpu_compositing/webgl/webgpu enabled、processCrashCount=0；attached workbench renderer 的 WebGL2 `clear/readPixels` 返回 `[26,51,77,255]`、error=0。证据 `.diag/devin-cdp-pixel-20261003-b/`。
- [x] 结论：当前 88 已能支持 Devin ANGLE WebGL 基础硬件渲染，应用侧 `disable-hardware-acceleration` 对该基础路径不是必需；不自动修改用户 argv，复杂 WebView/视频/WebGPU 仍待单独验证。
- [x] 同一隔离 CDP renderer 的 `navigator.gpu.requestAdapter()` 成功：maxBufferSize=4294967292、maxTextureDimension2D=16384，features 含 BC/ASTC/ETC2、shader-f16、subgroups、texture tier1/tier2；证据 `.diag/devin-webgpu-20261003/result.json`。
- [x] Devin WebGPU 实际 workload 通过：bgra8unorm texture、clear render pass、command submit、copy/map-read，返回 pixel=`[77,51,26,255]`；证据 `.diag/devin-webgpu-render-20261003/result.json`。这证明基础 WebGPU 执行链可用，仍不等于所有 WebView/视频/复杂 workload 已验收。

## 2026-10-03 — 90 GPUReady 候选包完成

- [x] 90 候选包含两项真实稳定性改动：GuestTools readiness marker 不依赖 status-item button/menu；同一 guest-agent connection 的 payload repair 最多3次，之后每60秒只 probe，reconnect 重置上限。
- [x] 限流5 jobs/background完整构建、stage audit通过。包：`VirtualMac/build/release/VirtualMac_1.2.3_17dfa3e47a.deb`；Debian version=`2:1.2.3+90.17dfa3e.gpuready`；SHA256=`869328336372ab5dcee4b59e2ac9c62cfd87169a58339c3a356e704604f50262`；20,858,104 bytes。
- [x] 解包验证：App二进制含 suppression 字符串；包内 GuestTools 与修复构建 SHA256=`b2a3cd74fe3b04d03c2718de25b1257c6401a728cace4a5c677ef8e024fa1c95`；App ldid CodeDirectory/CDHash 可读；包未含 VM 数据。
- [x] 已复制为 `VirtualMac_1.2.3_17dfa3e47a_GPUReady90.deb` 到本地飞牛目录，两处 hash 一致；未安装、未重启、未注入运行中 VMM。90 仍需首启验证后才能声称减少 wakeups 或解决卡死风险。
