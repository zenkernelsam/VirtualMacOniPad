# GPU 主线研究：让 VM GPU 达到"真 Mac 虚拟机"水准

> 起始：2026-10-01 · 维护：Devin · 状态：**进行中**
> 用户目标：「尽量找到和解决现在虚拟机GPU不完美运作，想做到和Mac运行虚拟机一样的原生GPU支援能力」
> 已知痛点（用户原话）：Matlab、Devin GPU 无法运转；不少软件要 disableGPU。

---

## 0. 当前结论（TL;DR）

**GPU 不完美的主干已定位为"双向协议错配"**：
- 客机侧 Metal 驱动插件 = `AppleParavirtGPUMetalIOGPUFamily.bundle` **40.7.1（macOS 15.6 构建）**
- 宿主侧执行端 = payload `ParavirtualizedGraphics.framework` **13.0.34（macOS 13.2.1 IPSW 提取）**
- 中间隔了 ~3 个大版本的协议演进。**客机日常运行即有 GPU 复位风暴**（guest kernel `gpuRestart`，9/26 起每天发生，触发者横跨游戏/Electron/WebKit/WindowServer），特征签名 = 已提交命令宿主侧永不完成（`submitEvent:INCOMPLETE`）。

另一独立问题：**OpenGL 完全依赖客机 shim**（`OpenGLPVGCompat.dylib`）——不注入时加速渲染器=0。shim 机制已完全摸清（见 §3）。

---

## 1. 通路总图（证据已核实）

```
客机 App (Metal / GLD-OpenGL / Quartz)
 └→ 客机内核 AppleParavirtGPU (IOAcceleratorES) + 用户态插件
    AppleParavirtGPUMetalIOGPUFamily.bundle (40.7.1, macOS15.6)   ← 序列化端
     └→ virtio GPU fifo → 宿主 VMM 进程 (com.apple.Virtualization.VirtualMachine, iPad)
          └→ ParavirtualizedGraphics.framework 13.0.34 (Ventura)  ← 反序列化/执行端
               └→ MetalSerializer.framework → iPadOS Metal → M1 GPU
```
- 客机 ioreg 逐字：`AppleParavirtGPU`（`MetalPluginName=AppleParavirtGPUMetalIOGPUFamily`、`PerformanceStatistics: Alloc system memory=642MB`）、`AppleParavirtDisplay` 2732×2048 external=Yes。
- 客机内核对象（IOKitDiagnostics）：`AppleParavirtGPU=1`、`AppleVirtIOUSBDeviceController=0`（类在但未实例化）、`AppleVirtIOBalloonTransaction`、`AppleVirtIOSocketEventTransaction=8`。
- 显示链：`_VZGraphicsDevice`+`_VZFramebuffer`，`framebuffer activated rate=30`，"已连接原生PVG帧缓冲区"（VirtualMac.log 逐字）。

---

## 2. 客机 GPU 复位风暴（本日实锤）

### 2.1 规模与触发者（`/Library/Logs/DiagnosticReports/Kernel_*.gpuRestart`，逐字统计）
- **20 份报告**，最早 9/26，**每天都有**；触发进程：`witchontheholyni`×8、`GitHub Desktop Helper`×7、`com.apple.WebKit`×3、`WindowServer`×2。
- → **非 app 特异**：凡是高负载 Metal 提交都可能踩中。WindowServer 都中招说明连系统合成路径都会触发。

### 2.2 复位链（`log show` 22:51–22:52 逐字序列）
1. `IOGPUScheduler::signalHardwareError(eRestartRequest)` → `hardware_error_interrupt` → `GPURestartBegin`（channel 1）
2. `GPU hang: AppleParavirtGPU HardwareDiagnosisReport`：Exec 队列 `submitEvent:INCOMPLETE`×70，`barrierEvent` 部分 INCOMPLETE——**提交给宿主的命令永远不 retire**
3. `Trying to restart GPU (Undefined)`（`Graphics Hardware: Undefined`——PVG 不报标准硬件名）
4. 19ms 后再 hang → 升级为 `global restart`
5. App 侧：`witchontheholynight: (Metal) Execution of the command buffer was aborted ... kIOGPUCommandBufferCallbackErrorHang (00000003)`
6. 复位后 `Clean slate for app[witchontheholyni]`——能续跑但会再挂（循环）

### 2.3 卡死队列 opcode 分布（全部报告统计）
`CMD=0x37` 出现 17/20（几乎必有）、`0x1e` 高频、`0x8`、`0x25`、`0x28` 偶见。这些是 PG fifo 命令字——**0x37 大概率是"执行命令缓冲区"提交**，即普通的 GPU 工作提交就会挂住（opcode→含义映射待 IDA Instance4 对 PG 反汇编确认）。

### 2.4 含义
客机侧一切正常（校验和、队列、fence 都工作）；**卡点必在宿主**：宿主 PG/MetalSerializer 收到命令后未推进完成 fence。候选宿主机制（待证）：
- **(a) 反序列化失败→fifo 标记 faulted 停摆**：PG 有 `_faulted`/`_faultCond` ivar 与 `_reportStampWaitTimeoutSource`（符号证据）。若某命令反序列化抛异常且恢复路径不重排后续命令 → 队列楔死 → 客机超时复位。
- **(b) 未知 opcode/字段**：客机 15.6.1 插件发出 Ventura 不认识的命令格式 → 反序列化卡在中途 → 同上楔死。
- **(c) 宿主 Metal 真挂**：iPad 单颗 GPU 同时跑 iPadOS UI + 客机转发负载 + jetsam/显存压力 → MTLCommandBuffer 长时间不完成（宿主侧 GPU hang）。
- **(d) 内存双计/jetsam 连锁**：vmmhook.m:86-90 注释逐字："8 GiB guest plus an 8 GiB Metal workload reaches a one-times-physical limit on a 16 GiB iPad" → VMM 已放宽到 2×physical 的 non-fatal high-water——**重载 GPU 时宿主内存压力是真实风险**（客机 devin .diag 显示 34GB 脏写/换页，说明负载确实重）。

**决定性取证（待 SSH 恢复）**：iPad `/tmp/vmm.stderr.log`、`/tmp/pvg-trace.log` 在复位时刻的记录——若见 `refusing unmapped mappedAddressForOffset`/`TASK_ADDRESS_UNMAPPED` = 翻译失败路径(a)；若见 Metal/serializer 断言 = (b)/(c)。

---

## 3. OpenGL 通路（已完全摸清）

