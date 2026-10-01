# SOURCE-AUDIT-REPORT — vz/ 全源码静态审计（subagent 全量产出，2026-10-01/02 夜）

> 来源：盘点 subagent（agent_id=9e85a372，~5h 全量阅读 `vz/` 下 host/guest/shims/tweak/install + patches/scripts/packaging）。主会话已抽验关键行号，与 §2.4 hook 盘点互相印证一致。全部结论可在仓库源码直接复核。

## 0. 审计范围与方法

- **审计对象**：`/Users/ciscohe/Desktop/VirtualMacOniPad`，重点为 `VirtualMac/vz/` 下全部 `.m`、`.c`、`.h` 文件，覆盖 `host/`、`guest/`、`shims/`、`tweak/`、`install/` 五个子目录，另含 `vz/patches/`（二进制补丁脚本）、`scripts/`（构建/审计脚本）、`packaging/`（launchd plist）。
- **方法**：**只读静态审计**。全部结论均可在仓库源码中直接复核，引用格式为 `文件路径:行号`。未做任何构建、运行、动态插桩或二进制验证。
- **重要声明**：entitlement XML 文件是**签名输入的期望值**，不代表已构建产物中实际嵌入的 entitlement；`scripts/audit-entitlements.py` 的存在只证明项目设计了比对机制，不证明部署产物通过审计。

## 1. 总体架构

该项目将 macOS 13.2.1 (22D68) 的 `Virtualization.framework`、Hypervisor、PVG 等私有框架**从 dyld 缓存抽取、重打桩为 iOS 平台 Mach-O**，在越狱 iPadOS 上重建"App → VZ XPC → VMM 进程 → Hypervisor/AVP"的完整链路。核心思路：

1. **App 进程**（`VirtualMacApp`，bundle id `com.mac.virtual`）组装 `VZVirtualMachineConfiguration`；
2. **主机侧 hook 层**（`vzxpchook.m`）拦截 `xpc_connection_create`，把桌面版 XPC 服务域语义翻译为 iPadOS 可用的 Mach 服务；
3. **VMM 助手进程**（`vmmhook.m` 注入）以 launchd Mach 服务 `org.jb.vmmservice` 监听，内部用 dyld interpose 替换 `xpc_main`，并承载 fake USB HCI、Hypervisor 兼容层、GuestPolicy 运行时补丁；
4. **Installation 助手**走 `com.apple.Virtualization.Installation` 逻辑名，`installation_usb_shim.m` 在伪造 IOKit 对象与原生 IOUSBLib/MobileDevice 之间架桥；
5. **guest 侧**通过 virtio-socket 上的 QGA 风格 JSON 协议部署 Guest Tools 与 `OpenGLPVGCompat.dylib`，用 `launchctl setenv DYLD_INSERT_LIBRARIES` 注入。

## 2. Hook 点清单

### 2.1 VMM 进程内（`VirtualMac/vz/host/vmmhook.m`，共 3422 行）

| 行号 | 机制 | 目标 | 效果 | 条件 |
|---|---|---|---|---|
| 3261–3263 | `__DATA,__interpose` | `hv_vcpu_create` | 建 vCPU 后按 XNU20 `arm_guest_rw_context` 布局改 `context+0x668` 处 `HCR_EL2`（清 TIDCP、置 TSC），`+0x700` 置 state_dirty（3227–3258，偏移来自 UTM Hypervisor 的 KDK 结构） | 常量启用 |
| 3283–3285 | interpose | `hv_vcpu_set_reg` | vCPU0 `HV_REG_PC` 置低位地址时判定 guest 重启，`guest_policy_rearm_after_reboot`（3270–3281） | `guest_runtime_policy_enabled` |
| 3360–3362 | interpose | `hv_vcpu_run` | 首次运行抓 PC/TTBR1_EL1/TCR_EL1 启动 GuestPolicy worker（3287–3311）；vCPU exit 计数/原因分桶/定时器寄存器采样（3312–3357） | 常量启用；深 trace 由 `VMMHOOK_TRACE_VCPU` 控制 |
| 3381–3384 | interpose | `hv_vcpu_set_vtimer_mask` | 计时器 mask 诊断日志 | debug logging |
| 3403–3406 | interpose | `hv_vcpu_set_vtimer_offset` | 同上 | debug logging |
| 3420–3421 | interpose | `hv_vcpus_exit` | 批量退出诊断 | debug logging |
| 2421–2469 | ObjC 方法替换 | `IOUSBHostControllerInterface` 的 `enqueueInterrupt:` 系 4 个方法 | fake HCI 对象的中断入队被路由进 `fake_usb_host_process_interrupt`（2220–2396） | `VMMHOOK_FAKE_USB` 环境变量（1333–1336）+ 关联对象标记 `is_fake_usb_hci`（1343–1345） |
| 2471–2477 | ObjC 方法替换 | 同类 `destroy` | fake 对象跳过真销毁 | 同上 |
| 2491–2627 | ObjC 方法替换 | `initWithCapabilities:queue:interruptRateHz:…` | 构造**纯用户态假 HCI**：拷贝 capabilities、设置 `IOUSBHostCIControllerStateMachine`、保存 command/doorbell block，100ms 后发 `ControllerPowerOn`(0x10) 启动枚举状态机 | `VMMHOOK_FAKE_USB` |
| 2603–2617 | ptrauth_strip + vtable 读取 | command_handler block `+0x20` 的后端 controller 虚表 | 打 backend vtable 前 8 项地址用于诊断 | 同上 |
| （构造器） | `__attribute__((constructor))` | 全模块 | 注册 XPC/Mach 监听、IOSurface/XPC interpose、可选 `hv_vm_map` 跟踪 | — |

