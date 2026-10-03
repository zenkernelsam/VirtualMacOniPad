# VirtualMac 后续研究排队与证据闸门

更新时间：2026-10-03

本文记录 GPU 收尾事项和用户指定的四条新研究线。它是研究排队单，不表示已经安装、打包或在 iPad 上执行了任何新功能。所有实验遵守 `AGENTS.md` 的 iPad 只读取证、禁止运行中 VMM 注入和避免 panic 规则。

## 当前状态与范围

当前 iPad 实际安装仍以最近一次只读核对为准：88（`2:1.2.3+88.bb005a7dfe.gpuvulkan`）。91 GPUJIT 包和 90 GPUReady 候选虽已构建并存入本机/飞牛目录，但都没有因此获得设备运行证据。用户要求暂缓升级，故本轮不安装、不重启、不做压力测试。

GPU 的结论必须区分四类证据：声明（capability/deviceInfo）、执行（命令提交和资源读回）、性能/稳定性（长时负载、wakeups、recovery、温度）以及应用侧状态。已有 ANGLE/WebGL/WebGPU、Godot 和 OpenGL 读回不能替代长期稳定性或 MATLAB/复杂 WebView 验收。

## GPU 尚未收尾

| 项目 | 已知证据 | 收尾闸门 |
|---|---|---|
| 88/90/91 新包首启 | 88 曾出现 `guest menu extra not acknowledged; repair attempt`；90/91 尚未在设备首启验证 | 用户允许升级后先独立保存新启动日志；确认 `guest menu extra acknowledged token`、repair 不再增长、VMM wakeups 与 GPU recoveryCount；旧 86/88 证据不能复用 |
| 卡死根因 | 重启与满载卡死只有时间关系；没有卡死前采样/宿主报告 | 先拉新宿主 stderr、wakeups/Jetsam/ReportCrash 和 guest 诊断，再判断是 GuestTools 放大、VMM、GPU、macPad 或其他因素；不得预先归因 |
| MATLAB CEF/JIT | `pthread_jit_write_protect_supported_np=0`，`MAP_JIT` 专用 probe 可执行返回 42；未补丁 CEF A/B 没有 GUI/CEF ready/屏幕像素证据 | 在隔离配置下完成 native 与 JIT compat 的 CEF 子进程、GUI ready、窗口像素和崩溃日志 A/B；在此之前保留 MATLAB_VM_Fix，不把 getter 伪造当 GPU 修复 |
| MATLAB figure present/context | NSOpenGLView 窗口基线 142 帧通过；MATLAB 特有失败仍未定位 | 取得 MATLAB 实际 drawable/present、上下文复用和连续屏幕读回证据后，才考虑最小进程范围修复 |
| Qoder 软件渲染文案 | 正式 CDP 报 `ANGLE_METAL`、`Apple Paravirtual device`、`gpu_compositing=enabled`、WebGL/WebGPU enabled、pixel readback 成功 | 取得用户看到的原文提示、对应进程的 featureStatus/启动参数和像素证据；在来源未定位前不改 Qoder bundle/config，也不把文案归因 VirtualMac |
| 性能与能力表 | 现有能力查询不等于性能；Tier2/协议 207、Apple9/4095 仍未验证 | 只在受控对照下测帧率、wakeups、recovery 和功耗；不强改 getter、serializer、协议或恢复全开能力 |

## 1. USB 直通：先拆分数据面与电源面

### 已确认事实

- `docs/PERIPHERAL-PASSTHROUGH-AUDIT.md` 的运行期表显示没有 USB 外设；客机 `AppleVirtIOUSBDeviceController` 类存在但实例为 0，VM 配置也没有 USB 设备键。
- 当前唯一 USB 通路是安装/Restore 桥 `/tmp/vz-usb-restore.sock`。桥协议包含 `GET_STATE/CONTROL/BULK/RESET/CREATE_ENDPOINT`，服务 RestoreOS 刷机，不是运行期任意外设直通。
- Ventura Virtualization payload 已包含 `VZUSBMassStorageDeviceConfiguration`、`VZUSBKeyboardConfiguration`、`_VZUSBDevice`、`_attachUSBDevice:error:` 等符号；这证明框架内有 USB 设备模型，不证明 iPadOS 16.3 能安全绑定实体 Type-C host controller。
- VMM entitlement 含 `com.apple.usb.hostcontrollerinterface`，但 iPadOS 对应 user-client、端口 ownership 和沙箱/AMFI 可达性仍未证实。
- Instance1（13337）内核字符串已见 `AppleEmbeddedUSBHost`、`AppleSynopsysUSB40XHCI`、`IOUSBHostFamily`、`AppleUSBHostPort`、`AppleTypeCPhy`、Thunderbolt USB 上下行适配器，以及 `ChargingCurrent`、`Requested Charging Capability`、`AppleUSBCableType`、`IsCharging` 等电源面符号。这支持“数据传输与充电控制可分层研究”，不是复用 host controller 的许可。