- **无 shim 时**：客机 `CGLChoosePixelFormat(accelerated)` → `count=0`，只能 `Apple Software Renderer 4.1`（本机 opengl-renderer 探针逐字输出）。
- **注入后**：`count=2, accelerated=1, renderer="Apple Paravirtual device", version="4.1 Metal - 89.4"`——GLD-over-Metal-over-PVG 工作，三角渲染+回读成功。
- 注入面：客机 `launchd` 全局 `DYLD_INSERT_LIBRARIES=/Library/VirtualMac/OpenGLPVGCompat.dylib`（`launchctl getenv` 逐字）；GUI 进程生效，CLI 子进程不继承（本机 shell 即无 env——用户态跑 CLI GL 程序会软渲，**这本身可能是一个"CLI 工具无 GPU"的用户可见 bug**）。
- **机制**（`vz/guest/OpenGLPVGCompat.m`，393 行）：
  1. `__interpose` 掉 `IORegistryEntryCreateCFProperty`：进程查询 PVG 节点的 `IOGLBundleName` → 返回 `AppleMetalOpenGLRenderer` + 调 `EnablePVGOpenGL`（line 366-375）。
  2. `EnablePVGOpenGL`（line 298）：仅当进程走到 GL 初始化才触发；对 `AppleParavirtDevice` 类 swizzle `supportsFamily:` → **谎报 Apple1–Apple7**（line 139-147：*"GLD selects its modern agx2 path when Apple7 is present; PVG otherwise exposes only Mac/Common families"*），并接管 `newCommandQueue`→`commandBuffer`→`renderCommandEncoderWithDescriptor:`。
  3. `PVGRenderEncoder`（line 149+）：清 `defaultRasterSampleCount`（≠0→设0）+ `ClearCustomSamplePositions`（ivar 手术把 `numCustomSamplePositions` 清零，因为 Metal 公开 setter 对 0 count 无效）——即"Ventura serializer 拒认的 GLD 提示"。
  4. Rosetta 专用：`PVGSetVertexBuffer` 把 x86 侧 16KiB staging 改为 `setVertexBytes:` 内联（PVG 零拷贝映射对 Rosetta 写不可见——line 191-197 注释）。
  5. 进程 denylist（`ProcessUsesUnsupportedOpenGLPath`）：firefox/Firefox GPU Helper/plugin-container/sublime_merge 等走原生软渲。
- 宿主侧配套开关：VZGuestTools 经 virtio socket :505050 下发 `OpenGLAllowed`/`OpenGLAcceleration` 策略 plist（`VZGuestTools.m:440-441`）。
- **已知限度**（`vmmhook.m:559-563` 逐字）："Ventura's preview-ABI tunable ... its **AppleMetalOpenGLRenderer output has blank regions through the iPad PVG stack**. Keep ... without activating that incomplete renderer path in production." → 作者已知 GLD 渲染有画面缺陷区（blank regions），未上 EXPERIMENT_VENTURA_OPENGL。

---

## 4. 能力协商面（APVFeatures——本次最大结构性发现）

### 4.1 宿主 PG (Ventura 13.0.34) 只懂 14 个 feature 位（strings 逐字模板）
`{APVFeatures="objectTables"B"efiDisplay"B"displayDoorbell"B"mapperIOSurfaces"B"synchronizeAndDiscardResources"B"displayMapperSurface"B"discardResources"B"displaySleep"B"supportsRGhAPresents"B"synchronizeDiscardChildResources"B"dualPlaneTextures"B"displaySetProperties"B"displayDimensionFloats"B"metalHeaps"B}`
另有 `binaryVersion` 握手字符串："Guest requested binary version: %u, setting binary version to: %u"、"Guest requested an unsupported binary version"、"This command is unsupported in this binary version"、"Guest doesn't support host version"——**协议按 binaryVersion 门控命令**。

### 4.2 客机插件 (40.7.1 / 15.6.1) 认 38 个键
新增（宿主字符串中不存在）：`supportsOpenGL`、`supportsArgumentBuffers`、`supportsHeapHazardTracking`、`supportsCommandBufferJump`、`supportsDynamicAttributeStride`、`supportsProgrammableSamplePositions`、`supportsVariableRasterizationRateMaps`、`supportsTileShadersImageBlocks`、`supportsSharedStorageHeaps`、`supportsProtectionOptionsEnvelope`、`supportsMultiplaneMippedBlitTextures`、`supportsSwizzledTextures`、`supportsVertexAmplification`、`supportsCorrect2pXR10A8`、`supportsCorrectBaseVertex`、`supportsIOSurfaceTextureWithRotation`、`supportsInsertCompressedTextureReinterpretationFlush`、`supportsInfoEncoder`、`supportsBlitEncoderSPI`、`supportsObjectUniqueIdentifier`、`supportsComputePassDescriptorDispatchType`、`supportsDisplayCompositorParameters`、`supportsDisplaySetGuestICCProfile`、`supportsSunburstDisplay`、`maxFIFOCount`、`s8ByteCountForD32S8`、`bufferFromIOSurface` 等。

