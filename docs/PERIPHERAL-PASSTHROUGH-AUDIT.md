# 外设直通现状盘点（Peripheral Passthrough Audit）

> 生成：2026-10-01 · 生成者：Devin（接手 Agent）
> 范围：只读取证。证据来源：①仓库 `VirtualMac/vz/` 代码；②iPad 实机 SSH（`192.168.64.1:2222`）拉取的运行配置与诊断包（本机 `.diag/20260920-121651/`）；③黄金基线 `VMGPU/` 符号普查；④客机内 `ioreg`/`ps`/`launchctl`。
> 结论凡无逐字证据处均标「待确认」。

---

## 0. 结论速览

| 子系统 | 现状 | 直通程度 | 差距 |
|---|---|---|---|
| GPU | PVG+MetalSerializer 转发 + 自有 OpenGL/BC 补丁 | 半直通（virtio→宿主 Metal） | **Ventura 13.2.1 payload vs 15.6.1 客机的序列化差距**；OpenGL 靠客机 shim 归一化；仍有 disableGPU 类失败（详见 GPU 研究文档） |
| CPU | Hypervisor vCPU×8 | 等价直通 | 只剩核数/QoS/亲和性调整空间 |
| 输入 | Mac Keyboard/Trackpad 配置类 + Pencil hover vsock | 已可用 | 240Hz 触控上游已修 |
| 网络 | virtio NAT（bootpd+NetworkSharing 套件） | 可用 | 桥接键 `BridgeInterface=en0` 存在但 `NetworkMode=NAT` 未启用桥接 |
| 音频 | virtio audio in+out | 可用 | — |
| 显示 | `_VZGraphicsDevice`+`_VZFramebuffer`，2732×2048@264ppi | 可用 | `system_profiler SPDisplaysDataType` 客机内输出为空（待查） |
| VideoToolbox | 强制注入原生加速器（`original-supported=0` 仍 attach） | 已直通 | 客机 ioreg：7 个活跃 `AppleVideoToolboxParavirtualizationUserClient` |
| **USB 外设** | **仅 restore/刷机桥**（`vz-usb-restore.sock`）；运行期无 USB 设备 | 未直通 | 框架有类 / 宿主访问通路未定 / entitlement 待证 |
| 目录共享 | `SharedDirectories=[]` 未启用 | 未启用 | virtiofs 通路是否存在待查 |
| Guest agent | virtio socket :505050，QGA 式 JSON | 可用 | — |

---

## 1. VM 运行期设备表（逐字证据）

证据：`.diag/20260920-121651/logs/VirtualMac.log`、`virtual-machines/Sequoia.bundle/VirtualMac.plist`。

```
[VirtualMac] configured guest cpus=8 host-active-cpus=8 memory=10240MiB
[VirtualMac] configured guest display 2732x2048 at 264 ppi mode=NativeRetina
[VirtualMac] configured keyboard device=Mac Keyboard class=_VZMacKeyboardConfiguration
[VirtualMac] configured pointing device=Mac Trackpad class=VZMacTrackpadConfiguration
[VirtualMac] configured virtio audio output=1/0x2801db440 input=1/0x2801daef0
[VirtualMac] configured native VideoToolbox accelerator=0x2801db220 original-supported=0
[VirtualMac] configured virtio NAT network attachment=0x2801db590 mac=2e:e7:f4:1f:ab:98
[GuestTools] configured Apple guest agent socket device
[VirtualMac] graphicsDevices=("<_VZGraphicsDevice: 0x2803ba380>")
            framebuffers=("<_VZFramebuffer: 0x282894770>")
[VirtualMac] 虚拟Mac正在运行 — 已连接原生PVG帧缓冲区
```

