# WORKLOG — 逐条进度日志（压缩后先读本文件 + AGENTS.md）

## 2026-10-01（会话 1：接手 + 盘点 + GPU 研究启动）

### 完成
- [x] 读三份交接文档（SUPER-HANDOVER / VM-crash-fix-and-build-notes / VMGPU-REFERENCE）
- [x] 复述十条准则、区分战线已知/未知（见会话首轮回复）
- [x] **SSH 通道打通**：`sshpass -p cisco ssh -p 2222 root@192.168.64.1`（NAT 网关=宿主 iPad；22/2222 双通；密码问用户，勿入库）
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
2. 验证 SSH：`sshpass -p cisco ssh -p 2222 root@192.168.64.1 'echo ok'`（22 也试）。
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