### 4.3 第二层协商（客机插件内的 device descriptor / serializer 特性模板，strings 逐字）
- `PGSerializerFeatures = {supportsReflectionSerializationVersion, supportsSharedTextures, supportsOpenGL, supportsIOSurfaceTextureWithRotation, supportsCorrectBaseVertex}` —— `supportsOpenGL` 即 shim 要打开的那一位。
- 描述符含 `DeserializerVersion`、`HostGPUFamily`、`MaxMetalShaderVersion`、**`SupportFlags2023`{SupportsApple5,SupportsDynamicAttributeStride,SupportsTexture2DMultisampleArray,...}、`SupportFlags2024`{SupportsLargeUserTasks,SupportsLargeKernelTasks,SupportsCommandBufferJump,SupportsRangeBuffer,SupportsSharedMemoryHeap,SupportsArgumentBuffers,SupportsSIMDReduction,SupportsFloat16BCubicFiltering,SupportsSIMDShuffleAndFill,SupportsConditionalLoadStore,SupportsComputeCompressedTextureWrite,SupportsSharedTexturePlacement}`——Ventura 宿主填这些位到什么值、客机是否忠实裁剪，是"客机有没有发出宿主消化不了的命令"的直接判定点。**待 IDA 或运行期 dump**。

### 4.4 客机 Metal device 探测（本机 metal-device 探针逐字）
`AppleParavirtDevice "Apple Paravirtual device" registryID=0x1000001a1`；supportsFamily：Apple 族全 0；Mac1=1、Mac2=1、Mac3+=0；Common1/2/3=1、Common4=0。BC7 纹理可建（metal-bc-probe 返回非 nil）。

---

## 5. 假设-取证矩阵（更新）

| 假设 | 现状 | 决定性取证 | 验证方式 |
|---|---|---|---|
| H-a：pvg_trace 异常路径楔死 fifo | 可能（代码证据：NSException→PG 恢复路径未知） | iPad `/tmp/pvg-trace.log` 是否有 `TASK_ADDRESS_UNMAPPED`/`refusing unmapped` | SSH 恢复后拉对应时段 |
| H-b：15.6.1 插件发出 Ventura 不识的 opcode | 待证（协议按 binaryVersion 门控，理论应裁剪；可能有漏） | PG 反汇编命令分发表 vs 客机发出 opcode | IDA Instance4 |
| H-c：宿主 Metal 真挂/资源压力 | 可能（VMM 2×physical 放宽注释 + iPad 单 GPU 竞争） | vmm.stderr.log 该时段 Metal/jetsam 报错 | SSH 恢复后拉 |
| H-d：OpenGL 覆盖不全→部分 app 仍软渲/崩溃 | 已证部分（CLI 不注入；blank regions 已知） | 逐 app 复现 | 客机内跑 Matlab/Devin 实测 |
| H-e：denylist 外 app 走 GLD 仍踩 serializer 拒收字段 | 待证 | shim 日志 `VIRTUAL_MAC_OPENGL_DEBUG=1` | 客机复现 |

---

## 6. 下一步（可测第一步 + 验收）

1. **[待 SSH]** 拉 `/tmp/vmm.stderr.log`+`/tmp/pvg-trace.log` 对应 gpuRestart 时段 → 分类宿主失败类型。**验收：逐字日志行挂到上面四个假设之一。**
2. **[客机可做]** 复现 witchontheholynight/GitHub Desktop 挂起 + 用 `log stream --predicate 'process=="kernel" AND eventMessage CONTAINS "GPU"'` 或 Console 抓现场；对 witchontheholynight 这类 Patch 项目 app 可从 `~/Desktop/Patch` 读它用什么渲染 API。**验收：app 侧错误 + 客机 kernel hang 时间戳对齐。**
3. **[IDA Instance4]** 反汇编 PG 的 fifo 命令分发 + `_faulted`/`_faultCond` 用法 → 证明"抛异常后命令是否 retire"。**验收：反编译片段+函数名。**
4. **[长期]** 若判定为 (b) 协议差距：评估两条路线——①客机侧收紧（把越界 feature 关掉，= 往正确层的诊断+门控，非症状补丁）；②把宿主 payload 换成更新 macOS 版本重建的 PG/MetalSerializer（版本闸门：需验证 iPadOS 16.3 兼容性，工作量大概率大）。

## 7. 证据存档
- 客机：`/Library/Logs/DiagnosticReports/Kernel_*.gpuRestart`（20 份，每日）
- 本机：`.diag/guest-probes/`（metal-device/metal-bc-probe/opengl-renderer 源码与二进制）
- iPad（待取）：`/tmp/vmm.stderr.log`、`/tmp/pvg-trace.log`

## 追加取证（2026-10-01 深夜）

### A. 卡死位置再收窄：仅 Exec 通道

`Kernel_2026-10-01-225208_Ciscodexuniji.gpuRestart` 逐字字段：

| 通道 | written | read | 待处理 |
|---|---|---|---|
| **Exec** | 1321961976 | 1321939736 | **~22KB 未消费，70 cmds 全 INCOMPLETE** |
| Object | 15865088 | 15865088 | 0（已排空）|
| Memory | 17004832 | 17004832 | 0（已排空）|
| Display[0] | 20810388 | 20810328 | 1 cmd（CMD=0x8 barrier）|

→ 客机侧写指针前进、宿主侧 read 指针停住：对象表/内存通道正常 retire，**唯独 exec（Metal command buffer 提交）通道被楔住**。指向宿主 PG exec 消费线程卡死/静默失败，不是传输层问题。

### B. 宿主 Cmd* 调度词表（Ventura 全量 32 条）

`strings VMGPU/.../ParavirtualizedGraphics | grep '^Cmd'` 抽出宿主反序列化器全部命令处理器（签名统一 `stampValue:withPayload:payloadSize:`）：
CmdNOP/CmdDebug/CmdDelay/CmdDeprecated/CmdDefineChildFIFO/CmdDeleteChildFIFO/CmdDefineTask2/CmdDeleteTask/CmdDeleteObject/CmdDeleteResource/CmdDeleteIOSurfaceBacking2/CmdMapMemory2/CmdUnmapMemory/CmdReplacePhysical/CmdSetObjectList/CmdExecIndirect2/CmdGetDeviceInfo/CmdGetComputeInfo/CmdHeapTextureSizeAndAlign/CmdSynchronizeResources/CmdInvalidateResources/CmdDiscardResources/CmdSynchronizeAndDiscardResources/CmdDisplayAck/CmdDisplayCursorGlyph/CmdDisplayCursorShow/CmdDisplaySetProperties/CmdDisplaySetSharedStatePage/CmdDisplaySleepState/CmdDisplaySwapMapping/CmdDisplayTransaction2_DEPRECATED/CmdDisplayTransaction3。

**opid→Cmd 映射须等 IDA**（dispatch 表是函数指针数组，strings 无顺序）。

### C. 宿主 stderr 在拿到日志前可用的线索

宿主错误串含 `Invalid FIFO command length (%lu <= %u <= %llu) opid=%u on channel %u`、`Guest used deprecated command=%u: on channel %u`、`This command is unsupported in this binary version` —— 若 VMM stderr 里有 opid 打印，即可锁定具体命令。

### D. 时间相关性（假设级）

22:52:08 客机 GPU reset（witchontheholynight）↔ ~22:53 起 iPad sshd 拒连（两端口 reset）——GPU 复位风暴→宿主资源耗尽 的链式因果可能成立（VMM 宿主进程 ~275%CPU 常驻）。待 SSH 恢复用 `log show`/`uptime`/`memory_pressure` 历史验证。

### E. 客机插件能力 schema 逐字（40.7.1，`AppleParavirtGPUMetalIOGPUFamily`）

`strings` 抽出的 APVFeatures 字段序列（B=bool, I=int）：
`valid/unsupported/objectTables/efiDisplay/displayDoorbell/mapperIOSurfaces/synchronizeAndDiscardResources/displayMapperSurface/discardResources/displaySleep/supportsRGhAPresents/synchronizeDiscardChildResources/dualPlaneTextures/displaySetProperties/displayDimensionFloats/metalHeaps/bufferFromIOSurface/maxFIFOCount/s8ByteCountForD32S8/supportsSharedTextures/supportsInfoEncoder/supportsDefaultRasterSampleCount/supportsVertexAmplification/supportsSunburstDisplay/supportsProgrammableSamplePositions/supportsVariableRasterizationRateMaps/supportsTileShadersImageBlocks/supportsDisplayCompositorParameters/**supportsCmdExecIndirect3**/supportsSwizzledTextures/supportsDynamicAttributeStride/supportsBlitEncoderSPI/supportsMultiplaneMippedBlitTextures/supportsComputePassDescriptorDispatchType/supportsObjectUniqueIdentifier/supportsCommandBufferJump/supportsSharedStorageHeaps/supportsHeapHazardTracking/supportsProtectionOptionsEnvelope/supportsInsertCompressedTextureReinterpretationFlush/supportsArgumentBuffers/supportsDisplaySetGuestICCProfile/supportsCorrect2pXR10A8`

Guest 侧 PGSerializer 类族：`PGSerializer{Render,Compute,Blit,Info,}CommandEncoder`——含 `executeCommandsInBuffer`（ICB）、`setAccelerationStructure`/`IntersectionFunctionTable`/`VisibleFunctionTable`（光追）、`encodeEndDoWhile/EndIf/EndWhile/StartElse`（动态控制流）、`insertCompressedTextureReinterpretationFlush`。

**deviceInfo schema**（客机要宿主填的探测字典）：`SupportFlags2024` 位域=`SupportsLargeUserTasks/LargeKernelTasks/CommandBufferJump/RangeBuffer/SharedMemoryHeap/ArgumentBuffers/SIMDReduction/Float16BCubicFiltering/SIMDShuffleAndFill/ConditionalLoadStore/ComputeCompressedTextureWrite/SharedTexturePlacement`；另有 `DeserializerVersion`、`HostGPUFamily`、`ArgumentBuffersTier`、`MaxVertexAmplificationCount`、`MaxMetalShaderVersion(Major/Minor)` 等。

### F. 具体根因假设（已被 IDA 证据修正——见 §G）

~~`supportsCmdExecIndirect3` 存在 ⇒ 客机发出 CmdExecIndirect3（或任一 opcode>宿主表）触发 `Invalid FIFO command`~~ —— **修正**：IDA 逆向后确认 gpuRestart 报告中最后卡住的 `CMD=0x37` 恰是 `CmdExecIndirect2`（合法 opcode），非未知命令。见 §G。

### G. IDA 逆向：Ventura PGFIFO 命令分发器全解码（2026-10-01 深夜，Instance4）

二进制：`VMGPU/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics`（Ventura 13.2.1 payload，黄金基线只读样本）。

#### G.1 分发器本体

`-[PGFIFO processFifo]` @ `0x100021594`（NSThread 名为 `PGFifoThread`，由 `-[PGFIFO start]` @ `0x10001bcb0` 用 `initWithTarget:selector:` 拉起）。循环逻辑：

1. `getFifoBytes:into:` 读 12B 头 → `{cmdLen(v33), barrierCount(v32), opid(v31), stampValue(v34)}`；
2. cmdLen ∉ [12, commandLength] → `os_log_error` `"Invalid FIFO command length (%lu <= %u <= %llu) opid=%u on channel %u"`；
3. `barrierWait:barrier:`（≤32 barrier，v32<0x21）→ `advance` → `pushStamp:cmdID:`；
4. `switch(opid)` 分发到 `Cmd*:stampValue:withPayload:payloadSize:`；
5. **opid>0x40** → `"Invalid FIFO command: %u on channel %u"` → `sub_10001C504`（dump payload）→ `faultAtStampValue:` + `signalStampValue:` —— **坏命令被打 fault 并 signal 后循环继续消费**（非宿主停摆；客机侧看到该 stamp 完成但带 fault → 客机触发通道 teardown → 其后所有排队/续交命令全部 `submitEvent:INCOMPLETE`）。

#### G.2 Ventura opid→Cmd 全表（switch 逐 case 解出）

| opid | 命令 | opid | 命令 |
|---|---|---|---|
| 0 | CmdDebug | 0x22 | CmdUnmapMemory |
| 1 | CmdDisplaySetSharedStatePage | 0x25 | CmdDeleteResource |
| 2 | CmdDisplayAck | 0x28 | CmdDeleteObject |
| 4 | CmdDisplayCursorGlyph | 0x30 | CmdDefineChildFIFO |
| 5 | CmdDisplayCursorShow | 0x31 | CmdDeleteChildFIFO |
| 6 | CmdDisplayTransaction2_DEPRECATED | 0x33 | CmdSetObjectList |
| 7 | CmdDisplayTransaction3 | 0x34 | CmdInvalidateResources |
| 8 | CmdDisplaySwapMapping | 0x35 | CmdSynchronizeResources |
| 9 | CmdDisplaySleepState | 0x36 | CmdDeleteIOSurfaceBacking2 |
| 0xA | CmdDisplaySetProperties | **0x37** | **CmdExecIndirect2** |
| 0x1E | CmdNOP | 0x38 | CmdDefineTask2 |
| 0x20 | CmdDeleteTask | 0x39 | CmdMapMemory2 |
| 0x3A | CmdGetDeviceInfo | 0x3E | CmdSynchronizeAndDiscardResources |
| 0x3B | CmdGetComputeInfo | 0x3F | CmdDiscardResources |
| 0x3C | CmdReplacePhysical | 0x40 | CmdHeapTextureSizeAndAlign |
| 0x3D | CmdDelay | **>0x40** | Invalid → fault+signal |
| **3, 0x1F, 0x21, 0x23, 0x24, 0x26, 0x27, 0x29–0x2F, 0x32** | **→ CmdDeprecated（`"Guest used deprecated command=%u"`）** | | |

PGFIFO 方法表（相对方法表格式，class_ro_t @ `0x100050dc8`，mlist @ `0x100029c50`，57 项）：`processFifo=0x100021594`、`faultAtOffset:stampValue:=0x10001bdd8`、`faultAtStampValue:=0x10001bf00`、`signalStampValue:=0x10001c0b4`、`barrierWait:barrier:=0x10001bfa4`、`pushStamp:cmdID:=0x10001c274`、`CmdExecIndirect2=0x10001f4b4` 等。

#### G.3 CmdExecIndirect2 内部（`0x10001f4b4` → block `0x10001f9f8`）

- 信封 payload：`u32 taskID; u32 resourceCount; u32 cmdBufferCount;` + `24B×resources` + `16B×{offset,length}×cmdBuffers`（长度不符→`objc_exception_throw`）。
- `[device getTaskID:]`→`[task runBlock:]`（= `shared_mutex lock_shared` + 执行 block，`0x10000bd4c`，**无 @catch**）。
- Block 内：`[task prepareResources:count:event:value:]` → 取 `device.execQueue` 建 host `commandBuffer` → 可选 `encodeWaitForEvent:value:` → 逐 cmdBuffer `mappedAddressForOffset:length:`（取 guest 序列化流宿主映射地址）→ **`[task deserializer] decodeSegments:lengths:count:into:`** → `addCompletedHandler:`（block `0x10001feac`，内做 stamp signal）→ `encodeSignalEvent:value:` → `commit` → `completeResources:count:sync:completionHandler:`。
- `deserializer` = PGTask ivar@+48，类型 `<MTLDeserializer>`，由 **`@loader_path/../../../MetalSerializer.framework`**（payload 内置 Ventura 版 MetalSerializer）提供。→ **15.6 客机序列化器 ↔ Ventura 反序列化器的代际差就压在 `decodeSegments:` 这一行里。**

#### G.4 楔死闭环：`faultAtOffset:stampValue:` 停车语义（决定性）

`-[PGFIFO faultAtOffset:stampValue:]` @ `0x10001bdd8`（`faultAtStampValue:` @ `0x10001bf00` 是其薄封装）逐字行为：

1. 在 stamp 环上等空位（`a1+412/416` 环形表 + `a1+432` condvar）；
2. 置 `*(a1+773)=1`（fault 位）→ `setFaultOffset:` → `[device signalFault]`（通知客机）；
3. **若 `*(a1+772)`（quiesce 位）未置 → `condition_variable::wait(a1+664)` 停车** —— FIFO 线程就地冻结，直到 `quiesce` 被调（客机 GPU reset 通道重建时）。

⇒ **一条 faulted 命令 = 整条通道楔死**（read 指针冻结于中流、GPUstamp 停于最后完成值、其后全部 INCOMPLETE）。与 gpuRestart 报告逐字节吻合：`Exec written-read=41064B`、GPUstamp `0x33c46b00`、pending `signalStamp 0x33c46c00–0x33c47500` 全 `CMD=0x37`；`Display[0]` 的 `CmdDisplaySwapMapping`(0x8) `barrier 0: stampIndex=0x1 stampValue=0x33c4b900` 正是**被楔住的 Exec stamp 拖死的 barrier**。

**Fault 触发面全集**（stub xref 枚举）：`faultAtStampValue:` 约 29 个调用点覆盖**几乎全部 Cmd\* handler**（每个 Cmd 自己校验 payload，失败即 fault）+ dispatcher 3 处（bad length / bad opid / deprecated 路径）+ `CmdDeprecated`；`faultAtOffset:` 直调 3 处——`faultAtStampValue` 壳、CmdDeleteIOSurfaceBacking2 内联、`0x10001feac` = **ExecIndirect2 的 addCompletedHandler block**（宿主 Metal CB 带 error 完成 → fault → 同样 park）。

⇒ 模型 A（协议/内容校验 fault）与模型 B（宿主 Metal error 完成）**殊途同归，全是 `faultAtOffset` 停车**。异常路径（`objc_exception_throw`）存在但无 @catch → 若真发生 = VMM 整机 abort，与实际观测（VM 活、仅 GPU reset）不符，降权。

**一条 hook 定案**：`faultAtOffset:stampValue:`（或 `setFaultOffset:`/`signalFault`）——包装后记录 fault 时的 `currentCommandOffset`/stamp/返回地址 → 直接给出是哪个 Cmd/哪段负载触发的 fault（diagnostic 用，非修复）。

#### G.5 下一步取证（排序）

1. **楔死现场快照**（最廉价、不用重启 VM）：下次 GPU 复位发生时 SSH `sample <VMM pid>`（只读）——若 `PGFifoThread` 停在 `faultAtOffset` 的 `condition_variable::wait` ⇒ 模型 A/B·fault 停车实锤；若停在 `decodeSegments`/Metal 内部 ⇒ 纯挂起模型。
2. **一条 hook 定案**（diagnostic，见 G.4）：pvg_trace 增量包装 `faultAtOffset:stampValue:`（覆盖面 = 全部 Cmd\* 校验失败 + Invalid opid + Deprecated + ExecIndirect2 完成错误）——记录 `currentCommandOffset`、stamp、返回地址（→哪个 Cmd）、payload 头部若干字节，一次复现即可定位元凶。当前 pvg_trace 只包 task 级方法（`getTaskID`/`createTaskID`/`deleteTaskID`/commit/`mappedAddressForOffset`），**不碰 dispatcher**——需要新增。
3. 若元凶落在 Cmd\* 校验或 deprecated/invalid opid → 属协议层：查客机对应 opid 是什么新命令 → 选修法（宿主侧转实现 / 客机侧绕开 / 对齐 binaryVersion 协商）。
4. 若元凶落在 `decodeSegments` 或完成错误 → 属序列化代际：dump indirect segment 内容比对 MetalSerializer 版本字段；长期解 = payload 代际升级（换 15.x MetalSerializer/PG 全套，工作量大但有 VMGPU 黄金基线比对流程兜底）。

### H. 客机侧 opcode 词表（guest kext 反汇编，2026-10-02）

**提取**：boot kernelcache（Preboot）→ `ipsw kernel dec` → `ipsw kernel extract` 出 `com.apple.driver.AppleParavirtGPUIOGPUFamily`（15.0.0，arm64，396KB，符号在）。本地存档 `.diag/guest-kext-15.6.1/`（gitignored）。

**方法**：`AppleParavirtGPU::commandDescriptor(queue,task,AppleParavirtGPUFIFOCommandID)` @ `0xfffffe0008cdc8e8` 的全部 ~30 个调用点回溯 `mov w3,#imm` → guest 侧 FIFO 命令枚举实况：