### Instance1 首轮反编译证据（2026-10-03）

证据原文保存在 `.diag/ida-13337-usb-evidence-20261003/results.json`，IDB health 为 `kc_raw_16.3_T8112.bin`、Hex-Rays ready。关键结果：

- `AppleUSBPhy::start @ 0xfffffe0008f2a240` 初始化多个 client array，读取 `phy-id`，按该值匹配 `AppleEmbeddedUSBArbitrator`，随后调用其注册入口；找不到 arbitrator 时记录 `unable to locate AppleEmbeddedUSBArbitrator service` 并失败返回。这是明确的 PHY ownership/arbitration 层。
- `AppleUSBPhy::enableHostMode(bool) @ 0xfffffe0008f2c354` 反编译为 4 字节空函数。当前 kernel 没有可直接调用的 host-mode 实现可供用户态桥复用；不能据此假设 guest 能接管 XHCI。
- `AppleEmbeddedUSBArbitrator::registerPhy @ 0xfffffe0008f2d6ec` 会读取 `publish-criteria`，维护 `gAppleARMUSBCableTypeDetached`，注册 USB cable change interrupt，并向 `IOPMrootDomain` 注册 power-state interest。USB 枚举与电源/系统电源通知在同一 arbitration 对象内协调。
- `getCableType @ 0xfffffe0008f2f8a0` 从 `AppleARMUSBCableType` 资源读取当前 cable type；`handleUSBCableTypeChange @ 0xfffffe0008f2f934` 在 cable type 变化时调用内部策略并更新状态。`enableUSBIsolationCells @ 0xfffffe0008f3049c` 当前只返回错误码，不能被当作可用的隔离开关。

这组证据把 USB 方向进一步收窄为“保留 AppleEmbeddedUSBArbitrator 的 ownership、电源和 cable 状态，另建用户态数据传输桥”。

### Instance1 深入反编译结论（2026-10-03）

证据保存在 `.diag/ida-13337-usb-deep-20261003/`。`AppleCS46L21Dock9Pin::_handleUSBHostPortAddedGated @ 0xfffffe0008ef1af0` 只向 `AppleUSBHostPort` 注册 `gIOGeneralInterest` 通知；`setUsbDeviceStack @ 0xfffffe0008ef3698` 根据 `IOAccessoryManager::getUSBConnectType` 与 `kBehaviorUSBCharger` 分别设置 GPIO7（CDP）和 GPIO4（USBDevMode），说明充电/数据角色由 dock/accessory manager 分离。`AppleUSBHostPort::handleOpen @ 0xfffffe000a3b8718` 只接受自身或 `IOUSBHostDevice`，没有用户态 host takeover。源码 `VirtualMac/vz/patches/patch_vmm_optional_devices.py` 明确记录 iPadOS 缺 `AppleUSBUserHCI`/`AppleUSBUserHCIResources`，`IOUSBHostControllerInterface` 创建返回 nil。

因此“原生 VZ host-controller 绑定”当前静态证据倾向不可行；它还没有证明任意实体 USB descriptor/transfer 已可从 iPadOS 用户态安全获取，不进入物理设备写操作。后续只研究现有 fake HCI 后的低延迟批量/共享内存桥，充电、电流、温度和 Type-C role 留在 iPad。

### 研究顺序