`VirtualMac.plist`（Sequoia.bundle，逐字键）：`CPUCount=8`、`MemorySize=10737418240`、`DisplayMode=NativeRetina`、`DisplayWidth/Height=1920×1200`（存储值；实际运行 2732×2048）、`NetworkMode=NAT`（`BridgeInterface=en0` 键存在但未生效）、`AudioInput/OutputEnabled=1`、`KeyboardDevice=MacKeyboard`、`PointingDevice=MacTrackpad`、`VideoToolboxEnabled=1`、`VirtualMacGuestToolsEnabled=1`、**`MetalBCSupportEnabled=1`、`OpenGLAccelerationEnabled=1`（自有键，非 Apple API）**、`SharedDirectories=()`、`ApplePencilPressureTiltEnabled=0`。

⚠️ **无任何 USB/串口/目录共享键**——USB 外设不在 VM 配置面上。

---

## 2. 代码侧：设备装配点与注入面

### 2.1 主路径 `makeConfiguration` — `vz/host/VirtualMacApp.m:4823`
（9/20 App 崩溃栈符号与源码逐字对应，确认此即 App 内配置装配点。）

| 行 | 装配内容 |
|---|---|
| 4825–4830 | 读 `GuestTools`/`OpenGLAcceleration`/`GuestToolsRemovalPending` 三键 → `runtimePolicyEnabled` |
| 4835–4847 | `VZMacPlatformConfiguration` + `VZMacAuxiliaryStorage`；`VZGuestToolsConfigureBootArguments` 写 NVRAM（日志：`-arm64e_preview_abi`） |
| 4849–4866 | `VZMacHardwareModel`/`VZMacMachineIdentifier`（从 bundle 文件反序列化） |
| 4868–4886 | `VZVirtualMachineConfiguration`：CPU 钳 [2,host]、内存钳 [2GB,物理]、`VZMacOSBootLoader` |
| 4888–4940 | `DisplayMode` 六态分支 → 宽/高/PPI 动态键取值；钳位 ≤7680px、72–600ppi |
| 4941– | `VZMacGraphicsDeviceConfiguration` + `VZMacGraphicsDisplayConfiguration`（续见代码） |

### 2.2 备用/测试路径 `vzboot.m`（SSH 冒烟启动器）
- `vzboot.m:91` 逐字注释：`// 13.2.1 uses the USB input devices (VZMac{Keyboard,Trackpad} are macOS 14+); guard nil.` → 该路径用 `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`。
- ~~⚠️ 矛盾待澄清~~ **已澄清**：`nm -gU` 在 Ventura payload 逐字命中 `_OBJC_CLASS_$__VZMacKeyboardConfiguration`/`_OBJC_CLASS_$_VZMacTrackpadConfiguration`/`_VZScreenCoordinatePointerEvent` —— 私有类在 13.2.1 已存在（14 才公开），注释过时，无路径矛盾。

### 2.3 USB 桥（现状唯一 USB 通路，仅服务安装）
- `vz/host/installation_usb_shim.m` 头注释逐字：*"Publish VMM's real AVP-backed restore USB device to MobileDevice without requiring macOS's AppleUSBUserHCIResources kernel service. MobileDevice continues to use iPadOS's native IOUSBLib; only IOKit registry/user-client calls for our synthetic handles are redirected to the VMM socket bridge."*
- 机制：伪造 IOKit 对象（`FAKE_USB_DEVICE_SERVICE_BASE=0x766d2000` 等魔数段）→ MobileDevice 的 IOUSBLib 调用重定向到 unix socket `/tmp/vz-usb-restore.sock`；协议见 `usb_restore_bridge.h`：`GET_STATE/CONTROL/BULK/RESET/CREATE_ENDPOINT`，payload ≤64MB。
- **用途边界**：`start-install.sh` 中 prewarm usbmuxd → RestoreOS USB 移交，仅服务 IPSW 安装。**非运行期外设直通**。
- 客机侧 ioreg：`AppleVirtIOUSBDeviceController` 类存在但实例=0 → virtio-usb 控制器未向客机暴露；`AppleUSBUserHCIResources`=1（含义待查）。

### 2.4 注入面（hook 层）—— 全量盘点（2026-10-01 复核）

**入口方式**：6 个文件带 `__attribute__((constructor))`：`vmmhook.m:2878`、`vzxpchook.m:202`、`pvg_trace.m:1533`、`metalshim.m:488`、`installationhook.m:94`、`installation_usb_shim.m:1833`。