| guest opid | 发送者（逐字符号） | Ventura 宿主归宿 |
|---|---|---|
| 0x1 | `AppleParavirtDisplay::setupSharedStateEv` | CmdDisplaySetSharedStatePage ✓ |
| 0x2 | `AppleParavirtDisplay::handleHostInterruptEv` | CmdDisplayAck ✓ |
| 0x4 | `program_hardware_cursor_gated` | CmdDisplayCursorGlyph ✓ |
| 0x8 | `program_hardware_swap_gated` | CmdDisplaySwapMapping ✓ |
| 0x9 | `do_power_state_change_gated` | CmdDisplaySleepState ✓ |
| 0xA | `program_hardware_swap_gated`(二参) | CmdDisplaySetProperties ✓ |
| 0xB | `setParameter` | **default → Invalid → fault** |
| 0xC | `setGuestICCProfile` | **default → Invalid → fault** |
| 0x20 | `AppleParavirtTask::free` | CmdDeleteTask ✓ |
| 0x22 | `MemoryMap::releaseFromGPUPageTable` | CmdUnmapMemory ✓ |
| 0x25 | `Resource::deleteHostResourceID` / `Device::deleteMemorylessTexture` | CmdDeleteResource ✓ |
| 0x28 | `Device::deleteObject` | CmdDeleteObject ✓ |
| 0x30 | `VirtualChannel::init` | CmdDefineChildFIFO ✓ |
| 0x31 | `VirtualChannel::free` | CmdDeleteChildFIFO ✓ |
| 0x33 | `Task::setResourceHeap`（feature byte@task+0x595 **清零时**） | CmdSetObjectList ✓ |
| 0x35 | `Resource::synchronize` | CmdSynchronizeResources ✓ |
| **0x37** | `CommandQueue::processSegmentKernelCommand` | **CmdExecIndirect2 ✓** |
| 0x38 | `Task/KernelTask::defineHostTask` | CmdDefineTask2 ✓ |
| 0x3A | `GPU::setupDeviceInfo` | CmdGetDeviceInfo ✓ |
| 0x3B | `Device::createComputePipeline` | CmdGetComputeInfo ✓ |
| 0x3E/0x3F | `Resource::synchronizeAndDiscard` | SyncAndDiscard/DiscardResources ✓ |
| 0x40 | `Device::heapTextureSizeAndAlign` | CmdHeapTextureSizeAndAlign ✓ |
| **0x41** | `Resource::deleteHostSharedTextureBacking`（仅资源类型 0xB/0xC 进入） | **>0x40 → Invalid → fault → 停车** |
| **0x42** | `Device::resetRasterizationRateMap` | **Invalid → 楔死** |
| **0x43** | `CommandQueue::processSegmentKernelCommand`（新 IOGPU 内核命令类型→即 **CmdExecIndirect3** 等价物） | **Invalid → 楔死** |
| **0x44** | `Task::setResourceHeap`（feature byte@task+0x595 **置位时**，否则退回 0x33） | **Invalid → 楔死** |

