# VM 路线 Apple 账户登录适配器 —— 对 macPad PR #4 方法论的移植评估

更新时间：2026-10-22

## 0. 结论先行

| 问题 | 结论 |
|---|---|
| macPad PR#4 方法论能否用于 VM 路线？ | **部分能**：AuthKitUI 两个真实修复 + 全阶段日志观测法可直接移植（已落地为 `vz/guest/AppleAccountSignInCompat.m`）；namespace 隔离/keybag 映射部分是 chroot 专属，VM 不需要 |
| VM 上能否最终登录成功？ | **主要阻断点未变**（见 `ARM-APPLE-IDENTITY.md` §5）：guest 无 SEP，拿不到宿主安全隔区派生身份。适配器能修 web 阶段 bug 并产出"死在哪一步"的证据，但不承诺登录成功 |
| 默认状态 | **关闭**。guest 内 `defaults write com.mac.virtual.guest-tools AccountSignInAdapter -bool true` 后才注入 |

## 1. PR #4 逐件评估

macPad 是 chroot 路线：guest 与 iPadOS 共享内核，账户/钥匙串 daemon 与宿主真机 daemon 同 mach bootstrap 抢名字、keybag 可映射到真机 SEP。VM 路线 guest 有自己的内核/launchd/SEP 视图，结论因此分两类：

| PR#4 组件 | chroot 中的作用 | VM 路线是否需要 |
|---|---|---|
| 私有 Mach namespace（`com.macpad.account15.*` 重命名 ctkd/secd/akd/accountsd/iCloudHelper） | 避免 guest daemon 与 iPadOS 真 daemon 撞名 | **不需要**：VM 内服务天然私有 |
| 11 个私有 guest 后端（克隆的 ctkd/secd/aksd/akd/accountsd/iCloudHelper 等） | 在共享内核上跑 guest 副本 | **不需要**：VM 跑的就是原 daemon |
| ctkd keybag `-3`→`0` 映射 | guest 的 macOS user-session bag 选择子翻译成 iPad 真机 device bag | **不可移植**：VM 无 native bag 可映射。改为 log-only 观察器，先取证据 |
| APNs `namedDelegatePort` 隔离 | 防 guest akd 与宿主 APSConnection 互抢 | **不需要**：VM 内 akd 独立 |
| sysctl capability 匿名管道跨 native→guest exec | 跨 chroot exec 边界传能力 | **不需要**：无此边界 |
| AACloudServiceOwner.bundle 改从 ExtensionKit 内嵌副本加载 | pane 可执行目录限制 | **不需要**：VM pane 可直接读原 bundle；改为 log 观察 bundle 列表 |
| iCloudHelper 私有 Mach endpoint | AOSKit bundled-XPC 客户端改连私有服务名 | **不需要**：guest 原 iCloudHelper 自洽 |
| **AuthKitUI `_createWaitTimerWithTimeInternval:` 30s→90s** | 实测 web 加载 ~38s 超过 30s UI 定时器 | **可移植，已落地**（同一 guest 15.6.1/24G90，selector/类/框架名一致） |
| **WebHTMLView unhide 后空白 → invalidate+display 重绘** | 修复手机号验证页空白 | **可移植，已落地**（PVG guest 的 legacy layer-backed WebHTMLView 有同类风险） |
| 全阶段 JSON stderr 日志（ACCOUNT15_*） | 每步留痕定位死因 | **可移植，已落地**（改标 `VMACCT`） |
| LA/CTK/AKS 观察器（externalizedContext、keybagHandle、AKS error） | 诊断+配合 keybag 映射 | **可移植为纯观察器**：guest 侧记录真实返回值，不重映射 |
| 事务式 install.py + 回滚 | chroot 文件原子替换 | 已由 deb 包 + preinst/回滚包机制覆盖 |

## 2. 已落地的移植件

- **`VirtualMac/vz/guest/AppleAccountSignInCompat.m`**（新增）：
  - web 适配块（移植 PR 的 AccountAuthWeb22）：仅当原始值恰为 30.0 才把 wait timer 提至 90s；`icaWebKitViewIsAvailable` 后按原回调 + AppKit invalidate/display 重绘 WebView/WebHTMLView 子树（不碰 lazy `webView` getter）；resource request/response/finish/fail/timer 全日志
  - LA 观察器：`LAContext externalizedContext`、`LAClient _handleConnectionResult:uuid:proxyId:error:`、`synchronousExternalizedContextWithError:`（log + 错误链展开）
  - CTK 观察器（纯观察，**不重映射**）：`TKLocalSEPKey keybagHandleForceSystemSession:`、`authContextWithError:`、`error:withAKSReturn:ACMHandle:AKSOperation:params:message:`
  - AIDA 观察器：`AIDAServiceOwnersManager serviceOwnerBundles` 记录返回的 bundle 路径与 `com.apple.AppleID.Service.Cloud` 注册情况
  - 防御式安装与 PR 同款：每个 method 验证存在性/参数数/实现归属框架（dladdr 含 `/AuthKitUI.framework/` 等），timer ABI 校验 `d`；每框架 once-flag，任何一步不符即 skip 且不动原实现
