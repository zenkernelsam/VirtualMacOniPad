# App Store / Music / TV 账户审计：IDMS 关联与本地占位账户

> 2026-11-12；实际客机 macOS 15.6.1 / 24G90。只读取证，不登录、不调用 SDK 账户认证、不编辑账户库、不注入或重启进程。
> 本机证据：`.diag/20261112-media-readonly/`；上游现场摘要：`.diag/20261111-account-build/guest-readonly-status.json`。

## 结论与纠正

**当前两条媒体账户均为未登录的本地占位账户。旧日志中的 `Security level check failed to find IDMS account` 是“给当前输入账户寻找对应 IDMS 账户失败”的分支，不能据此认定 VM 缺 SEP/FairPlay，或直接判定媒体登录不可实现。**

本次确认的是账户状态和该日志的代码含义；**实际登录失败根因仍待新的正常 UI 尝试取证**。近期 `log show` 被 sandbox 拒绝，未获得这次现场的认证错误链。当前占位账户缺少已登录身份，可能只是登录尚未完成的结果，不能反过来证明它就是登录失败的起点。

| 旧记录 | 本次证据与适用范围 |
|---|---|
| “iTunesStore 从未建行” | 已过时：production / sandbox 各有一行，均 `active=0 / authenticated=0 / isLocalAccount=true`。 |
| “找不到 IDMS”说明全库无 IDMS | 不成立：IDMS 行存在且 `active=1 / authenticated=1`；AMS 查找的是与输入账户相对应的 IDMS。 |
| `ZCREDENTIALTYPE=NULL` 证明没 token | 证据不足：当前 IDMS 的该字段也为 NULL；SQL 元数据不能代替 Keychain 或 AuthKit 实际凭据状态。 |
| 这条错误已证明 VM/FairPlay 硬限制 | 撤回该根因推断：分支在 IDMS 关联失败时直接返回 0，还未进入 `securityLevelForAccount:`。 |
| 客机 akd 没有媒体 entitlements | 当前原生 akd 已有 `applemediaservices`、`appstorecomponents`、`accounts.allaccounts`、`accounts.idms.fullaccess`；仍需按实际调用进程核查权限。 |
| 独立 ADI 的 CloudKit 成功证明媒体已通 | 不成立：双端 Octagon/CKKS 改善与媒体登录验收是不同结果。 |

Apple 的 VM 服务限制、FairPlay、DRM、订阅与地区要求仍可能影响后续功能；本轮没有测到这些路径，也没有证明它们不存在。

## 1. 当前账户：只输出类型、布尔、长度

读取方式：SQLite URI `mode=ro`，连接内 `PRAGMA query_only=ON`。未读取或输出密码、令牌内容、账号名、DSID 值或账户 UUID 值。

| 类型 | 行数 | active / authenticated | supportsAuth | 账户 credentialType / authType | identifier 长度 | username 长度 | isLocalAccount |
|---|---:|---|---:|---|---:|---:|---|
| `com.apple.account.idms` | 1 | 1 / 1 | 0 | NULL / NULL | 36 | 22 | 未查询 |
| `com.apple.account.iTunesStore` | 1 | 0 / 0 | 1 | NULL / NULL | 36 | 5 | **true** |
| `com.apple.account.iTunesStore.sandbox` | 1 | 0 / 0 | 1 | NULL / NULL | 36 | 5 | **true** |

- IDMS 的**账户类型默认 credentialType** 为 `token`；两个媒体类型默认 `password`。类型默认值不是已取得凭据的证明。
- 两条媒体账户的 username 与 IDMS username，精确比较和大小写归一化比较均 **false**；账户 identifier 相等比较也是 false。AMS 的实际匹配逻辑不使用账户 UUID，见 §3。
- 三类账户的 `ZCREDENTIALITEM` 均为 **0 行**。这个结果同样不能单独证明 Keychain 无 token。
- `ZPARENTACCOUNT` 未建立媒体→IDMS 关系；但下述 AMS 方法也不是按 parent FK 查找。