#### H.1 协商是诚实的——新 opcode 有门控（修正预期）

- `setResourceHeap` 明文二选一：task+0x595 feature byte 置位→0x44，清零→0x33（Ventura 旧命令）。**guest 对 0x44 有显式降级**。
- 客机 Metal 插件的 APVFeatures schema 里 `supportsCmdExecIndirect3` 是协商位 → 0x43 仅在宿主自报支持时发出。
- `deleteHostSharedTextureBacking` 只对资源类型 0xB/0xC 发——这类资源只在宿主协商了共享纹理后才会被创建。
- 序列化版本同样是诚实协商：插件 `initWithDevice:objectRefAllocator:deserializerVersion:` —— **客机按宿主自报的 DeserializerVersion 出料**。
- 宿主 `setBinaryVersion` @ `0x100011efc`：guest 请求值 **clamp 到 ≤43**（`a3>=0x2B→43`），按版本层叠出 feature bitmask 写 device+1220（v40 会清 0xFF0000 位，v42/43 各加位）；`v6<0` → "unsupported binary version" error。

#### H.2 修正后的嫌疑排序（协商诚实 ⇒ 新 opcode 正常不会发出）

1. **宿主 Metal 执行失败**（iPadOS 16.3 AGXMetal 跑不动 Ventura 反序列化器发出的合法内容）→ `addCompletedHandler` 见 `status==5` → fault→park。**与 metalshim 已补 BC 纹理同类——iPadOS16.3 的 Metal 功能缺口可能不止 BC**。不依赖任何协议 skew，最干净解释"多应用随机踩中"。
2. 客机未门控路径/资源生命周期竞态（如资源先删后引用 → Cmd* 校验 fault）。
3. 合法 opid 的 payload 布局漂移（同 binaryVersion 下 Ventura 实现与 15.6 出料对某些字段解释不同）。
4. 新 opcode 误发——仅当某条路径忘了查 feature 位（待证伪）。