1. 只读反编译 Instance1 的 `AppleUSBPhy::start/enableHostMode`、`AppleUSBHostPort` ownership 路径、`AppleCS46L21Dock` host-port added 路径和 `AppleARMFunctionChargerMux::setUSBInputCurrentLimit`，记录 host/device mode、power role、current limit 的调用关系。
2. 只读枚举 iPad IORegistry/IOKit Type-C、USB host、充电节点，保存插拔前后 descriptor/registry 差异；不写 power role/current limit，不重启系统服务。
3. 复核 Instance4（13340）时只把当前 PG IDB 当作 GPU 参考；Virtualization USB 私有类的宿主实现需从 payload/符号证据单独建立，不能把 PG 反编译当 USB 证据。
4. 若 host 侧可达，优先设计用户态 descriptor/transfer bridge：客机只获得设备数据端点，iPad 保留充电、电流、温度和 Type-C role 管理。先做单一低风险设备类别（例如 HID 或 mass-storage descriptor），再考虑 hub/Thunderbolt。

### 决策闸门

只有同时证明端口 ownership 可恢复、充电控制不会交给 guest、拔插/错误可回收、以及 VMM 不需要内核注入，才进入小型 bridge 原型。任何需要把整个物理 XHCI/Type-C 控制器交给 guest、改电源 role 或 hook 运行中 VMM 的方案暂停并重新向用户确认。

## 2. Nested Virtualization

### 当前边界

`VirtualMac/vz/host/hypervisor14_compat.c` 是把 macOS 11 Hypervisor 导出转发给 Ventura VMM 的兼容层；当前源码只出现 `hv_vm_create/map/unmap`、`hv_vcpu_create/run`、寄存器访问、`hv_vcpus_exit` 和固定 36-bit IPA 兼容 API。没有已确认的二级 VMX/EL2、nested capability 或 guest hypervisor exposure 代码。

### 只读研究步骤

1. 审计 `hypervisor14_compat.c`、`vmmhook.m` 和 payload 的 Hypervisor 私有符号，区分“guest 能调用 Hypervisor.framework API”与“硬件允许 guest 再开一层虚拟机”。
2. 在 Instance1 内核中搜索 nested/EL2/virtualization capability 及 vCPU trap policy；只保存反编译和字符串证据。
3. 从当前 guest 的只读 CPU/Hypervisor 可见性查询判断是否暴露虚拟化特性；不运行嵌套 VM、不改 vCPU 寄存器、不改变 trap 配置。

### Instance1 首轮字符串证据（2026-10-03）

13337 kernel 搜索结果保存在 `.diag/ida-13337-nested-evidence-20261003/find-regex.json`，深入报告在 `.diag/ida-13337-nested-deep-20261003/REPORT.md`。`VM-create @ 0x80b0450` 检查 `IOTaskHasEntitlement(..., "com.apple.private.hypervisor")`，无授权上限为 0，有授权上限为 3，并把唯一 HV state 绑定到 `current_task`；`vCPU-create @ 0x80b2010` 读取 `ICH_VTR_EL2`、`ACTLR_EL12` 建立 EL2→guest EL1 上下文，但没有 `HCR_EL2/VTTBR_EL2/VNCR_EL2` 的第二层管理。精确搜索 FEAT_NV、HCR_EL2、VTTBR_EL2、VNCR_EL2、nested virtualization 均为 0 命中。`pmap_set_nested_internal`/stage2 字符串只是 pmap 子区域诊断，不能当作 nested hypervisor 证据。

结论收窄为“当前原生硬件 nested 证据倾向不可行”。项目 `hypervisor14_compat.c`/`vmmhook.m` 也只有单层 hv_vm/hv_vcpu 转发；iPadOS14 的 HCR_EL2 TIDCP/TSC 修补是 guest EL1 兼容，不是第二层虚拟化。后续只做 guest 只读 `kern.hv_vmm_present`、Hypervisor API 返回码和 CPU ID 查询；不启动第二 VM、不改 vCPU 寄存器。软件/半虚拟化 container service 可以另行研究，但不能宣称 nested VM。

### 预期结论形式

若只有单层 host Hypervisor API，结论应写成“可研究容器/用户态模拟器，未证明硬件 nested virtualization”；只有找到明确二级 stage-2/EL2 支持和安全 guest exposure，才进入 Linux KVM/Hypervisor 实测设计。

## 3. 音频开关与发热

### 已有证据