| 类型 | properties 总数 | key 含 dsid | key 含 security | key 含 auth |
|---|---:|---:|---:|---:|
| IDMS | 55 | 2 | 1 | 6 |
| iTunesStore | 6 | 0 | 0 | 0 |
| iTunesStore.sandbox | 2 | 0 | 0 | 0 |

仅对已经由静态代码确认的 `isLocalAccount` property 解包布尔：两个账户均为 true，归档长度均 **138 bytes**。没有解包 DSID、altDSID 或 token 内容。

完整受限聚合：`.diag/20261112-media-readonly/metadata.json`；可复验脚本：同目录 `collect-metadata.py`。脚本只输出类型、flags、长度、相等布尔及已知 credential 类型。

## 2. 日志字符串归属与精确分支

当前 guest DSC 搜索命令与逐字结果：

```sh
VirtualMac/build/toolchain/bin/ipsw dyld str \
  /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e \
  'Security level check failed to find IDMS account'
```

```text
0x19d4e107f: "%{public}@: Security level check failed to find IDMS account" image=AppleMediaServices
```

单独提取一个 image，未导出整个缓存、未占用 IDA：

```sh
VirtualMac/build/toolchain/bin/ipsw dyld extract \
  /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e \
  AppleMediaServices --objc --output .diag/20261112-media-readonly/dsc
```

产物 `AppleMediaServices`：**12,732,400 bytes**；SHA256：
`00dcf5e2c3b8ac472de51ada1130aa6ce3c2a629d4bdbee839e1e7dc59031cbb`。

`-[ACAccount(AppleMediaServices) ams_securityLevel]` 起点 **0x19d180ca4**，关键逐字指令：

```text
19d180cd8  bl  _objc_msgSend$ams_sharedAccountStore
19d180ce8  mov x2, x20                         ; self 作为查询输入
19d180cec  bl  _objc_msgSend$ams_IDMSAccountForAccount:
19d180cf8  mov x19, x0
19d180d04  cbz x19, 0x19d180d38                ; 找不到对应 IDMS
...
19d180d20  mov x2, x19
19d180d24  bl  _objc_msgSend$securityLevelForAccount:
...
19d180dac  add x3, x3, #0x7f                  ; 上述日志 format
19d180dc0  bl  __os_log_impl
19d180dd4  mov x20, #0x0                      ; 缺对应账户分支返回 0
```

因此“Security level check failed”不是已经执行安全等级查询并被拒绝；在这条日志对应的分支里，**对应 IDMS 账户仍是 nil**。不要改返回值、伪造等级或全局旁路检查。

证据文件：`security-level.txt`。复验可使用 Xcode/CLT 的 `llvm-objdump --disassemble --start-address=0x19d180ca4 --stop-address=0x19d180e14`；所有地址为该 guest 缓存的未 slide 地址，不可当运行中函数指针使用。

## 3. AMS 如何寻找“对应的 IDMS”

| 原生方法 | 未 slide 地址 | 行为 |
|---|---|---|
| `ams_IDMSAccountForAccount:` | `0x19d18d21c` | 将目标 type 设为 IDMS，转给下一个方法。 |
| `_correspondingAccountWithAccountTypeIdentifier:forAccount:` | `0x19d18ff74` | 输入 type 已相同则直接返回输入；否则取 altDSID、DSID、username 做关联。 |
| `ams_accountWithAltDSID:DSID:username:accountTypeIdentifier:` | `0x19d18bd3c` | 查询目标 type 的可见账户，再选第一个匹配者。 |
| 上述匹配 block | `0x19d18bfdc` | altDSID 字符串相等 **或** DSID 数字相等 **或** username 精确字符串相等。 |

关联调用逐字证据：

```text
19d190014  bl  _objc_msgSend$ams_altDSID
19d190028  bl  _objc_msgSend$ams_DSID
19d19003c  bl  _objc_msgSend$username
19d190050  mov x2, x23                       ; altDSID
19d190054  mov x3, x24                       ; DSID
19d190058  mov x4, x25                       ; username
19d19005c  mov x5, x19                       ; 目标 account type
19d190060  bl  _objc_msgSend$ams_accountWithAltDSID:DSID:username:accountTypeIdentifier:
```

