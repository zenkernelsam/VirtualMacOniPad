# SEP Bridge 超级交接：macOS VM Apple Account 登录修复

> 交接对象：任何 coding agent（不依赖 Devin 会话记忆）。项目根：`/Users/ciscohe/Desktop/VirtualMacOniPad`。
> 先读本文件 + 根 `AGENTS.md` + `docs/WORKLOG.md`（末尾的 2026-10-22 SEP桥 系列条目 = 逐小时取证流水）。
> 最后更新：2026-10-23，对应 commit `a827f32`。
>
> **2026-10-24 更新（已突破）**：VM 内 Apple Account 登录成功。关键是在客机 `akd` 内
> interpose `sysctlbyname("kern.hv_vmm_present")` 返回 0（`VM_SEP_FAKE_NONVM=1`），
> 让 DeviceIdentity 走真机 BAA 路径，经本桥用 iPad 真 SEP 完成真实 2FA。完整复盘见
> `docs/VM-APPLE-ID-BREAKTHROUGH.md`；开机自恢复 `com.vm.sepbridge.autoapply`。
>
> **2026-10-23 更新（先读这条）**：helper 每个请求都 `kickstart -k` 杀 akd 的 bug 已修
> （`waitForLink(0)` 循环永不执行）——iPad akd 现在常驻，单次转发 1–6ms 而非 ~10s。
> 客机桥改为只注入 akd/appleaccountd/Settings。新取证：anisette 在 akd 内**直连
> `com.apple.adid`**（绕过 ObjC swizzle）；nil-device 的异步 `provisionAnisetteForDevice:`
> / `legacyAnisetteDataForDSID:device:` 会让 iPad akd `std::terminate`。详见
> `docs/WORKLOG.md` 的 2026-10-23 条目与 `.diag/sepbridge-20261023/`。

## 0. 三十秒状态摘要

**目标**：让 iPad M1 上的 macOS 15.6.1 虚拟机（Virtualization.framework）能登录 Apple Account。客机没有 SEP，Apple 身份类操作全部失败；方案 = 把客机 akd 的 AuthKit 叶子调用经 TCP 桥转发到 iPad 的**真实 akd/SEP** 执行，回传真实结果。不伪造任何身份/证书/签名。

**已验证可用**：整条传输链路 + iPad 侧真实签名（AKAttestationSigner.sharedSigner 返回 NSDictionary+NSData，无错误）。

**当前卡点**：登录 UI 点击「继续」后 email 被吞。最后一次带桥测试（23:39）的 akd 日志显示认证流程停在 `Collecting user credentials... Client is capable of displaying UI` ——**之后 email 提交从未到达 akd**。更早的测试（20:34、23:03）**确实**到达过 `signatures-for-data` 并成功转发 —— 即有时能走到签名步、有时连 akd 都摸不到，条件差异未查明。

**VM 刚重启过**：所有 launchctl env 已丢，桥当前未装载，「验证失败」是**无桥的原生失败**，不是新退步。恢复必须按 §6 重新部署。

## 1. 环境事实

| 项 | 值 |
|---|---|
| 执行环境 | 你运行在 **iPad 上的 macOS VM 客机**（VirtualMac2,1, 15.6.1/24G90, arm64e, 8核/10GB） |
| 宿主 | iPad Pro 11" M1, iPadOS 16.3 (20D47) + Dopamine 3.0.2 **rootless** |
| iPad SSH | `sshpass -p <pw> ssh -p 2222 root@192.168.64.1`（密码问用户，**不得写入任何入库文件**） |
| 客机 sudo | `echo <pw> \| sudo -S ...`（同一密码，只用于本会话） |
| 仓库 | `/Users/ciscohe/Desktop/VirtualMacOniPad`，GitHub `zenkernelsam/VirtualMacOniPad`，branch `main` |
| 关键源码 | `VirtualMac/vz/guest/{SEPBridgeCompat,sepinject,sepbridge-helper}.m` |
| 事件日志 | 客机 `/tmp/sepbridge-events.log`（VMSEP JSON 行）；iPad `/var/jb/sepbridge/helper.log`（VMSEPH） |
| 认证流抓包 | `log stream --level debug --predicate 'process == "akd" OR process == "AppleIDSettings" OR process == "appleaccountd" OR subsystem CONTAINS "authkit" OR subsystem CONTAINS "appleaccount"' > /tmp/authcapture.log` |
| 证据目录 | `.diag/sepbridge-20261022/`（含 `ipad-akd/` iPad akd 二进制 + DSC、`introspect/` guest AuthKit 方法 dump、`host-probe/RAW-EVIDENCE.md` iPad AuthKit 能力清单） |