#### H.3 已备工具与待办

- 楔死现场 `sample` VMM（无需重启）→ 判 faultAtOffset 停车 vs decodeSegments 挂起；
- diagnostic hook：`faultAtOffset:stampValue:` 记返回地址→定位 fault 源 Cmd；
- 若宿主 Metal 失败坐实 → 沿 metalshim 模式枚举 iPadOS16.3 AGX 缺失能力逐项 shim（或 payload 代际升级根治）。

### I. 楔死现场自动捕获（2026-10-02 重启后部署）

- `VirtualMac/vz/development/probes/gpu-wedge-watch.sh` 常驻（3s 轮询客机 DiagnosticReports）：新 gpuRestart → 自动抓 报告+tailspin+guest `log show`(fault interrupt 5m 窗)+宿主 `stackshot -p`+vmm.stderr tail → `.diag/wedge-watch/`。
- guest 侧 fault 信号：`AppleParavirtGPU::handleFaultInterrupt` @ `0xfffffe0008cdbda0` → IOLog `"handleFaultInterrupt: Received fault interrupt"`（**客机 log show/dmesg 可见**，早于 gpuRestart 报告生成）→ 逐通道 vtbl+0x198 判 faulted → `[x19+0x158](1, [channel+0x18]faultCode)` 上报。channel+0x18 = 每通道 fault code 字段。
- iPad 栈采集现状：无 sample/lldb；`stackshot -p <pid>` 实测可用（kcdata blob）；`task_for_pid` 在 vzxpchook spawn 路径里已证可行（`vzxpchook.m` task_for_pid kr 日志）→ 可做最小 PC-dump 诊断工具（待定，需用户点头才往 iPad 上传二进制）。
- stackshot kcdata 解码器：待写（wedge 证据到了再补；thread name + PC 即可定位 PGFifoThread 停在哪）。
- 序列化特性协商再确认：payload `MTLSerializerFeatures` 8 键（supportsOpenGL/supportsSharedTextures/supportsReflectionSerializationVersion/…）→ 客机 `PGSerializerFeatures` 消费其中 5 键；`DeserializerVersion` 由宿主上报、客机 serializer 按此出料。