`VirtualMacApp.m` 的 `configureAudio` 逐字分支为：`VZDisableAudio` 直接返回；否则按 `AudioOutputEnabled` 和 `AudioInputEnabled` 分别建立 `VZHostAudioOutputStreamSink`/`VZHostAudioInputStreamSource` 与 virtio-sound stream。日志已出现过 `audio disabled by VM configuration`、`configured virtio audio output=1 ... input=0` 和 input/output 都关闭的启动。

当前证据只说明配置可独立切换。已有 wakeups/Jetsam 报告与某次启动时间相关，不能证明“关闭音频一定降温”，也没有匹配的温度/功耗序列。

### 待用户可停机后的 A/B

固定 guest、CPU/内存、画面和工作负载，分别测：输入+输出、仅输出、仅输入、全关。每组记录相同时间窗的 iPad thermal state/温度可用字段、VMM CPU、wakeups、Jetsam、GPU recoveryCount 和 guest 音频日志；每组至少重复两次并保存原始文件。先做短时低风险观察，不改宿主电源策略。

### 修复候选

若仅音频 stream 造成可重复的 CPU/wakeups 增量，优先做 UI/配置层默认关闭或按需启用，并保留独立输入/输出开关；不要在没有对照数据时删除 virtio audio、改 CoreAudio 权限或声称已解决发热。

## 4. iPad 键盘的 ESC/F1–F12

### 已有实现

`VirtualMacApp.m` 的 `macVirtualKeyCode` 已映射 HID `0x29` 为 Escape、`0x3a–0x45` 为 F1–F12，事件通过 `_VZKeyEvent initWithType:keyCode:` 发送。触控输入 accessory 也已经列出 `esc`、导航键、`F1`–`F12`，使用横向可滚动 `UIStackView`。

但当前实现有一个已定位的可达性缺口：`VZHUDView.refreshMenu` 在 `GCKeyboard.coalescedKeyboard != nil` 时隐藏键盘按钮；`VZInputView.inputAccessoryView` 在同一条件下返回 `nil`。也就是说，官方键盘接入时，恰好最需要的 ESC/F-row accessory 不可见，底层 keycode 映射虽然存在，用户仍无法触达。

### 最小改进方案

先把 HUD 键盘按钮从“无实体键盘才显示”的条件中分离出来：实体键盘存在时，按钮仍可打开一个不依赖系统 input accessory 的 function-row 面板；面板复用现有 `sendSoftwareKey`/`_VZKeyEvent`，不抢普通文本输入焦点。再审计横向滚动可达性、焦点/按住语义和 guest 端 key event 日志；保持现有 HID 映射不变。可选布局是把 ESC、F-row、Delete、Home/End 分成可展开的 function row。组合键（例如 Globe/Command+数字）只能作为可选快捷方式，不能替代可视按钮。

### 已实现的第一版 UI（待设备验收）

当前源码已加入独立 `VZFunctionRowView`：默认隐藏；固定在底部安全区上方 16pt；宽度约安全区 82%、最大 760pt、最小 280pt；深色半透明背景、细边框、横向滚动，包含 ESC 与 F1–F12。硬件键盘存在时 HUD 键盘按钮保持可见，点击只展开/收起该面板，不弹出系统软件键盘；VM/HUD 隐藏或键盘断开时自动收起。arm64 iPad App 语法编译通过（仅有既有 `UIWindow.screen` deprecated warning）。尚未打包、安装或在 iPad 实景验收。

验收需逐键保存 host key log 与 guest 可见结果，覆盖按下/释放、修饰键组合、横向滚动和实体键盘并存；不因 UI 便利性修改 USB 或虚拟键盘协议。

## 排队顺序

1. GPU：用户允许升级后完成独立首启、卡死取证和 Qoder 文案来源核对；在此之前保持 88。
2. USB：先完成 Instance1 内核 ownership/power-role 反编译和只读 IORegistry 证据，形成 bridge 可行性报告。
3. Nested：静态确认 capability 边界，不运行嵌套 VM。
4. Audio：停机后做四组短时 matched A/B，再决定是否做配置层优化。
5. Keyboard：在不改底层映射的前提下施工可展开 function row，并做逐键回归。

本文件只记录研究方向和闸门；任何新增包必须对应真实新增功能和独立验收证据，不能只换版本号重打包。