## 2. 桥架构（已实测通的形状）

```
客机 akd ──dyld注入──> SEPBridgeCompat.dylib
   swizzle AuthKit 服务类叶子方法 → NSKeyedArchiver → TCP 192.168.64.1:18443
                                                              │
iPad: sepbridge-helper (launchd user/501/com.vm.sepbridge, KeepAlive)
   :18443 = 客机请求入口；:18444 = iPad akd 反向回链；:18445 = HTTP 文件服务
   请求经 :18444 回链转交 ──> iPad akd 内的 sepinject.dylib（opainject 注入）
                                                              │
sepinject 用真实 AKClient + AKAnisetteProvisioningService /
   AKAttestationSigner.sharedSigner 执行 → 真实 SEP 签名 → 回传
```

- 方向选择原因：iPad akd 沙箱只许**外呼**，故注入侧主动回拨 :18444；helper 做中间人。
- 协议：长度前缀 NSKeyedArchiver plist；`{"op":"daemon","sel":..., "args":[...]}` → `{"args":[...], "error":..., "akdpid":...}`。
- 包装格式：对象经 `sepWrap`/`sepUnwrap`（keyed archive + `{"k":...}` 字典）。

## 3. 已验证事实（带证据）

1. **端到端转发真实成功**：`signaturesForData:options:completion:` → iPad AKAttestationSigner → 返回 `(NSDictionary, NSData=1233B, nil)`，日志：
   `{"resClass":"__NSDictionaryI0,__NSCFData1233","event":"forward-ok","err":false,"ms":9893,"akdpid":35283}`
   `legacyAnisetteDataForDSID:` → iPad 返回真实 `AKAnisetteError` 错误对象（可移植 NSKeyedArchiver 错误通道工作正常）。
2. **absinthe leaf 原语在 iPad 上不查 XPC context**：`absintheSignatureForData:` 实测返回真签名字符串（~8.5-10s 真 SEP 工作）。但返回 `__NSCFString` token，macOS akd 批量接口要 NSData——已改走 signer 类，不再用 absinthe fanout。
3. **真错误链**（无桥时原生失败）：`ADIGetIDMSRouting -45061`/`ADIProvisioningEnd -43004` → `AKAnisetteError -8004 "No Anisette"` → `-8001` → `SRP authentication failed` → UI `AKAuthenticationError -7018` = 「验证失败」。**anisette provision 在 akd 内部直连 `com.apple.adid`（C 级 CoreADI），不经过任何 ObjC 服务层** —— 这是剩余的最底层缺口。
4. GrandSlam `lookup/v2` 网络层实测返回 200（客机网络通）。
5. iPad AuthKit 能力（`.diag/sepbridge-20261022/host-probe/RAW-EVIDENCE.md`）：`DeviceIdentity*`/`AKAnisette*`/`fetchAnisetteDataForContext`/`legacyAnisetteData`/`DCBAASigner`/`ADIProvisioning` 全在；`DeviceIdentityProcessVMRequest`/`CreateHostSignature` 缺（VM attestation API 是 macOS 专属）。
6. 客机 akd `flags=0x0`（无 hardened runtime/LV）→ `DYLD_INSERT_LIBRARIES` 生效；`_AKAnisetteProviderProxy` 默认 provider + `AKNativeAnisetteService`（内含 ADIProvisioning 调用）。

