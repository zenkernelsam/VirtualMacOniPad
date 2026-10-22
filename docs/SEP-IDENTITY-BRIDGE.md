# SEP 身份桥（SEP Identity Bridge）设计文档

> 目标：让客机 akd 的 Apple 账户登录流程借用宿主 iPad 的真 SEP 身份完成
> DeviceIdentity/attestation/anisette 认证。与 macPad 相同的信任模型：
> VM 跑在 iPad 硬件上，由该 iPad 的真实设备身份担保。
> 不伪造 DeviceIdentity、不绕过 BAA/Anisette 校验、不伪造证书——
> 所有签名/attestation 均由宿主 iPad 的真 SEP 实时产生。

## 0. 死因链（2026-10-22 实测，逐字）

```
DCBAASigner: Cannot sign data, platform is not supported by DeviceIdentity
  → com.apple.devicecheck.error.baa -10000
AuthKit/akd: DeviceIdentity not available
  → AKAuthenticationError -7066 (host attestation headers 获取失败)
akd: ADIProvisioningEnd failed. Error: -43004
  → AKAnisetteError -8004 "No Anisette for you today!" → -8001
  → SRP authentication with server failed → UI 弹窗 -7018「验证失败」
```

三条独立的身份需求：
1. **BAA/DeviceCheck 签名**（DCBAASigner → DeviceIdentity 签名）——可能非致命
2. **Anisette**（akd anisette 服务 → ADIProvisioningStart/End → SEP）——致命
3. **Host attestation headers**（AKAttestationSigner + SecKeyCreateAttestation + AKRequestSigningHeaderHostAttestationKey）——致命

## 1. 关键架构事实

### 客机侧（macOS 15.6.1 VM，本机可直接取证）

- **akd `flags=0x0`**：无 hardened runtime、无 library validation、
  `platform-application` entitlement。**`DYLD_INSERT_LIBRARIES` 可直接注入**。
  现有全局 env 已包含 `AppleAccountSignInCompat.dylib`，akd 重启后自动加载。
- akd 内部分层（nm/strings 实测）：
  - `AKAnisetteProvisioningController`（client 控制器，`_anisetteDataProvider`
    属性类型 `id<AKAnisetteServiceProtocol>`，`setAnisetteDataProvider:` 为
    **官方注入缝**，同 setter 还存在于 `AKAppleIDAuthenticationContext`/
    `AKAppleIDSession`/`AKAppleIDServerResourceLoadDelegate`）
  - `_AKAnisetteProviderProxy` = 默认 provider，方法全枚举：
    `fetchAnisetteDataForContext:provisionIfNecessary:withCompletion:`、
    `legacyAnisetteDataForContext:DSID:withCompletion:`、
    `provisionAnisetteForContext:withCompletion:`、
    `eraseAnisetteForContext:withCompletion:`、
    `syncAnisetteForContext:withSIMData:completion:`、
    `fetchPeerAttestationDataForContext:withRequest:completion:`
  - 服务侧：`_anisetteServiceListener`(NSXPCListener) +
    `_nativeAnisetteService`→`AKNativeAnisetteService`（服务实现，
    内部调 `ADIProvisioningStart/End`——akd 二进制内含这些字符串与符号）
  - attestation：`AKAttestationSigner` + `SecKeyCreateAttestation` +
    `_attestationDataForRequestData:` + host-attestation header 常量
  - **官方 proxied-auth 通道存在**：`_proxiedAnisetteData`、
    `_pairedDeviceAnisetteController`、`_signWithProxiedDeviceHeaders:`、
    `fetchPeerAttestationDataForContext:` —— Apple 本就定义了
    "设备A为设备B提供 attestation/anisette" 的协议（D2D setup 用途）

### 宿主侧（iPadOS 16.3, iPad13,11，逐字符号扫描）

- **存在**：`DeviceIdentityIsSupported/IssueClientCertificate/
  CopyAttestation/CreateClientCertificateRequest`、`AKAnisette*` 全套
  （含 `AKAnisetteServiceProtocol`——与客机同名协议）、
  `fetchAnisetteDataForContext`/`legacyAnisetteData`、`DCBAASigner`、
  `AKDevice`、`ADIProvisioning` 字符串
- **不存在（macOS-only VM API）**：`DeviceIdentityProcessVMRequest`、
  `DeviceIdentityCreateHostSignature`、`DeviceIdentityValidateIdentity`、
  `AKAnisetteProvisioningService`（精确类名）、`vm_create_host_key_signature`、
  `AVPIdentityData`
- `com.apple.ak.anisette.xpc`：LaunchDaemon akd(mobile) 在**系统域**注册，
  当前 ACTIVE（0x28e03）。root helper 可 `bootstrap_look_up` 直连；
  若 listener 做 entitlement 检查，用 ldid 签私有 entitlement 解决。
- 证据：`.diag/sepbridge-20261022/host-probe/RAW-EVIDENCE.md`

### macPad PR#4 的映射（已逐行读源码）

- macPad 把 `com.apple.ak.anisette.xpc` 重命名到私有命名空间——
  **不转发，克隆 akd 直接产出 anisette**，因为 chroot 共享内核 →
  macOS 二进制原生打到 iPad 真 SEP。证明：Apple 接受 iPad 设备身份
  为 macOS 格式请求的 anisette/attestation。
- VM 的等价物 = 让 guest akd 的同类调用落到 iPad 真 SEP——
  我们实现的不是 macPad 的命名空间隔离，而是它免费获得的
  "共享内核 → 真 SEP"这一层。