### 2.2 主机 App 进程内

| 文件：行号 | 机制 | 目标 | 效果 |
|---|---|---|---|
| `vzxpchook.m` | `__DATA,__interpose` + 显式 GOT 重绑 | `xpc_connection_create` | 识别 `com.apple.Virtualization.VirtualMachine` / `com.apple.Virtualization.Installation` 逻辑名，spawn/连接助手进程，经 `/tmp/vmm_ep.txt` 交换 endpoint，**重写 endpoint 内 `+0x18` 处 Mach send-right** 完成端口替换 |
| `vzxpchook.m` | interpose/导出 | sandbox-extension 弱符号、`sysctl` | 补 iPadOS 缺失符号；sysctl 覆写使移植框架认为环境合法 |
| `VirtualMacApp.m:4418,4558–4566` | `dlsym` + rebind + `installFramebufferTrace` | hook dylib 导出 `vz_host_vm_started` | `setFramebuffer:` 后安装 `process_frame_update` 处理器；start 成功后回调 `gHostVMStarted()`（5307） |
| `VirtualMacApp.m:449` | `class_replaceMethod` | shapeEffects 类对象方法 | UI 层兼容替换 |
| `metalshim.m` | ObjC 方法替换 + 构造器安装 | `MTLDevice` 等缺失方法 | 补 iPad Metal 缺失 API、managed→shared storage 归一、设备能力查询、BC 纹理创建/视图/上传/替换 |
| `native_bc_texture_support.m` | `MSHookFunction`（dlopen `libellekit.dylib`/`libhooker.dylib` 发现） | AGXMetal 纹理格式选择器 | ABI 指纹校验+地址范围验证后向 AGX 格式表注入 BC 描述符 |
| `pvg_trace.m` | ObjC 方法替换 + 构造器 + 定长指令补丁 | `_PGDevice` 等 PVG 类 | task 创建/display/pipeline cache/blit/reporting 追踪；metallib 回退；按 22D68 精确 call-site 打补丁 |
| `shims/pvg_metallib_shim.m` | 构造器 + 精确偏移补丁 | PVG `default.metallib` 加载点 | 预置 metallib，修补编译/查找失败路径 |
| `installation_usb_shim.m` | dyld interpose（IOKit/电源符号）+ Unix socket 客户端 | `IOUServiceRequest`/`IOConnectCall*` 等 | 伪造 IOKit registry 对象，把控制/批量传输经 `usb_bridge_request`（172–186, `socket(AF_UNIX,SOCK_STREAM)` → `VZ_USB_BRIDGE_SOCKET`）发回 VMM |
| `installation_usb_shim.m` | `dlopen`/`dlsym` | 原生 `IOUSBLib`、`MobileDevice` | 恢复流程交由系统原生栈处理 |
| `tweak/VZKeyboardPassthrough.m` | 构造器 + ObjC 方法替换 | SpringBoard/UIKit | 拦截 `SpringBoard keyCommands`、`handleKeyHIDEvent:`、`SBSystemGestureManager`/`SBFluidSwitcherGestureManager` 手势、`UIApplication _handleKeyUIEvent:`，转发快捷键并仅在 VM 前台时抑制系统手势；由 `com.mac.virtual.settings-changed` Darwin 通知驱动，哨兵 `/tmp/virtual-mac-vm-active`、`/tmp/virtual-mac-open-after-respring`，配置 `/var/mobile/Media/VirtualMac/Settings.plist` |
| `guest/OpenGLPVGCompat.m` | ObjC 运行时替换 + dyld interpose | `AppleParavirtDevice`、Metal、IOKit registry 属性函数 | 启用 Apple7 GLD profile、重写 command queue/render encoder、归一样本位置、注入 `AppleMetalOpenGLRenderer` 属性 |

