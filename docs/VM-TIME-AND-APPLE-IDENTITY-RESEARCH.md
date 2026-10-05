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