## 2. 桥接架构

```
┌─ guest akd (DYLD_INSERT: SEPBridge dylib) ──────────────────┐
│  swizzle AKNativeAnisetteService 服务协议方法                 │
│  swizzle AKAttestationSigner / SecKeyCreateAttestation       │
│  swizzle DCBAASigner(DeviceCheckInternal) 签名路径           │
│      ↓ 序列化参数(plist) → TCP 192.168.64.1:port             │
└──────────────────────────────────────────────────────────────┘
                    ↓ (NAT，仅宿主监听 192.168.64.1)
┌─ iPad root helper (jb, ldid+entitlements) ───────────────────┐
│  anisette → bootstrap_look_up("com.apple.ak.anisette.xpc")   │
│             → NSXPCClientInterface 同协议调用 → iPad akd     │
│  attestation → Security.framework SecKeyCreateAttestation /  │
│             DeviceIdentityCopyAttestationDictionary          │
│  BAA 签名 → DeviceCheckInternal DCBAASigner / DeviceIdentity │
│      ↓ 真 SEP/ADI 实时产出                                    │
│  序列化 AKAnisetteData/attestation/签名 → 回传                │
└──────────────────────────────────────────────────────────────┘
```

### 拦截边界（按优先级）

| 层 | 拦截点 | 覆盖 | 说明 |
|---|---|---|---|
| A | `AKNativeAnisetteService` 的 daemon 协议方法 | akd 自身 + 所有 XPC 客户端 | **单点覆盖**：akd 内部 fetch 经 controller→proxy→self-XPC→本服务；外部 client 直接 XPC 也落在此 |
| B | `AKAttestationSigner` / `SecKeyCreateAttestation` / DeviceIdentity 签名 | "host attestation headers" 路径 | 语义 = 宿主设备自己的 attestation，iPad SEP 直出即正确 |
| C | `DCBAASigner`/`DeviceIdentity` 签名 | DeviceCheck/BAA | 错误日志中非致命，第二阶段再做 |
| 备选 | `_AKAnisetteProviderProxy` 方法 | client 侧 | 若层 A 运行时证明覆盖不全，或改用 `setAnisetteDataProvider:` 注自定义 provider |

**Session/句柄问题**：`ADIProvisioningStart` 返回 session handle；
若层 A 采用"provider 级"转发（只转发最终 fetch 方法），session 生命周期
完全在 iPad 端（iPad akd 自己管理），不存在跨机句柄映射问题——
**这是选层 A 而非原始 ADI 函数级转发的主要原因**。

### 序列化

`AKAnisetteData` 字段均为 plist 类型（machineID/oneTimePassword/
routingInfo/serial/UDID/dsid/date…）。请求参数 = context dict + DSID。
格式：NSKeyedArchiver 或手写 plist dict；传输 TCP 上 `length|plist`。

## 3. 未决问题（按实现顺序验证）

1. **iPad anisette XPC 的 listener entitlement 门槛**：root helper 直连是否
   被 `shouldAcceptNewConnection` 拒绝 → 先写最小 probe（NSXPCConnection +
   `legacyAnisetteDataForContext:DSID:`）实测；被拦则 ldid 签
   `com.apple.private.*` 试配（越狱常规），再不行回退 macPad-chroot helper
   （macPad 自己的 akd 已在同一 iPad 上原生产出 anisette——保底方案）。
2. **`AKNativeAnisetteService` 方法表**：内部类被 strip，静态拿不到；
   写客机侧 runtime introspection probe（dylib 内
   `objc_getClass`+`class_copyMethodList`+`protocol_getMethodDescription`
   on `AKAnisetteProvisioningDaemonProtocol`）确定 swizzle 面。
3. **akd 注入生效确认**：akd 当前 pid 8393（env 生效前启动）；
   `killall akd`（user agent，按需重生）→ 新实例加载 dylib →
   `VMSEP` JSON 事件落 unified log 确认（stderr 进 unified log 未证实，
   同时写文件兜底）。
4. **iPad AuthKit 是否能在 root 进程实例化 controller**：备选直连 XPC。
5. **Anisette 通过后的下一道墙**：设备 cert 颁发/PET token/
   `certificationRequestData`（iPad 有 `IssueClientCertificate` 备用）——
   登录成功 ≠ 服务全开；逐步测。
6. **Apple 服务器接受度**：macPad 证明 iPad 身份配 macOS 请求可行；
   但 VM 的 `VirtualMac2,1`/`AKDevice` clientInfo 与 macPad 的
   chroot 表现是否一致待实测。

## 4. 交付形态

- 客机：扩展 `AppleAccountSignInCompat.dylib` 或新 `SEPBridge.dylib`；
  独立开关 `defaults write com.mac.virtual.guest-tools SEPIdentityBridge -bool true`；
  日志 `VMSEP` JSON 事件（模式同 VMACCT）。
- 宿主：独立 helper 二进制（不经 launchd 常驻；手动跑或临时 plist——
  **不重启/改动任何系统服务**）。
- 传输：helper 只监听 `192.168.64.1:<port>`（VM NAT 网关地址，仅客机可达）。
- 全部改动可回滚：关 defaults + killall akd 即还原。

## 5. 红线复述

不伪造 DeviceIdentity 输出、不绕过 BAA/Anisette 校验、不伪造证书链、
不改 AuthKit 的验签逻辑。桥只改变"谁来执行身份运算"——从客机虚拟环境
变为同一物理 iPad 的真 SEP。所有数据流可被用户审计（VMSEP 日志 +
helper 端日志）。
