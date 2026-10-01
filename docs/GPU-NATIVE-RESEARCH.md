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

### F. 具体根因假设（证据链已收紧）

`supportsCmdExecIndirect3` 存在 ⇒ 协议存在 `CmdExecIndirect3`；宿主 32 条 Cmd 词表只有 `CmdExecIndirect2`。**假设**：客机在某些提交（可能正是带 barrier/indirect 的路径）发出 CmdExecIndirect3（或任一 opcode>宿主表），Ventura PGFIFO 打 `Invalid FIFO command ... opid=%u on channel %u` 后停止消费该 FIFO → guest 见 `submitEvent:INCOMPLETE` 永不 retire → IOGPUScheduler restart → channel→global reset 风暴。**完美解释"仅 Exec 通道积压、Object/Memory 排空"的通道排水图**。
- 验证：SSH 恢复后 `grep -iE "opid|invalid fifo|unsupported.*binary" /tmp/vmm.stderr.log`；若中，反编译确认该命令的 binary-version 门控，然后选修法（宿主侧假完成 / 客机侧降级到 ExecIndirect2 / 对齐 payload 代际）。