- **`VirtualMac/scripts/development/build-account-signin-compat.sh`**（新增）：三切片（x86_64/arm64/arm64e）+ adhoc 签名，与 GL shim 同管线
- **`VirtualMac/scripts/build-guest-tools.sh`**：构建并把 `AppleAccountSignInCompat.dylib` 打进 guest payload `/Library/VirtualMac/`
- **`VirtualMac/vz/host/VZGuestTools.m`**：provisioning 脚本段新增条件式拷贝 + `codesign --verify --strict`（payload 没有该文件时静默跳过，旧 payload 兼容）
- **`VirtualMac/vz/guest/VirtualMacGuestToolsApp.m`**：`DYLD_INSERT_LIBRARIES` 改为列表组合——GL（原有逻辑不变）+ account 适配器（仅当 defaults key 开且文件在且运行时安全策略允许）。两者都关时照旧 unsetenv

## 3. 宿主烟测结果（2026-10-22，本机 macOS 15.8.1 x86_64）

用 `DYLD_INSERT_LIBRARIES` 注入普通测试进程（dlopen AuthKitUI/LA/CTK/AIDA）：

```
VMACCT {"event":"loaded", ...}
VMACCT {"event":"web-installed","wait_seconds":90,"original_callbacks":true}
VMACCT {"event":"la-installed","external":1,"connection":1,"sync":1}
VMACCT {"event":"ctk-installed","bag":1,"auth":1,"aks":1}
VMACCT {"event":"owner-bundles","count":4,"paths":[...,AACloudServiceOwner.bundle,...]}
VMACCT {"event":"owner-installed","registered_cloud":true}
```

期间发现并修复一个真实差异：add-image 回调触发时目标框架的 ObjC 类**尚未注册**（`objc_getClass` 返回 nil）——macPad 在固定 daemon 进程里 constructor 晚于此阶段，VM 全局注入则更早。已改为 pending+重试（250ms×60）等类可解析再装，安装幂等。

注意：宿主 15.8.1 ≠ guest 15.6.1，只是 ABI 烟测；guest 上的真实行为以 VMACCT 日志为准。

## 3. 启用与取证协议

```sh
# guest 内（Terminal.app）：
defaults write com.mac.virtual.guest-tools AccountSignInAdapter -bool true
# 重新登录（env 只影响之后启动的进程），然后 System Settings → Apple Account 走登录流

# 观察日志（任一）：
log stream --predicate 'eventMessage CONTAINS "VMACCT"' --info
log show --last 30m --predicate 'eventMessage CONTAINS "VMACCT"' > /tmp/vmacct.log
```

取证清单（写 WORKLOG 时逐条记录）：
1. `VMACCT loaded` 是否出现在 Settings pane 进程（验证 DYLD_INSERT 是否到达平台二进制——若缺席即说明 dyld 对 pane 剥离了注入，适配器无覆盖）
2. `web-installed` / `la-installed` / `ctk-installed` / `owner-installed` 的安装明细
3. `ctk-keybag-handle` 的 original_bag 值（VM 里到底是 -3、别的负数还是根本不被调用——这是 VM 路线的真实未知点）
4. `la-sync-error`/`ctk-aks-error`/`la-connection-error` 的 domain+code 链（判死在哪一层：设备认证、keychain 还是身份）
5. `web-failed`/`web-timer-fired`（判是否死在 web 阶段）
6. `owner-bundles` 的 paths + `registered_cloud`（判 AIDA owner 是否就位）

## 4. 已知边界（不夸大）

- **SEP 缺席**：本适配器不修"无 SEP 派生身份"这个根因。若证据显示死在 AKS/SEP/attestation，则与 `ARM-APPLE-IDENTITY.md` §5 的结论互相印证；此时下一步候选是研究**半虚拟 SEP 桥**（guest ctkd/aks → VMM → iPad 真机 SEP 的转发设备）——大工程，单列战线。
- **平台二进制注入**：`DYLD_INSERT_LIBRARIES` 对 Apple 平台二进制是否被剥离未证实——`VMACCT loaded` 的缺席本身就是证据，不是失败。
- **user-session bag 语义**：`-3` 是 macPad 在 16.2 chroot 实测到的值；VM guest 的 AKS 行为可能不同，log 先行。
- 本适配器不做：身份生成/注入（已有 identity 工具链）、三码接收、任何 Apple 侧绕过。