### J. Reims vGPU 对照评估（2026-10-02，steelbrain/reims-vgpu，LGPL-3.0，已 clone 至 /tmp/reims-vgpu）

**它是什么**：同一协议（AppleParavirtGPU）宿主侧的**独立 Rust 重实现**——QEMU 设备（x86 PCI / arm64 sysbus MMIO）+ 线格式解码器 + Metal/Vulkan 执行后端。客机同样是 stock macOS + 苹果原生 kext。**我们方案不是"低效版本"**：VirtualMac 用的就是苹果的这套宿主实现本身（Ventura PG.framework+MetalSerializer 拆到 iPadOS），执行路径 = Metal 直连 iPad AGX，比 Reims 的 Vulkan→MoltenVK→Metal 还少一层。Reims 的价值在**规格书与对照**，不在性能。

**协议表逐条核对结果**：`crates/reims-vgpu/src/model/regs.rs` 的 CHILD_COMMANDS 与我们 IDA 解出的 Ventura `processFifo` 分发表**完全一致**——0x37=EXEC_INDIRECT2、`opcode≤0x40` 上限+`>0x40` 非法、deprecated 洞位、0x25=DeleteResource/0x28=DeleteObject 区分等全对。独立来源双向印证，我们的逆向表可信。他们的新知：`0x2d`=Monterey 时代 DeviceInfo、`0x3a`="DEVICE_INFO_TAHOE"（跨代 DeviceInfo 两种形式）、`DefineTask2` 首 word=`(task_id<<1)|is_kernel`、EXEC_INDIRECT2 头 `{task_id, resource_count, cmdbuf_count}`。

**对楔死排查的直接价值**：
- `crates/reims-vgpu-wire/src/ops/` = MetalSerializer 线格式**完整重实现**（render/blit/compute/icb/heap_texture/tile/sampler/texture_view/depth_stencil…20 个解码模块）——正是我们宿主 `decodeSegments` 所解的字节流的可读规格；
- `reims-vgpu-core` 有**串行参考解释器**（serial reference interpreter）+ wire fixtures——楔死现场抓到字节流后可直接过它的解码器，哪条记录拒解 = 嫌犯；
- conformance/ 有 `native-apple-m4-macos15` 基线 + Swift harness（native 跑 Metal 期望值 vs guest 里跑同一套）；
- 风险点：他们也只实现 `≤0x40` 词表（目标客机=Ventura），**0x41–0x44 在 Reims 里同样不存在**——无法借它消化 15.6 客机新 opcode（若真有发出的话）。

**应用到 VirtualMacOniPad 的路径评估**：

| 路径 | 成本 | 价值 | 结论 |
|---|---|---|---|
| A. 当规格书/oracle 用 | 零（已 clone） | 即时——楔死字节流对照解码 | **现在就用** |
| B. `decodeSegments` 前加转译 shim（hook 内预处理序列化流） | 中 | 若根因=Ventura 反序列化器拒解某合法构造 → 精准修 | 取决于楔死证据 |
| C. 换血：VMM 里用 reims 设备模型替 PG.framework | 大（VMM 是闭源 XPC，PG 经私有 SPI 挂载；LGPL 义务；后端仍是同一个 AGXMetal） | 仅当根因=反序列化器且 shim 不可行 | 长线备胎 |
| D. metal2vulkan 路线 | — | iPadOS 无 Vulkan，MoltenVK 仍回落同一 AGXMetal | 排除 |

**下一步（含 Reims 的）**：楔死现场字节流到手 → 用 `reims-vgpu-protocol::fifo` + `reims-vgpu-wire` 解同一段 → 若 Reims 能解而 Ventura 拒/错 = 反序列化器代差实锤；若两者行为一致 = 执行层（iPadOS16.3 AGXMetal）实锤。**这个对照实验比继续纯 IDA 盲逆快得多**。

### K. 能力缺口闭环：宿主 deviceInfo 只写 ≤16 字段（2026-10-02 决定性发现）

**客机实测**（`probes/mtl-caps-dump`，客机侧跑）：

| 属性 | 客机 PV device | 真 M1 macOS15 |
|---|---|---|
| `argumentBuffersSupport` | **0** | 2 |
| `readWriteTextureSupport` | 1 | 2 |
| `supportsDynamicLibraries`/`FunctionPointers*`/`RenderDynamicLibraries` | no | YES |
| `supportsPullModelInterpolation`/`ShaderBarycentricCoordinates` | no | YES |
| `supportsFamily:Metal3` | 不报 | YES |
| `counterSets` | (null) | 有 |
| families | Mac1+Mac2+Common1-3 | +Apple7+Metal3 |

**根因链路（逐字节证据）**：
- 宿主 `writeDeviceInfo` @ `0x100002a04`（PG.framework）：按 `{u32 field_id, u32 value}` 对写，**字段词表止于 16**——1=MSAASamples,2=D24S8,3-5=MaxThreads xyz,6=MaxThreadgroupMem,7=FramebufferRead,8=RGB10A2Gamma,9=HWFP16,**10=DeserializerVersion=0（硬编码）**,11=PrimitiveTypes,12=dualPlane→Multiplane,13=LinearAlign,14-16=Heap 系。
- 客机端字段词表（`AppleParavirtGPUMetalIOGPUFamily` 结构编码，约 40 字段）：17=BufferFromIOSurface,18=MaxMetalShaderVersion,19=SupportsSharedTextures,…,**33=SupportFlags2024**{SupportsArgumentBuffers,CommandBufferJump,SharedMemoryHeap,SIMDReduction,ComputeCompressedTextureWrite…},**37=HostGPUFamily,38=ArgumentBuffersTier,39=ArgumentBuffersMaxSamplerCount**…全部 ≥17 → **宿主永远不会写 → 客机 Defined=0 → 全读 0**。
- `writeDeviceInfo` 的版本门 `a2>=N`：`a2` 来自客机 FIFO 命令载荷自己报的目标版本——客机报得再高，宿主也只写它认识的字段（旧 binary 不会有新代码）。
- 客机 `setupDeviceInfo` @ plugin `0x188a4`：IOConnectCallMethod 取 kext 回复 → 按顶层组 {0x3ee,0x3ef,0x3f0,0x3f1} 解析子字段组。`argumentBuffersSupport` getter @ `0x1b870`→`supportsArgumentBuffers` @ `0x1b838`：ivar+0x31==1 且 ivar+0x80 bit5 才真——两字节都由 deviceInfo 驱动。**注意：客机此 getter 上限=BOOL(1)=tier1**，即便打开也只报 tier1（结构如此）。
- 宿主 binary 里存在 `registerArgumentBufferLayoutForReference:`/`registerArgumentEncoderForReference:` —— Ventura 反序列化器**实现过 argbuf 编码**，缺的只是 deviceInfo 宣告。