### 2.3 二进制补丁（`vz/patches/`，均为**版本钉死**的离线补丁）

| 脚本 | 目标 | 关键偏移/替换 |
|---|---|---|
| `patch_internet_sharing.py` | Ventura 13.2.1 `InternetSharing` | `0x1CC54` logging 初始化→`mov w0,#1;ret`；`0x18470`/`0x1BCCC`/`0x19A0C` bootpd/rtadvd/natpmpd 存在性检查→`b success`；`com.apple.bootpd`→`vzi.apple.bootpd`（等长）；`/etc/bootpd.plist`→`/tmp/bootpd.plist`、`/etc/com.apple.mis.rtadvd.conf`→`/tmp/…` |
| `patch_ipados14_internet_sharing.py` | iPadOS14 `InternetSharing` | `0xC7C4` SIOCSIFMTU 失败分支→NOP；`0x2C154` NATPMP 默认→0；同标签/路径替换 |
| `patch_ipados14_bootpd.py` | iPadOS14 `bootpd` | `/Library/Preferences/SystemConfiguration/bootpd.plist\0`→`/tmp/bootpd.plist\0`（原地缩短 cstring 保偏移） |
| `patch_vmm_trusthash.sh` | VMM | PVG registry 查找 + PAC 行为定偏移修补，重签 VMM entitlements |
| `patch_pvg_exception_log.py` / `patch_vmm_optional_pvg_reset.py` / `patch_ipados14_vmm_videotoolbox_import.py` | PVG/VMM | 禁用崩溃性异常日志；守卫可选 PVG reset-retain 列表；VT 导入兼容 |
| `patch_virt_ios.py` / `patch_ipados15_objc_imports.py` / `patch_ipados15_objc_class_data.py` | Virtualization.framework | confstr/沙盒扩展/设备迭代器定偏移修补；`objc_retain_x0`/`objc_release_x0` 重定向；Ventura class-data fixup → iPadOS15 ABI |
| `uncache.py` / `stamp_ios.py` / `add_macho_dylib.py` / `patch_macho_cstring.py` / `patch_netrb_lookup.py` / `patch_network_helper.py` | 缓存镜像/助手 | 重建 chained fixups；改 Mach-O platform=iOS 并 ad-hoc 签；插 LC_LOAD_DYLIB；cstring 原地替换；NETRB bootstrap 命名空间改写；bootpd 配置路径/syslog 符号 |

## 3. VM 设备装配（`VirtualMacApp.m`）