过滤和匹配逐字证据：

```text
19d18bdb4  mov w3, #0x1
19d18bdb8  bl  _objc_msgSend$_ams_accountsWithAccountTypeIdentifier:options:error:
19d18be48  bl  _objc_msgSend$ams_firstObjectPassingTest:
...
19d18c004  bl  _objc_msgSend$ams_altDSID
19d18c018  bl  _objc_msgSend$isEqualToString:
19d18c020  mov w21, #0x1                     ; 命中即 true
...
19d18c034  bl  _objc_msgSend$ams_DSID
19d18c048  bl  _objc_msgSend$isEqualToNumber:
...
19d18c05c  bl  _objc_msgSend$username
19d18c070  bl  _objc_msgSend$isEqualToString:
```

`options=1` 的完整语义、AMS 进程中 Accounts 的权限/可见性仍待确认。SQLite“有一行”不保证该进程通过该 API 能读到它。旧 `accountsWithAccountType:` 探针也不能直接替代这个实际调用的参数/结果取证。

证据文件：`corresponding-account.txt`、`matching-and-predicate.txt`。

## 4. 为什么当前两行是 local placeholder

`-[ACAccount(AppleMediaServices) ams_isLocalAccount]` 位于 **0x19cceb110**：先检查 iTunes 账户类型，再读取 `_AMSAccountPropertyIsLocalAccountKey`；另有账户 identifier 常量回退分支。

```text
19cceb124  bl  _objc_msgSend$ams_isiTunesAccount
19cceb12c  adrp x8, 0x1e8aff000
19cceb130  ldr x2, [x8, #0x130]             ; _AMSAccountPropertyIsLocalAccountKey
19cceb138  bl  _objc_msgSend$_accountPropertyBooleanForKey:
19cceb140  mov w0, #0x1                     ; 布尔 true 时是 local account
```

当前 DSC 常量 **0x1e8aff130** 指向 CFString **0x1f1d50458**，静态内容逐字为 `isLocalAccount`。媒体 DSID 常量是 `dsid`；altDSID 常量是 `altDSID`。

据此查库并只解码该布尔，两个媒体账户均 **true**。AMS 还含 `_createLocaliTunesAccountForAccountType:`（**0x19d1901bc**）、`performCreateLocalAccountWithType:` 等路径，说明本地账户本身是框架正式支持的状态，不能把它冒充已登录账户。

证据：`local-account.txt` 与 `metadata.json`。本轮没有调用创建方法或改这些 flags。

## 5. 原生认证入口与权限：下一轮取证地图

当前 AMS image 中存在以下方法；只盘点符号，没有执行：

| 方法 | 地址 | 可用于定位哪一步 |
|---|---|---|
| `AMSAuthenticateTask initWithAccount:accountStore:options:bag:` | `0x19d1afaa8` | 媒体认证 task 的来源、account/options/bag。 |
| `AMSAuthenticateTask performAuthentication` | `0x19d1b040c` | 开始认证，而非只查询账户状态。 |
| `_accountForAuthenticationWithError:` | `0x19d1b0e40` | 为认证选择/准备哪条账户。 |
| `_createAuthKitUpdateTaskForAccount:` | `0x19d1b23d0` | 转入 AuthKit 更新流程。 |
| `_performAuthenticationUsingAccount:credentialSource:` | `0x19d1b5a58` | 真正的 credential source 路径。 |
| `_processAuthKitUpdateResult:error:` | `0x19d1b6104` | AuthKit 结果、错误如何向媒体层传播。 |
| `_finishWithVerifiedAccount:andAuthKitUpdateResult:` | `0x19d1b26e0` | 已验证账户的最终完成结果。 |
| `_signIntoOtherMediaTypeWithVerifiedAccount:authenticationResults:` | `0x19d1b3700` | App Store/Music/TV 之间的媒体类型处理。 |