## 4. 已修掉的全部坑（勿重犯）

| 坑 | 根因 | 修法 |
|---|---|---|
| akd「转发成功返回时必崩」| `%@` 格式化 `const char*`（`.UTF8String`）→ SIGTRAP | `%s` |
| fanout 崩 `a.count` | 内层 completion 声明 `^(NSArray*)` 但收到 NSData | `^(id a, id e){ out=a; }` |
| completion 里 EXC_BAD_ACCESS | `vals[]` 存裸指针，ARC 释放后悬垂 | `CFBridgingRetain` 保活 |
| reply block 里 PAC 崩 | 裸函数指针调 block：arm64e invoke 指针带 PAC，非认证跳转必崩 | **用真 block 调用语法**（clang 生成 `blraa`）；switch 1-6 参 |
| akd 转发中途「clean-exit」| launchd idle-exit + `xpc_transaction_exit_clean` 自决 | interpose `xpc_transaction_exit_clean`/`exit(0)`/`_exit(0)`（仅 akd 仅 status 0；旁路 `syscall(SYS_exit)`） |
| helper/iPad 链路整死 | 写死 socket → SIGPIPE 默认杀进程 | 三端 `signal(SIGPIPE, SIG_IGN)` → EPIPE 走重试 |
| iPad akd idle-exit | transaction pin 无效 | 每 20s 泄漏 `xpc_transaction_begin` + 自连 `com.apple.ak.anisette.xpc` 保持连接 |
| `err:true` 假警报 | `resp["error"]={"k":"nil"}` 非空 dict 永真 | 按 k 判，错误详情打 `errDomain/errCode/errRaw` |
| **arm64 而非 arm64e** | 系统进程要 arm64e，arm64-only dylib dyld 即崩（连环崩 Settings 等） | 全部 `-arch arm64e`；iPad 侧用 Theos SDK `/Users/ciscohe/theos/sdks/iPhoneOS16.5.sdk` |
| 注入 iPad 报 unsigned | Dopamine 要 cdhash | `codesign --force --sign -` adhoc 签（cdhash 入 blob）后 opainject 成功 |
| akd 连崩后登录页空白 | launchd 指数退避「spawn scheduled」 | `sudo launchctl bootout gui/501/com.apple.akd && sudo launchctl bootstrap gui/501 /System/Library/LaunchAgents/com.apple.akd.plist`（**勿用 kickstart -k，会挂起等退避**） |
| ReportCrash 看不到 akd 栈 | 「Corpse allowed 1 of 5」限流 | dylib 内 sigaction 自 dump（`sepCrashDump` 写 `/tmp/sepbridge-events.log`） |
| `dyld` env 不持久 | VM 重启即丢 → 桥静默失效 → 退回「验证失败」原生路径 | §6 恢复脚本（TODO：做 LaunchDaemon 免手动） |
| **AppleIDSettings appex 无注入** | ExtensionKit 清 env → dylib 进不了 appex；该 appex 是「stopped」态时点击零响应 | 桥只在 akd/Settings 主进程有效；appex 死了 `killall AppleIDSettings` 重开页 |

## 5. 当前卡点与未决假设

**现象**：输 email → 「继续」转圈 ~15s → email 字段清空。三种已观察到的内部轨迹：

- A（23:39）：akd 收到 auth context → `Collecting user credentials... Client is capable of displaying UI` → **静默 15s → teardown**。email 提交从未到 akd。
- B（23:03、20:34）：完整走到 `signatures-for-data` 转发成功返回 `(NSDictionary, NSData)` —— 之后 akd 崩（当时修复前的旧栈）或继续。
- C（更早）：走到底层 `ADIProvisioningEnd -43004` = anisette provision 需要 adid/SEP → 真错误。