**`vmmhook.m`（VMM 进程兼容层，最大 hook 面）**：
- `__DATA,__interpose` 21 个：`xpc_main`(3000)、`sandbox_init`(3003)、`open`(3040)、`IOSurfaceCreate`(1076)、`xpc_send`/`xpc_send_with_reply`/`xpc_set_handler`(1170-1182)、`IOServiceMatching`/`NameMatching`/`GetMatchingService`/`Open`(2763-2781)、`vmnet` 组(323)、**`hv_*` 全套**：`hv_feat`(3093)、`hv_ipa_size`(3125)、`hv_vm_destroy/create/map/protect`(3144-3198)、`hv_vcpu_create/set_reg/run/set_vtimer_mask/set_vtimer_offset/vcpus_exit`(3262-3421)。
- **USB HCI swizzle 组**：`method_setImplementation`×6 at 2665-2702（`init`/`enqueue_one`/`enqueue_one_expedite`/`enqueue_many`/`enqueue_many_expedite`/`destroy`）—— restore 桥的 VMM 端设备实现。
- **unix socket server**：2172-2187 `bind`/`listen` `/tmp/vz-usb-restore.sock`（chmod 0666）—— 桥服务端在 VMM 进程内。
- `vmm_xpc_main`(2957)：strategy-B `xpc_connection_create(NULL, main_queue)` mach-service listener（顶替 iOS 上不可用的 `xpc_main`）。

**`vzxpchook.m`（App 侧 VZ 兼容层）**：不走 `__interpose`（VZ 对宿主符号是 flat-namespace weak-import，interpose 够不着）→ `vz_rebind_virtualization()`(915-990) 手工 GOT rebind：page 对齐 + `mprotect` + `ptrauth_sign_unauthenticated` 签名写回；rebind 表含 `IOSurfaceLookupFromXPCObject`、`confstr`、`sysctlbyname`、`sandbox_extension_issue_generic_to_process/release`、`xpc_connection_create/send_message/send_message_with_reply/set_event_handler`；`preIOS16Only` 条件位。App 日志逐字：`authenticated VZ rebind=0x...`。

**`pvg_trace.m`（PG 序列化追踪/修复层，注入 VMM）**：`__interpose`(1298) + 约 15 处 `method_setImplementation`——`SegmentedAddressForOffset`(519)、`MappedAddressForOffset`(520)、事件/资源/IOSurface settle 路径(702/857/916/1459/1609-1688)。即 VM 崩溃修复与 GPU 追踪的落点。

**`metalshim.m`（宿主 Metal 兼容）**：`method_setImplementation` at 451/485/522 + ctor(488)。

**`installationhook.m`（安装模式）**：`__interpose` `xpc_main`(203)/`sandbox`(212)/`confstr`(221) + ctor(94)；自带 mach-service listener(131)。

**`installation_usb_shim.m`（MobileDevice 侧）**：`__interpose` 宏段(1783) + ctor(1833) + socket client(185)。

**`VirtualMacApp.m`（App 内）**：`class_replaceMethod`(449)、`method_setImplementation` `frameUpdate`(4426)/`cursorUpdate`(4437) 于 `_VZFramebufferView`(4419/5030)、accelerator `isSupported` 强制(4640)；输入事件合成 `_VZScreenCoordinatePointerEvent`(658)/`_VZKeyEvent`(1453)/`_VZScrollWheelEvent`(808)/Magnify/Rotation/SmartMagnify(682/698/713)。

**系统注入**：`VZKeyboardPassthrough.dylib`（TweakInject，`/var/jb/usr/lib/TweakInject/`）。

**App↔VMM RPC**：14 handler——`map_shared_ram_for_custom_virtio_devices`、`open_host_virtio_socket`、`process_frame_update/cursor_update`、`process_trackpad_haptic_feedback`、`guest_did_panic` 等——**无 USB handler** → USB 直通需新增通路或复用 restore 桥。