| 类别 | 类/参数 | 附着关系 |
|---|---|---|
| 平台 | `VZMacPlatformConfiguration`：auxiliary storage、hardware model、machine identifier（均从 bundle 载入） | 设到 `VZVirtualMachineConfiguration.platform` |
| CPU/内存 | `cpuCount`≥2 且≤host active CPUs；`memorySize`≥2GiB 且≤host 派生上限 | 配置直属字段 |
| BootLoader | `VZMacOSBootLoader` | `bootLoader` |
| 显示 | `VZMacGraphicsDeviceConfiguration`（+displays）；帧缓冲经 `prepareFramebuffer`（5017）/`installFramebufferTrace`（4418）与 hook dylib `vz_host_vm_started`（4558）对接；`setFramebuffer:` 安装 `process_frame_update` | `graphicsDevices` |
| 存储 | `Disk.img` + `VZDiskImageStorageDeviceAttachment` + `VZVirtioBlockDeviceConfiguration` | `storageDevices` |
| 键盘 | `_VZMacKeyboardConfiguration`（优先）或 `VZUSBKeyboardConfiguration` | `keyboards` |
| 指针 | `VZMacTrackpadConfiguration` 或 `VZUSBScreenCoordinatePointingDeviceConfiguration`；滚动由 `VZTrackpadScrollBridge.m`（逆自 MultitouchHID 22D68 的加速曲线/动量模型）供给 | `pointingDevices` |
| 音频 | `VZVirtioSoundDeviceConfiguration` 系 + AVAudioSession + 麦克风 TCC（Info.plist `NSMicrophoneUsageDescription`） | `audioDevices` |
| 视频加速 | `VZVideoToolboxDeviceConfiguration`（AVP VideoToolbox entitlement 支撑） | `videoDevices`/图形 |
| 网络 | `VZNATNetworkDeviceAttachment`（默认，经移植 `InternetSharing`+私有 `vzi.apple.bootpd` DHCP）或 `VZBridgedNetworkDeviceAttachment`；`VZVirtioNetworkDeviceConfiguration`；MAC 持久化/生成 | `networkDevices` |
| 目录共享 | `VZSharedDirectory`+`VZMultipleDirectoryShare`+`VZVirtioFileSystemDeviceConfiguration` | `directorySharingDevices` |
| socket 设备 | Guest Tools 启用→`VZVirtioSocketDeviceConfiguration`；Pencil 独占另一个 vsock（仅当 guest tools 未占用）；`EXPERIMENT_GDB_DEBUG` 下另有调试设备 | `socketDevices` |

运行时：`alloc/initWithConfiguration:`（5263–5265）→ `VZGuestToolsAttachToVirtualMachine`（5267–5269，含 removal-pending 分支）→ `start` 完成后 `VZGuestToolsStartProvisioning`（5303–5306）+ `gHostVMStarted()`（5307）。Restore 模式会清空 guest runtime policy 环境，避免常规启动策略污染 RestoreOS。

## 4. USB Restore 完整链路

**总线侧（VMM 内，`vmmhook.m`）**：`VMMHOOK_FAKE_USB` 使 `traced_usb_hci_init`（2491）返回假 `IOUSBHostControllerInterface`，枚举状态机按命令码推进：

```
0x10 PowerOn → 0x12 ControllerStart → 0x18 PortPowerOn → 0x1e PortStatus
→ (connected) 0x1c PortReset → 0x20 DeviceCreate(→address) → 0x28 EndpointCreate(EP0)
→ 0x2e SetNextTransfer → ring doorbell → 0x3d 传输完成
```
- 首个控制传输 ring 复刻 IOUSBHost.framework 1.2/Ventura：control `0x8038/0x8039/0x803a` + 终止 `0x403c`（1406–1426），请求 18 字节设备描述符；
- 描述符 `idProduct==0x12ac`（VID `0x05ac`）→ `fake_usb_bridge_prepare_restoreos(generation)`（2381–2383）；recovery 人格描述符 PID `0x1281`；
- 端口事件 type `0x08` 处理 iBoot `go` 引发的断连/重连，`fake_usb_bridge_drop_personality` + 重新枚举 + 新 generation 发布给 IOUSBLib façade（2237–2249）；
- 描述符 Stall（status `0xb`）最多重试 15 次，间隔 1s（2384–2393）；
- EP 描述符复制进 `fake_usb_bridge_endpoint_descriptors[256][7]` 常驻，注释明确指出 AVP 每次传输都回读 `wMaxPacketSize`，栈上缓冲会成为 `com.apple.virtualization.usb.hci` 上的延迟 UAF（1283–1289）。

**桥接层**：VMM 作 server 监听 Unix stream socket `/tmp/vz-usb-restore.sock`（magic `0x565a5553`"VZUS"，协议 v2，单请求载荷上限 64MiB），操作含：状态查询、控制传输、批量传输、复位/重枚举、端点创建。请求-响应用 `dispatch_semaphore` 30s 超时（1466–1473），按 command/endpoint 分锁（1269–1297）。

**安装器侧（`installation_usb_shim.m`）**：`usb_bridge_request`（172–186）`connect` 到该 socket；其上伪造 `IOUService`/connection 句柄，把 MobileDevice 的 IOUSBLib 调用翻译成桥协议（224–346、420–428、1239–1541 各请求构造点）。

**主机协议栈**：原生 `IOUSBLib`+`MobileDevice` → 随包 `usbmuxd`（经 `/tmp/vzusbmuxd` 协调）→ 系统 `/var/run/usbmuxd` → RestoreOS 的 USBMux/restore 协议。