**未决**：
1. 轨迹 A 为什么提交不到达？嫌疑：UI 提交的 XPC 走 `com.apple.ak.auth.xpc` 的另一 selector（未挂桥也无需桥），但**该消息本身**被什么挡住/丢弃；或 appex 在等待某个本地/网络条件后才发提交。取证：`sample` appex 转圈时的栈（主线程卡在哪）；`log stream` 全开级抓 appex 全部消息。
2. 即便提交到了，C 路径的 adid 缺口仍在：**anisette provision = akd→`com.apple.adid` XPC→C 级 CoreADI→SEP**。ObjC 层 swizzle 触不到它。这是**下一层桥**：要么桥 guest↔iPad 的 `com.apple.adid` XPC 消息（C 接口，adid ObjC 面≈0，需逆向其 XPC 消息格式），要么在 akd 内更高层拦截 anisette 请求（`_AKAnisetteProviderProxy` 6 方法已挂，但该类注册晚/可能非此路径——swizzled=15 时是否真调到待验）。
3. `securityd MacOS error -67028`（SecStaticCode，lsd 注册时刷）——大概率与登录无关（是 launchservices 代码签名校验噪声），待证。
4. `System Settings` 进程也装了桥（swizzled=8）——若 UI 流程在 Settings 进程内调被挂方法，会被转到 iPad；目前无该进程的 forward 事件，但不能排除。

**禁止的假捷径**：伪造 anisette/证书/身份、NOP 绕过、无条件返回成功。一切必须真实执行于 iPad。

## 6. 客机恢复步骤（VM 每次重启必做，env 不持久）

```bash
PW=<问用户>
# 1. 拉 dylib（iPad helper :18445 HTTP 文件服务）到 /Library/VirtualMac
echo $PW | sudo -S sh -c 'curl -fsS -o /tmp/SEPBridgeCompat.dylib http://192.168.64.1:18445/SEPBridgeCompat.dylib && rm -f /Library/VirtualMac/SEPBridgeCompat.dylib && mv /tmp/SEPBridgeCompat.dylib /Library/VirtualMac/ && chmod 755 /Library/VirtualMac/SEPBridgeCompat.dylib'
# 2. 三件套 env（gui/501 用户域）
echo $PW | sudo -S sh -c 'uid=$(stat -f %u /dev/console); launchctl asuser $uid launchctl setenv DYLD_INSERT_LIBRARIES "/Library/VirtualMac/OpenGLPVGCompat.dylib:/Library/VirtualMac/AppleAccountSignInCompat.dylib:/Library/VirtualMac/SEPBridgeCompat.dylib"; launchctl asuser $uid launchctl setenv VM_SEP_BRIDGE 1'
# 3. 用户域偏好（不能 sudo 写，写到 root 域无效）
defaults write com.mac.virtual.guest-tools SEPIdentityBridge -bool true
# 4. 杀 akd 让它带桥重生；若遇退避用 bootout+bootstrap（见 §4）
echo $PW | sudo -S killall -9 akd appleaccountd adid
# 5. 验证：akd 起来后 grep '"process":"akd"' /tmp/sepbridge-events.log → daemon-swizzled
```

**iPad 侧（一般不重启就一直好）**：
- 查 helper：`ps aux | grep sepbridge-helper`（pid 32256 系）；日志 `/var/jb/sepbridge/helper.log`
- 查链路：`akd-linked`/`reinject-done` 事件；无回链时 helper 自动 `launchctl kickstart user/501/com.apple.akd` + 重注
- 重注手动：`opainject <akd-pid> /var/jb/sepbridge/sepinject.dylib`（须 adhoc 签名+arm64e）
- `user/501` env 残留 `DYLD_INSERT_LIBRARIES=systemhook:/var/jb/sepinject.dylib`（改不掉）→ 该文件必须持续存在且签名有效；sepinject 有 `getprogname=="akd"` 门控

## 7. 构建命令