**修复方向（新战线，独立于楔死）**：宿主侧 swizzle `getDeviceInfo:length:dst:`/`writeDeviceInfo`（落 vzxpchook/pvg_trace 现有 hook 架构），在回复尾部追加 15.6 认识的字段——`ArgumentBuffersTier`、`SupportFlags2024`（按 iPadOS16.3 AGX 真实能力逐项置位）、`HostGPUFamily`、`MaxMetalShaderVersion`、`SupportsSharedTextures` 等。**前置条件：先 dump iPadOS16.3 MTLDevice 真实能力表**（拔 iPad `/System/Library/PrivateFrameworks/Metal.framework`+AGXMetal13_3 静态取证或经用户批准跑 iPad 探针），**按真实能力上报，不多报**——报多了客机发出宿主执行不了的内容 = 正好落进楔死路径。
- MATLAB 证据（`~/Desktop/Patch/MATLAB`）：CEF 合成残缺被迫 `--disable-gpu`；figure OpenGL 曲线不显示+MSAA 后管线全毁（OpenGLPVGCompat 未覆盖 VBO+shader+MSAA）；Java2D Metal/OpenGL 全关。argbuf=0 + CEF wedge 修复后，Chromium 系（含嘉立创EDA/Devin）预期可去 `--disable-gpu`。
- 遗留核实：客机 15.6 deviceInfo 顶层组 0x3ee-0x3f1 的子字段 id 全表（继续解 `setupDeviceInfo`）；`readWriteTextureSupport`/`supportsFamily:Metal3` 的字段来源。

#### K.1 iPadOS16.3 宿主真实能力表（mtl-caps-dump 实测，`.diag/host-ipados16.3/mtl-caps.txt`）

| 属性 | iPadOS16.3 M1 实测 | 客机 PV 实报 | 差距 |
|---|---|---|---|
| argumentBuffersSupport | **1 (tier1)** | 0 | 宿主有，客机不知 |
| readWriteTextureSupport | **2 (tier2)** | 1 | 被砍半 |
| supportsDynamicLibraries / FunctionPointers(FromRender) / RenderDynamicLibraries | **YES** | no | 全关 |
| **supportsRaytracing(+FromRender)** | **YES** | no | M1 宿主驱动开光追（bundle 有 raytracing_rt.metallib 佐证） |
| supportsPullModelInterpolation / ShaderBarycentricCoordinates | **YES** | no | — |
| supportsFamily | Apple1-7 + Common1-3 + **Metal3** | Mac1/Mac2/Common1-3 | 客机连 Apple family/Metal3 都不报 |
| counterSets | GPU timestamp set | (null) | — |
| maxBufferLength | 3.83GB | 5GB（客机合成值） | 客机值反而更大 |
| recommendedMaxWorkingSetSize | 10.2GB | 6.67GB | — |
| maxArgumentBufferSamplerCount | 1024 | 2048（客机合成值） | — |
| sparseTileSizeInBytes | 16384 | 16384 | 一致 |

**iPad 侧探针操作要点（已验证）**：二进制须放 `/var/jb` 前缀下执行（AMFI/trustcache 范围）；`MTLCreateSystemDefaultDevice` 无 entitlement 返回 nil；需 ldid 签 entitlements：`com.apple.security.iokit-user-client-class`(IOGPUUserClient/AGXDeviceUserClient/AGXSharedUserClient…)+`platform-application`+`get-task-allow`。探针源=`probes/mtl-caps-dump.m`（iOS/macOS 同源，dlsym 弱解 MTLCopyAllDevices）。

**结论**：宿主 AGX = 接近满血 Metal3 M1（含光追）；客机看到的 = 被 Ventura deviceInfo 词表（≤16 字段）阉割后的残血设备。swizzle writeDeviceInfo 追加字段的**每个值都有宿主实测依据**（tier=1 不是 2、RT=YES、dynlibs=YES——按此表上报即诚实）。

#### K.2 deviceInfo 扩展实现（`pvg_trace.m` `TraceGetDeviceInfo` + `vmmhook.m` 映射表）

**注入点**：swizzle `-[_PGDevice getDeviceInfo:length:dst:]`（IDA 确认其 IMP=`sub_100011DF0`，仅存根通道 `0x3a` 命令（`sub_1000203D8`）调用；参数序 = `[key_table_len][count][reply_pfn]`）。流程：调原 IMP → `reply_pfn<<14` 经 vmmhook `hv_vm_map` 记录表换算宿主 VA → `+*(device+0x1F0)` 复现 dst → 走哨兵 → 追加/覆写扩展 key（`<keyLimit` 门控，语义与 Ventura `keyLimit>K` 逐位一致）→ 重写 `{0,0}` 哨兵（`count>capacity` 时末位保留哨兵——Reims `info_reply::encode` 同款语义）。客机在完成 stamp 前阻塞 → 天然无竞态。

**默认表 = Apple 真实宿主抓包值**（Reims `DEVICE_INFO_CAPS`，经 iPadOS16.3 实测表 K.1 复核）：keys 17–41（洞位 20/22/38/39 不发、死位 43 跳过；42/44 仅 macOS26 解析端可达）；**key10 DeserializerVersion 默认仍 0**（Ventura 原值——bump 会解锁客机序列化器 rung≥3/5/6/7/8 的新词表（OpenGL 段 0x8a-0x98 在 ≥6 才发出），能否被 Ventura 反序列化器消化需单独实验）。配置面：`PVG_DEVICEINFO_CAPS=0` 全关；`PVG_DEVICEINFO_EXTRA="k=v;…"` 追加/覆写（如 `10=8`）；App 侧 `defaults write <bundle> PVGDeviceInfoCaps -bool NO` / `PVGDeviceInfoExtra` 免重编。

**Reims 协议层已确认**：macOS15 客机声明 keyLimit=42（解析 key 1..41）；key33 SupportFlags2024 bit5=ArgumentBuffers 是插件 tier 的真正来源（key38/39 无消费者）；key18 是 packed AIR 版本（客机端 ≥0x20008→clamp 0x20007）。

**遗留核实**：首启须在 vmm.stderr 看到 `deviceinfo caps augmented` + pvg-trace `DEVICEINFO` 行确认命中；若 `no-host-map`（pfn 不在 hv_vm_map 域）需走 allocator 复制方案。
