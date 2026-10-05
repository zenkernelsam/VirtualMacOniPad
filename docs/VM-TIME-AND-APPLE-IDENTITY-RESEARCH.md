# 挂起恢复时间与 Apple 服务身份研究

更新时间：2026-10-05

## 1. 挂起恢复后的 guest 时间

### 现象与边界

用户报告低电量、息屏或合盖后 iPadOS 冻结 VirtualMac 进程；恢复进入 guest 后，macOS 时间停留在挂起瞬间。该现象符合 guest 虚拟时钟没有在 host resume 后重新校正。它与 GPU、磁盘或 guest 崩溃是独立问题，不能把“VM 进程没崩”当作时钟正确的证据。

### 现有可用通路

`VZGuestTools.m` 已通过 virtio socket 505050 连接 AppleQEMUGuestAgent，并已有 `guest-exec`、`guest-exec-status`、文件读写命令。Guest agent 通道是现成的 root guest-agent 控制面，不需要 SSH、密码、运行中 VMM 注入或内核修改。

源码候选已加入：App 从 `applicationWillResignActive` 记录 host wall time；重新 `applicationDidBecomeActive` 且 inactive 超过 30 秒时，通过 agent 执行 macOS `/bin/date -u MMDDhhmmYYYY.ss`。guest timezone 不变，只校正 UTC instant；agent 未连接时安全跳过。arm64 syntax compile 已通过，尚未打包/安装/实景验证。

### 验收闸门

1. 正常运行 guest，记录 guest `date -u`；
2. 关闭屏幕/盒盖至少 60 秒后恢复；
3. 记录宿主恢复日志、guest `date -u` 和 GuestTools 的 `guest UTC clock sync succeeded/failed`；
4. 重复两次，确认没有在普通前后台切换时误改时间；
5. 若 guest agent 断线，等待重连后再同步，不把失败变成 repair 风暴。

这项改动应单独作为时间同步候选包验收，不能与未验证的磁盘/ GPU 能力表混为一个因果结论。

## 2. iCloud/Apple 服务身份链

### 当前实现的事实

`VirtualMacApp.m` 的 `makeConfiguration` 只从 VM bundle 读取：

- `HardwareModel` → `VZMacHardwareModel initWithDataRepresentation:`；
- `MachineIdentifier` → `VZMacMachineIdentifier initWithDataRepresentation:`；
- `AuxiliaryStorage` → `VZMacAuxiliaryStorage initWithContentsOfURL:`，其中已有 guest boot-args/agent port。

代码没有读取或设置 guest SMBIOS serial/MLB/ROM，也没有 Fakesmc 路径。当前 bundle 文件大小为 HardwareModel 150 bytes、MachineIdentifier 60 bytes；实际值不写入 Git、日志或研究文档。

### VZ payload 的身份能力

实际打包 Ventura Virtualization payload 的 ObjC 元数据/strings 显示：

- `VZMacPlatformConfiguration` 持有 `hardwareModel`、`machineIdentifier`、`auxiliaryStorage`；
- `VZMacMachineIdentifier` 内部持有 `_ECID`、`_serialNumber`（类型 `_VZMacSerialNumber`）和 `disableECIDChecks`，并有 `dataRepresentation`；
- 私有方法名包含 `_machineIdentifierWithSerialNumber:`、`_machineIdentifierWithECID:serialNumber:`、`_machineIdentifierForVirtualMachineCloneWithSerialNumber:`；
- `_VZMacSerialNumber` 内部是 10-byte `AvpSerialNumber` 并提供只读 `string`。

这证明 VZ 有“由 serial/ECID 派生 Mac machine identifier”的内部身份链，但不证明在 iPadOS 16.3 上任意自定义值都能通过校验，更不证明 iCloud 会接受与真实 Mac 同时在线的重复身份。Apple 服务还可能依赖 hardware model、ECID/activation、Secure Enclave、账户风控、网络和 guest OS 签名状态。

### 后续合法研究方式

用户将提供其自有 MacBook 的身份值时，只在当前会话内读取，不写入仓库、日志或包。先做离线格式/长度/一致性检查，再判断 VZ 是否有官方或私有 initializer 能建立 MachineIdentifier；不直接改当前 VM bundle，不覆盖原身份文件。

验证顺序：

1. 只读记录真实 MacBook 自有 identity 的字段来源和格式；
2. 对照 VZ `HardwareModel`/`MachineIdentifier` 的数据表示与 `VZMacMachineIdentifier` 派生方法；
3. 在复制的 VM bundle 上做配置验证，不触碰正在运行的 93；
4. 只有配置被 VZ 接受后，才在用户明确安排的停机窗口做 Apple 服务登录/备份测试；
5. 保留原 bundle 和 93 回滚，不承诺 Apple 服务一定允许虚拟机或重复身份。

不生成第三方序列号、不复用他人身份、不绕过 Activation Lock/Apple 风控、不伪造签名、不注入运行中 VMM。若 Apple 服务因虚拟机策略或硬件信任链拒绝，结论应记录为平台限制。

### 当前 UI 入口候选（已实现，待设备验收）

VM 配置页的”音频与加速”之后新增”Apple Services Identity”入口，停机时可填写 Mac Serial Number、Board Serial Number (MLB) 和 ROM；值保存在当前 VM 的 `VirtualMac.plist`，不写入 Git、日志或打包元数据。开机配置阶段只对已知的 Mac Serial 尝试调用 VZ 私有 `_VZMacSerialNumber` + `_machineIdentifierWithSerialNumber:` 派生 `VZMacMachineIdentifier`；MLB/ROM 暂时保存为未来映射字段并明确打印，不伪称已接入。当前仍未拿用户三码做实测，也未承诺 iCloud 一定恢复。

### 后续：一键生成与多重身份（2026-10-05）

“Apple Services Identity” 入口已扩展为**一键 `Generate New Identity`**：生成全新 `VZMacMachineIdentifier` 写成 bundle 的 `MachineIdentifier`，归档到 bundle 内 `Identities/`（支持多重身份切换、恢复 `original.mid`），生成前按需 dlopen 抽取的 VZ 框架（`ensureExtractedFrameworksLoaded`）。身份表示实测为二进制 plist `{ECID: <int>}`，序列号由 ECID 派生、不存储，显示回退用 ECID。

Apple 服务的硬性要求（宿主+客户机 macOS 15、全新安装、**宿主 Secure Enclave 派生身份**、new-style UDID；Parallels KB 另列 App Store/Xcode 为框架限制）与 iPad 阻断点、复刻清单见 [`docs/ARM-APPLE-IDENTITY.md`](ARM-APPLE-IDENTITY.md)。结论：iPad 宿主下无法通过注入/生成身份获得 Apple 服务，一键生成仅用于本地身份管理。

2026-10-05 的独立诊断显示，唯一 68 字节、高位 ECID 生成样本对应
“VM STARTED 但没有 framebuffer frame”；同一包中的 60 字节 Original 启动收到
GuestTools ready 和 PVG frames。没有配置错误码，结论保持为强相关而非排他因果。
97 起生成器按当前 bundle 的表示长度和 `ECID <= 2^63-1` 做保守门控，失败候选
不覆盖原文件；Manage Identities 可将非活动生成项移入 `Identities/.Trash/`，
保护 Original 和当前活动项。
