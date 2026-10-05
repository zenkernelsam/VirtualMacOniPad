# ARM 版 Apple 身份（machine identifier）复刻指南

更新时间：2026-10-05

本文记录 VirtualMacOniPad 里"生成/复刻 VM 身份"的做法，以及 Apple 服务（iCloud / App Store）对虚拟机身份的硬性要求。目的：以后创建新虚拟机时能按此复刻；同时讲清在 iPad 上为什么拿不到 Apple 服务。

## 1. ARM 上没有"三码"

x86 黑苹果的"三码"是 SMBIOS 的 `SystemSerialNumber` + `MLB`（主板序列号）+ `SmUUID`，由 OpenCore 以 SMBIOS 表注入。**ARM macOS 虚拟机不走这条路**：

- Apple Silicon 用 `Virtualization.framework`，一个虚拟 Mac 由 `VZMacHardwareModel` + `VZMacAuxiliaryStorage` + **`VZMacMachineIdentifier`** 定义；序列号、Hardware UUID、Provisioning UUID 都由 machine identifier 派生。
- 本项目（`VirtualMacApp.m` 的 `makeConfiguration`）没有 SMBIOS / Fakesmc 路径；`AppleBoardSerialNumber` / `AppleROM` 只写入 `VirtualMac.plist`，**当前无消费方**。

所以要"换身份"，改的是 **machine identifier**，不是 MLB/SmUUID。

### 身份表示的实际格式（本机实测）

用 `vzidentity new` 生成后 `plutil -p` 可见，`dataRepresentation` 就是一个二进制 plist：

```
{ "ECID" => 4030798233956965065 }   // 60 字节；ECID 数值大小不同时帧长在 60/68 间变化
```

- **序列号不在其中**，是由 ECID 派生的；macOS 15 的框架上私有 `_serialNumber` getter 不可用（`vzidentity` 输出 `serial=(unavailable)`），项目里因此回退用 **ECID** 作显示标签（`VZAppleIdentityLabelForData`）。

## 2. 一键生成 / 多重身份（应用内）

VM 配置页 → "Apple Services Identity"（section 6）单击：

| 动作 | 行为 |
|------|------|
| `Generate New Identity` | 一键：生成全新 `VZMacMachineIdentifier` 并写成 bundle 的 `MachineIdentifier`；首次会把原身份备份为 `Identities/original.mid`；新身份同时归档到 `Identities/<ms>.mid`；日志打印 `identity=...` |
| `Manage Identities` | 列出池中身份（显示派生 serial 或 `ECID n`，✓ 标当前），点击即切换；可再生成 |
| `Serial / MLB / ROM` | 手工填序列号（走私有 `_machineIdentifierWithSerialNumber:` 派生，作为"指定身份"备选） |
| `Use Original Identity` | 恢复安装时的原始身份 |

- 生成只在 VM 停机时可用；`Identities/` 是 bundle 内的子目录，不影响 `VZIsValidVMBundle`。
- 生成前会按需 dlopen 抽取的 VZ 框架（`ensureExtractedFrameworksLoaded`），因为框架原本只在启动 VM 时才加载。
- 代码位置：`vz/host/VZVMLibraryViewController.m`（UI + 池），`vz/host/VirtualMacApp.m`（`VZWriteFreshAppleIdentity` / `VZAppleIdentityLabelForData`）。

## 3. 三种生成/复刻方式

1. **安装时自动生成**：`vz/install/install_macos.m:169-174` 在全新安装时用 `VZMacMachineIdentifier` 生成并写入——每次新装天然是一个新身份。
2. **应用内一键生成**：见上（适合换身份、给克隆出的新 VM 分配唯一身份）。
3. **离机生成/查看**：Mac 侧探针 `vz/development/probes/vzidentity.m`：
   ```
   clang -fobjc-arc -framework Foundation -framework Virtualization \
       vz/development/probes/vzidentity.m -o /tmp/vzidentity
   /tmp/vzidentity new                 # 生成并打印 hex/base64 + 标签
   /tmp/vzidentity dump <MachineIdentifier>   # 只读查看现有身份
   /tmp/vzidentity write <out.mid>     # 生成并写文件（可预置进 bundle）
   ```
   注意：macOS 15 生成的表示（68/60B bplist）与 iPad 上 Ventura 时代 VZ 的表示**未必互通**，跨版本替换可能被拒；应用内生成（用设备上同一套 VZ）才是权威路径。

### 新虚拟机复刻清单
装好 → 关机 → （可选）`Apple Services Identity` → `Generate New Identity` → 确认状态显示 Configured / 日志出现 `identity=` → 开机 → 在 guest 内核对序列号。