**端到端路径**：
```
RestoreOS(AVP guest USB) ⇄ VMM fake HCI（vmmhook.m）
   ⇄ /tmp/vz-usb-restore.sock（SOCK_STREAM, vz_usb_bridge 协议）
   ⇄ installation_usb_shim.m（伪造 IOKit + usb_bridge_request 客户端）
   ⇄ 原生 IOUSBLib / MobileDevice
   ⇄ bundled usbmuxd（/tmp/vzusbmuxd）
   ⇄ /var/run/usbmuxd ⇄ RestoreOS USBMux
```

## 5. GPU / PVG / Metal / BC / metallib

| 层 | 文件 | 方法 |
|---|---|---|
| Metal API 补齐 | `host/metalshim.m` | 构造器安装的 ObjC 方法替换：补缺失 MTLDevice 方法、storage mode 归一（managed→shared）、能力查询、BC 纹理 create/view/upload/replace；`MSHookFunction` 探测 |
| 原生 BC 注入 | `host/native_bc_texture_support.m` | 扫描已加载 AGXMetal 镜像→ABI 指纹+地址校验→`MSHookFunction`（ellekit/hooker）→格式表注入 |
| PVG 追踪/修补 | `host/pvg_trace.m` | `_PGDevice` 等类方法 hook、按 22D68 精确 call-site 指令补丁、metallib 回退，构造器初始化 |
| metallib 预载 | `shims/pvg_metallib_shim.m` | 构造器预载 `default.metallib` + 精确偏移补丁 |
| guest OpenGL | `guest/OpenGLPVGCompat.m` | `AppleParavirtDevice` 识别、Metal 方法替换、Apple7 GLD、encoder 重写、registry 属性 interpose |
| guest 策略 | `host/VZGuestRuntimePolicy.m`（`EXPERIMENT_GDB_DEBUG`） | GDB stub `:12345` + guest 内核页表遍历；`vmmhook.m` 的 `hv_vm_map` 映射跟踪、`guest_policy_find_csr_virtual` 把 guest CSR 限位反复钉为 `0x6f`（895–921，1500×20ms 窗口），`EXPERIMENT_VENTURA_OPENGL` 下还有 `-arm64e_preview_abi` tunable 定位器（551–563，**注释自述该渲染路径半成品、生产未启用**） |
| guest 门禁 | `VZGuestTools.m:516–522` | OpenGL 仅 guest macOS≥14(Sonoma) 开启 |

## 6. Entitlement 与能力差距

| 组件 | 文件 | 关键私有能力 |
|---|---|---|
| App | `host/VirtualMac.entitlements` | `security.virtualization`+`private.virtualization`、`virtualization.avp.videotoolbox`、`vm.networking`、`private.hypervisor`、`private.memorystatus`、`IOSurface.wiredSendRights`+IOUserClient 例外、no-sandbox/no-container、platform-application、AMFI cdhash 执行、麦克风 TCC、`get-task-allow` |
| VMM | `patches/vmm.ents.xml` | 上述之外再加 `vm.device-access`、IOKit 授权、AGX/IOAccel user-client、增内存上限、扩展虚拟地址、ANE/pro-res、**USB HCI**、security message filter、FairPlay IOKit |
| Installation | `patches/installation.ents.xml` | diskimage attach、DeviceSupportUpdater requestor、网络客户端、USB HCI 等 |
| InternetSharing | `patches/internet-sharing.ents.xml` | SystemConfiguration 写、`com.apple.vmnet.plist` 写、packet filter、Ethernet user、IOUserEthernetResourceUserClient、DNS proxy |
| network-helper | `patches/network-helper.ents.xml` | network client/server 等 |

`scripts/audit-entitlements.py` 以 `ldid -e` 比对期望/实际。**App 端 entitlement 远少于 VMM**——能力按进程边界刻意分离；部署完全依赖越狱信任链（platform-application + no-sandbox + cdhash 执行在非越狱环境不可得）。

## 7. 进程 / IPC 拓扑