**设备装配写点（`setObj(configuration, ...)`）**：`setAudioDevices:`(4607)、`_setAcceleratorDevices:`+`_VZMacVideoToolboxDeviceConfiguration`(4623-4650)、`setNetworkDevices:`(4774)、`setDirectorySharingDevices:`(4817)、`setGraphicsDevices:`(4947)、`VZVirtioBlockDeviceConfiguration`+`setStorageDevices:`(4957-4959)、`setKeyboards:`(4966-4973)、`setPointingDevices:`(4975)、`setSocketDevices:`(5009)。vzboot.m 备用路径：72/85-96。

---

## 3. Payload 能力普查（VMGPU 符号证据）

`VMGPU/Frameworks/` 与设备 `/var/root/VirtualMac/payload/Frameworks/` 目录一致（SSH 核对：15 项）。

| 框架 | 版本 | 来源 | 与本战线相关 |
|---|---|---|---|
| Virtualization | 104.7.1, DTPlatformVersion 13.2 | macOS 13.2.1 (22D68) IPSW（`build/inputs/manifest.txt` 逐字） | 153 ObjC 类；含 USB 类（下） |
| ParavirtualizedGraphics | 13.0.34 | 同上 | `_PGDevice/_PGDisplay/PGFIFO/PGTask/PGIOSurfaceHostDevice/PGDisplayPipeline*/PG*Resource` 约 30 类 |
| MetalSerializer | （Ventura 代） | 同上 | GPU 命令序列化；OpenGL shim 注释称 "Ventura-era serializer" |
| VideoToolbox(+PVSupport) | — | 同上 | 已直通工作 |
| Hypervisor/vmnet/Netrb/DiskImages2 | — | 同上 | hv/NAT/磁盘 |
| 兼容 dylib | MetalCompat/IOKit15Compat/LibSystem15Compat/LibCxx/LaunchServicesCompat(+ipados14) | 自建 | Ventura 栈跑在 iPadOS 16.3 的粘合层 |

**USB 类符号证据**（`nm -gU`/`otool -ov` on VMGPU Virtualization）：
```
_OBJC_CLASS_$_VZUSBMassStorageDeviceConfiguration      ← macOS 15 才公开的同名类，13.2.1 已内置
_OBJC_CLASS_$_VZUSBKeyboardConfiguration
_OBJC_CLASS_$_VZUSBScreenCoordinatePointingDeviceConfiguration
_OBJC_CLASS_$__VZUSBMouseConfiguration / _VZUSBTouchScreenConfiguration / _VZUSBKeyboard
_OBJC_CLASS_$__VZUSBDevice / VZUSBDeviceInternal
方法：_canAttachUSBDevices / _canDetachUSBDevices / _attachUSBDevice:error: /
      _detachUSBDevice:error: / _canGetUSBControllerLocationID /
      _getUSBControllerLocationIDWithCompletionHandler:
```
→ Ventura 代已内置完整 USB 协议栈（至少服务 restore 与 USB 输入设备），`_attachUSBDevice:` 是未公开热插入口。
**能否挂任意实体 USB 外设**取决于：①VMM 是否可实例化 USB 控制器给客机（当前客机 ioreg 实例=0）；②iPadOS 16.3 上访问实体 USB 的用户态通路 + entitlement；③amfi/沙箱放行（`no-sandbox`+`platform-application` 已开绿灯）。
→ **决定性证据需 IDA（Instance4 @13340，待用户加载）反编译 `_attachUSBDevice:error:` / `_VZUSBDevice` 初始化 / USB 控制器的 host 侧设备绑定路径。**

---

## 4. Entitlements 现状与差距

**App**（`vz/host/VirtualMac.entitlements` 逐字）：`security.virtualization`、`private.virtualization`、`virtualization.avp.videotoolbox`、`vm.networking`、`private.hypervisor`、`private.memorystatus`、`private.IOSurface.wiredSendRights`、`iokit-user-client-class=[IOSurfaceRootUserClient]`、`private.security.no-sandbox`、`no-container`、`platform-application`、`private.amfi.can-execute-cdhash`、`private.tcc.allow=[Microphone]`、`get-task-allow`。