`AMSAuthenticateOptions` 另有 `authenticationType`、`reason`、`mediaType`、`authKitData`、`presentingViewController` 等 getter/setter。仅知道 selector 存在，不能猜枚举值或任意驱动程序化认证。

通过 `/usr/bin/codesign -d --entitlements :- <系统 bundle/akd>` 只读核对：

| 客机原生进程 | 已确认相关 entitlements |
|---|---|
| App Store | `accounts.allaccounts`、`applemediaservices`、`authkit.client.internal`、`appstoreagent`、`appstorecomponents`、`commercekit.appstore` 等。 |
| Music / TV | `accounts.allaccounts`、`applemediaservices`、`authkit.client.internal/private`、Commerce 权限项。 |
| akd | `accounts.idms.fullaccess`、`accounts.allaccounts`、`authkit.client.internal`、`applemediaservices`、`appstorecomponents`。 |

这些是原生签名的权限，并不授权把任意工具伪装成这些客户端，也不证明媒体服务所有下游依赖可用。`amsengagementd` 的准确磁盘路径/签名尚未在本轮取到，不复用其他进程的 entitlement 推断。

上述四个目标均重新核对了 `Software Signing` / Apple 签名 Authority，均非 ad-hoc；`codesign --verify --strict` **4/4 exit0**。这排除了本轮把自签名工具的 entitlements 当成原生目标权限的错误。

## 6. 可测的下一步与数字闸门

1. **先验新包的身份传输与独立 ADI。** 验实际 Guest Tools build/签名、对应真实 iPad 地址、版本化 token 链路、akd 的真实 anisette/signature 返回；不能用“进程活着”或 SDK 单独成功代替。
2. **正常 UI 进行一次媒体登录对照。** 由用户在 App Store / Music / TV 中输入账号与密码，走正常 2FA。本轮没有尝试 Apple 密码。每次明确记录一个应用、一次点击、起止时刻，避免把后台日志误认为该次登录。
3. **点击前/结束后各采一次受限账户元数据。** local→非 local、active/authenticated、identifier 的内部匹配布尔及相关 property 的存在性可以比较；不输出原始身份和 token。账户 flags 单独变化仍不算登录成功。
4. **只读取这次 AMS/AuthKit 错误链。** 优先用户环境中的 `log show/stream`；本工具 sandbox 当前返回 **exit64 / sandbox denied**，没有新日志。若需要新增运行中 hook/注入，先按 AGENTS 红线处理，不默认授权。
5. **检查真实 API 关联结果。** 要区分 `_ams_accountsWithAccountTypeIdentifier:options:1:error:` 返回 0 行、返回 IDMS 但三条匹配均失败、已经匹配但 `securityLevelForAccount:` 返回低等级这三种状态。只有最后一种才研究实际安全等级依据。
6. **成功闸门**：正常 UI 明确显示已登录且能读取需要账户授权的服务内容；账户元数据和该次认证返回一致。分别验 App Store、Music、TV；单个服务通过不宣称三者全通。DRM播放、订阅、地区问题另计。

禁止把占位行直接改 active/authenticated、随意补 DSID、复用 iPad/SDK token 写系统账户、改 `ams_securityLevel` 返回常数或跳分支。任何实现必须来自已确认的原生认证流程，并保留真实失败与回滚能力。

## 7. 证据边界

- 本轮只读了当前用户账户库的受限元数据；未改 Keychain、账户库、个人身份文件或系统服务。
- 只提取当前 guest 的一个 AMS image，保存的是公开静态代码与脱敏聚合；`.diag` gitignored，换机器需另取或单独携带证据。
- 新 helper/独立 ADI 源码、组件离线测试和构建结果，不代表当前运行的旧库已切换，也不代表媒体 UI 已通过。
- `docs/VM-APPLE-ID-REVIVAL-HANDOFF.md` 和 WORKLOG 的 2026-10-24 条目是历史现场：其中“从未建行”“已证明 VM 安全限制”的推断不能覆盖本次新证据。