- **launchd**：`org.jb.vmmservice`（`host/vmm-launchd.plist`，Mach 服务）；guest 内 `gui/$uid/com.mac.virtual.guest-tools`、`com.mac.virtual.opengl-compat`（LaunchAgent/LaunchDaemon，`VZGuestTools.m:469–484,543–575`）；rootful 侧 `vzi.apple.bootpd-controller`（`packaging/rootful/vzi.apple.bootpd-controller.plist`，WatchPaths `/tmp/bootpd.plist` → `/usr/libexec/VirtualMac/bootpd-controller.sh`）。
- **XPC/Mach**：逻辑服务名 `com.apple.Virtualization.VirtualMachine`/`…Installation`；endpoint 接力文件 `/tmp/vmm_ep.txt`；send-right 位于 endpoint+0x18；VMM 用 `task_for_pid`/端口提取；`vmmhook` 以 `xpc_main` interpose 改为 Mach 监听。
- **Socket/文件**：`/tmp/vz-usb-restore.sock`（USB 桥）、`/tmp/vzusbmuxd`、`/var/run/usbmuxd`、`/tmp/bootpd.plist`、`/tmp/VirtualMacGuestTools.ready`、`/var/root/VirtualMac/payload/…`、`/Library/VirtualMac/…`（guest 内）。
- **动态加载**：`dlopen` IOUSBLib/MobileDevice、ellekit/hooker；`dlsym("vz_host_vm_started")`（`VirtualMacApp.m:4558`）；guest `DYLD_INSERT_LIBRARIES=OpenGLPVGCompat.dylib`。
- **兼容层**（host 一组 `*_compat.c`）：ServiceManagement（iPadOS14 `bootpd` 特判）、Security stubs、`libsystem15` 多函数返回 `ENOTSUP`、Hypervisor14 转发、`IOMainPort`、HID 符号、DiskArbitration 占位（`DIIsInitialized`→false）、`_sl_dlopen`、`DebugAssert`/`log2`/`strndup`/`CRIsAutoSubmitEnabled`/OpenDirectory-unavailable 等。

## 8. 问题与风险（精选 8 条，均为源码可证）

1. **大面积版本钉死**：大量 `0x…` 绝对偏移只对 macOS 13.2.1/22D68（VMM、PVG、InternetSharing、objc fixup）与特定 iPadOS14/15 ABI 有效，任何镜像变化即失效或错补丁（各 patch 脚本均带 expected-bytes 校验，失配即拒绝执行——属防御设计但说明脆弱性）。
2. **`/tmp/vz-usb-restore.sock` 0666**：本地任意进程可向控制桥发请求（64MiB 载荷上限要求两端一致实现）；`/tmp` 下多个哨兵/接力文件同样全局可见。
3. **依赖越狱信任链与私有 entitlement**：`get-task-allow`+no-sandbox+no-container+platform-application+AMFI cdhash 的组合表明纯调试/越狱部署形态，非生产安全模型。
4. **GuestPolicy 直接改 guest 内核内存**：把 CSR 策略钉为 `0x6f`（即 csrutil 全关语义）、实验性 `-arm64e_preview_abi` 写入器；`hv_vm_map` 跟踪+页表遍历属高风险写路径，且仅在 `EXPERIMENT_*` 下编译。
5. **`VZLocalPolicy.m` 内嵌 Ventura 开发私钥**并签名改写后的 LocalPolicy 材料——密钥泄露+策略签名绕过是同源问题。
6. **native BC 依赖 AGX ABI 指纹与 MSHookFunction 可用性**：ellekit/hooker 不在场则整条路径静默不启用。
7. **USB fake HCI 属精密时序模拟**：状态机依赖命令码/状态位精确匹配与 100ms/1s 定时，`VMMHOOK_FAKE_USB` 未开则整体链路不存在；EP 描述符生命周期是注释明示的 UAF 雷区。
8. **若干兼容桩是占位/ENOTSUP**：DiskArbitration、OpenDirectory、`libsystem15` 多函数等——调用方若依赖真实语义会得到"假成功/假失败"。

## 9. 局限与置信度

- 本审计未执行任何构建、签名验证或运行时测试；`audit-entitlements.py` 未运行，故**不能断言产物 entitlement 与 XML 一致**。
- `vzxpchook.m`、`metalshim.m`、`native_bc_texture_support.m`、`pvg_trace.m`、`OpenGLPVGCompat.m`、`VZGuestRuntimePolicy.m`、`VZLocalPolicy.m` 的逐行行号以本审计读取区间为据；个别未逐行列出的机制以"文件+实现区域"引用，均可在对应文件中直接复核。
- `EXPERIMENT_GDB_DEBUG`/`EXPERIMENT_VENTURA_OPENGL`/`VMMHOOK_*` 环境变量均为条件路径，报告中已标注。