**VMM XPC**（`manifest.txt` 内嵌 entitlements 逐字）：`vm.networking`、`private.proreshw`、`aned.private.allow`、`private.hypervisor`、`security.hypervisor`、`ane.iokit-user-access`、`private.vfs.open-by-id`、**`com.apple.usb.hostcontrollerinterface`**、`private.security.message-filter`、`private.FairPlayIOKitUserClient.access`。

差距：
- VMM 自含 `com.apple.usb.hostcontrollerinterface`（macOS 上 USB host 控制器直通正用它）——iPadOS 16.3 是否有对应 user-client 实现 = 可行性另一半，待 IDA+探针。
- App 无显式 USB 设备键；若走 IOUSBHost 通路，可能需向 `iokit-user-client-class` 白名单追加 `IOUSBHostDevice`/`IOUSBHostInterface` 等类。
- `no-sandbox`/`platform-application`/`get-task-allow` 已足够宽松；风险在 iPadOS 内核 USB 栈而非进程权限。

---

## 5. 新发现的问题（非本任务范围，已取证记录）

1. **App 端 `makeConfiguration` 崩溃 ×2**（9/20 12:09 与 12:16，vmfix1 在装期间）：`EXC_BAD_ACCESS @0x10`，栈 `objc_msgSend→-[__NSDictionaryI objectForKeyedSubscript:]→Virtualization+733648→makeConfiguration+572→startVirtualMachineWorker`。疑似字典下标用到坏 key——与笔记 §4.3 "非忠实重建崩在 VZ 的 objc 字典取值"同签名族。**待 IDA 定位 VZ+733648 的调用点**。证据：`.diag/20260920-121651/crash-reports/VirtualMac-*.ips`。
2. **客机 `system_profiler SPDisplaysDataType` 输出为空**——PG 显示设备在客机可工作但 profiler 无条目（待查是否影响 App 的 GPU 能力探测逻辑）。
3. `vzboot.m:91` 注释与运行日志的输入设备类名不一致（§2.2）。

---

## 6. 差距总表与可行性判断

| 需求 | 可行性初判 | 决定性待证点 | 建议下一步 |
|---|---|---|---|
| USB 外设直通 | **中等偏乐观**：框架类全在、VMM 有 HCI entitlement、已有 socket 桥范式可推广 | `_attachUSBDevice:` 在 iPadOS 的实现是否可达实体 USB；IOUSBHost 用户态通路 | IDA Instance4 反编译 VZ USB 路径；iPad 侧只读枚举 USB registry |
| GPU 达真 Mac 水准 | **主要工作面**：Ventura serializer↔15.6.1 客机的协议/feature 差距是已知根因族 | 需枚举失配面（GLD hints、Metal feature set、IOSurface、BT/BC、shader 版本） | 见 `docs/GPU-NATIVE-RESEARCH.md` |
| 桥接网络 | 高：`BridgeInterface` 键已有，需验证 netrb/InternetSharing 桥接路径 | `NetworkMode` 枚举值支持 | 低优先 |
| 目录共享 | 中：需 virtiofs/VZSharedDirectory 类存在性 | 类普查（本报告的类清单可查） | 低优先 |
| 串口/console | 高：RPC 已有 `console_port_did_open_or_close` | — | 低优先 |

---

## 7. 审计方法附注

- 诊断包：设备 `/var/mobile/Media/VirtualMac/Diagnostics/VirtualMac-Diagnostics-20260920-121651.zip`（3 包各 ~1.1GB，本机只抽取了文本证据；bulk 内容主要为崩溃 .ips）。
- 抽取范围：manifest/Settings/全部 logs/package/jailbreak/device/VM plist + 两份 VirtualMac App 崩溃报告 → `.diag/20260920-121651/`（gitignored）。
- 未做：IDA 反编译（Instance1-3 被占；Instance4 待建）、vz/host 全量 74 文件逐行盘点（subagent 并行中，结果将合并回本文件修订版）。