## 4. Apple 服务的硬性要求（iCloud / App Store）

以下为 Apple 开发者文档 + Parallels KB + Apple DTS 论坛的一致结论：

- **宿主与客户机都必须 macOS 15（Sequoia）或更高**；且**必须是从 macOS 15 的 `.ipsw` 全新安装的 VM**（升级来的、旧安装器装的都不行）。
- **VM 身份来自宿主机的 Secure Enclave**（Apple 原文：用 macOS 15 映像创建 VM 时，虚拟化用宿主安全区域的安全信息为 VM 生成身份）；把 VM 迁到另一台 Mac 会**用新宿主的 Secure Enclave 重建身份**并要求重新认证。
- Apple DTS：guest 能登 Apple 账号，靠的是安全改进生成的 **new-style UDID**，不是用户填写的序列号。
- Parallels KB 另指出：Apple Silicon 上 macOS 虚拟机**登录 App Store / Xcode 目前仍属 Apple 框架限制**（iCloud 在 macOS 15 beta 3 才放开）。

## 5. 为什么 iPad 上拿不到 Apple 服务

- 宿主是 **iPadOS（≤16.3.1），不是 macOS 15** → Apple 的首要前提不满足。
- 项目抽取/restamp 的 VZ 框架为 **Ventura 时代**，**未实现 Sequoia 的"宿主 SEP 派生身份"链**。
- 因此：**在 iPad 上，任何"注入序列号 / 生成身份"都无法让 Apple 服务接受**——这是平台限制，不是序列号问题。序列号/身份只影响 guest 内"关于本机"的显示与 UUID，不构成 Apple 认的凭据。

**结论**：一键生成/多重身份可用于本地身份管理；但要用 Apple 服务，需在**真实 Apple Silicon Mac（macOS 15+）+ 全新 macOS 15 VM** 上进行（App Store/Xcode 仍可能受限）。

## 6. 实测记录（实验协议）

在**复制**的 bundle 上做（不动正在运行的 VM），每臂记录 guest 内登录结果与 `/tmp/VirtualMac.log`：

| 臂 | 身份 | iCloud 结果 | App Store 结果 | 备注 |
|----|------|------------|----------------|------|
| 基线 | 安装时生成 | 待测 | 待测 | |
| dummy | 一键生成的随机身份 | 待测 | 待测 | 预期被拒（宿主非 macOS 15） |
| 指定 | 自有 Mac 序列号派生 | 待测 | 待测 | |

部署需 `VZ_IPAD_UDID` / `VZ_IPAD_PASSWORD`（写入 `VirtualMac/.env`），脚本见 `scripts/install-ipad-deb.sh`、`scripts/development/deploy-ipad-app.sh`。

## 边界

不伪造签名、不绕过 Activation Lock/风控、不复用他人身份。若 Apple 因虚拟机策略或硬件信任链拒绝，结论记为平台限制。
## 7. 2026-10-05 黑屏取证与保守修复

用户在一个新生成身份上观察到黑屏，随后恢复 Original。诊断包
`.diag/identity-diagnostics-20261005/VirtualMac-Diagnostics-20261005-212504.zip`
的逐字证据是：

- 生成身份后，日志仍为 `VM configuration validation result=1 error=(none)`
  和 `VM STARTED state=1`，所以不是 VZ 配置校验直接拒绝；
- 该次启动在 `framebuffer state after-2s` 仍为 `lastFrame=0x0/0x0`，
  且随后没有 GuestTools ready 或 PVG frame；
- 同一诊断包中，恢复 Original 的启动出现
  `Apple guest agent ready` 和 `PVG frame=1/2/3`；
- 当前 bundle 的 `MachineIdentifier` 与 `Identities/original.mid` 均为
  60 字节；失败尝试留下的生成样本是 68 字节，ECID 需要高位整数表示。

这组数据证明了“生成身份启动停在无显示帧阶段”的现象，但没有 VZ 错误码，
因此不把 ECID 表示形状写成已经排他的根因。97 的保守门控在生成前读取当前
bundle 表示长度，只接受相同长度且 ECID 不超过 `2^63-1` 的
`VZMacMachineIdentifier`；不合格候选丢弃并重新生成，16 次都不合格则保留
原文件并报告失败。这样避免了本次 68 字节、高位 ECID 样本再次覆盖可启动身份。

身份池的 Manage Identities 现在为每个生成项提供 Delete。original.mid 和当前
活动身份受保护；确认删除后只把非活动生成项移动到
`Identities/.Trash/`，不会直接删除。该目录不参与身份列表。