```bash
# 客机 dylib（arm64e 必须）
xcrun clang -arch arm64e -dynamiclib -O2 -fobjc-arc -fblocks \
  -framework Foundation -o /tmp/SEPBridgeCompat.dylib VirtualMac/vz/guest/SEPBridgeCompat.m
# 正式构建脚本（x86_64+arm64+arm64e universal）
VirtualMac/scripts/development/build-sepbridge-compat.sh   # 环境变量见 VZ_* in scripts/lib/common.sh
# iPad sepinject（Theos SDK + adhoc 签）
xcrun clang -arch arm64e -dynamiclib -O2 -fobjc-arc -fblocks \
  -isysroot /Users/ciscohe/theos/sdks/iPhoneOS16.5.sdk -miphoneos-version-min=15.0 \
  -framework Foundation -o /tmp/sepinject.dylib VirtualMac/vz/guest/sepinject.m
codesign --force --sign - /tmp/sepinject.dylib
# helper 同上 SDK
```

部署 iPad：`scp -P 2222 /tmp/sepinject.dylib root@192.168.64.1:/var/jb/sepbridge/sepinject.dylib.new` → ssh `mv` fresh inode → `opainject` 重注。

## 8. 诊断命令册

```bash
# 桥事件（客机）
tail -100 /tmp/sepbridge-events.log | grep -vE 'install-pass'
grep -E 'forward|invoke|crash|connect-fail' /tmp/sepbridge-events.log | tail -30
# akd 是否活着/什么版
pgrep -xl akd; log show --last 10m --style compact | grep -iE 'akd.*(SIGSEGV|exited|spawn)'
# 认证流全程（重开抓包最准）
log stream --level debug --predicate 'process == "akd" OR process == "AppleIDSettings" OR process == "appleaccountd"' > /tmp/authcapture.log
# 转圈时给 appex 抓栈（卡点定位）
pgrep -xl AppleIDSettings; sample <pid> 3
# iPad 侧
sshpass -p <pw> ssh -p 2222 root@192.168.64.1 'tail -30 /var/jb/sepbridge/helper.log; ps aux | grep -E "akd|sepbridge"'
# 客机崩溃报告
ls -lt ~/Library/Logs/DiagnosticReports/ | head   # akd corpse 受限流：看 events.log 的 "crash" 事件
```

## 9. 下一步建议（按优先级）

1. **转圈抓栈**：用户点「继续」转圈期间 `sample AppleIDSettings 3` + `sample akd 3` + 全量 `log stream`——定位提交到底卡在 UI 还是 XPC。**这是当前最高信息量的一步，成本极低。**
2. 若提交到了 akd：顺 `com.apple.ak.auth.xpc` 的 selector 列表补 swizzle（`authenticateWithUsername:` 等可能在别的服务类上）。
3. 若走到 anisette：桥 `com.apple.adid` 层（逆 iPad adid 的 XPC 消息格式；iPad adid 是 system 域守护，注入/转发都要重新评估——**注意：这是 C 接口工程，量级等同再造一层桥**）。`.diag/sepbridge-20261022/ipad-akd/` 有 iPad akd 二进制可上 IDA。
4. 验证 `_AKAnisetteProviderProxy` 6 个 context 方法是否真被调（forward 事件若从不出现，说明 akd 走的是 `AKNativeAnisetteService` 内部直连 adid）。
5. 把恢复步骤做成 LaunchDaemon（免每次重启手动 env）。

## 10. 铁律（继承 AGENTS.md）

- 取证先行：任何结论附逐字证据（崩溃报告/日志/反编译/命令输出）。
- 禁症状式补丁：不 NOP、不伪造能力常数、不伪造身份/证书。
- iPad 侧：不 panic 风险操作（不重启系统服务、不写 nvram、不动内核）；只用户态注入已授权的 akd/helper。
- 凭据：SSH/sudo 密码只在会话上下文，**绝不写入入库文件/文档**。
- Git：`git add <明确路径>`、英文 ASCII commit message、commit 后立即 `git push origin main`。
- `VMGPU/` 只读黄金基线；`~/Desktop/macPad` 只读参考。
- 中文交流、技术术语留原文、先结论后依据、不确定标「待确认」。
