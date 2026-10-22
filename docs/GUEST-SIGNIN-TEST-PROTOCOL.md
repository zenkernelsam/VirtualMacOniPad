# Guest 内 Apple Account 登录适配器实测协议

> **执行者**：跑在 macOS 客机（VM）里的 agent。
> **前提**：宿主已安装 `VirtualMac_1.2.3_317567bbc7.deb`（或更新）且客机已重启过一次；本仓库已同步到 ≥ `ac12a5f`。
> **目标**：实测 `AppleAccountSignInCompat.dylib`（web 30→90s 超时延长 + 空白页重绘 + LA/CTK/AIDA 观察器）在 guest 15.6.x 上的真实行为，拿到"登录死在哪一步"的证据。**不承诺登录成功**——SEP 身份链天花板见 `docs/ARM-APPLE-IDENTITY.md` §5。

## 0. 红线（先读再动手）

- **只读取证 + 一个 defaults key**。不改 guest 系统文件、不装描述文件/证书、不动 keychain 内容、不碰 SIP/boot-args。
- **凭据安全**：Apple ID 密码由用户本人输入，agent 不索要、不记录、不入日志；截图/日志交付前遮罩邮箱与个人信息。
- **禁止把"界面没报错"写成"登录成功"**。只有账号持久化在 System Settings 里显示（姓名/设备列表）才算过了那一关。
- 登录流只做 Apple ID 账密 + 双重认证那一段；**不试** iCloud 钥匙串、Apple Pay、查找我的 Mac（这些有真实副作用）。

## 1. 前置校验（全部通过才继续）

```sh
# 1a. Guest Tools 已是新构建（NN-短hash 与新 deb 对应；旧值=未装机成功）
cat /Library/VirtualMac/.build

# 1b. 适配器在 guest 文件系统里（宿主 provisioning 已拷贝+验签）
ls -la /Library/VirtualMac/
lipo -info /Library/VirtualMac/AppleAccountSignInCompat.dylib
# 期望: x86_64 arm64 arm64e 三切片；arm64e 必须有（guest 平台二进制）
codesign --verify --strict /Library/VirtualMac/AppleAccountSignInCompat.dylib && echo SIG-OK

# 1c. 运行时安全策略满足（GL shim 能跑的同一条件）
csrutil status 2>/dev/null | head -3
nvram boot-args 2>/dev/null
# 期望: SIP 放宽 + boot-args 含 -arm64e_preview_abi
```

**若 1b 缺文件**：说明装的 deb 没含新 payload 或 provisioning 跳过 → 停止，回报 `.build` 值和 `ls /Library/VirtualMac/` 输出，不要手动造文件。

## 2. 启用适配器

```sh
defaults write com.mac.virtual.guest-tools AccountSignInAdapter -bool true
```

然后**注销并重新登录** guest（菜单栏 → 注销）。Guest Tools menu extra 是 login item，重登时会重跑 `applyOpenGL` 把新 insert 列表写进 launchd 环境。

> 不想重登的替代：退出并重开 "Virtual Mac Guest Tools"（`/Library/VirtualMac/Virtual Mac Guest Tools.app`），效果相同——`applyOpenGL` 在 app 启动时执行。重登更干净，推荐。

登录回来后验证：

```sh
launchctl getenv DYLD_INSERT_LIBRARIES
# 期望含两个路径（冒号分隔）:
#   /Library/VirtualMac/OpenGLPVGCompat.dylib:/Library/VirtualMac/AppleAccountSignInCompat.dylib
# 只有 GL 一个 → pref 没生效；空 → GuestTools 没跑。回报并停止。
```

注意：**env 只影响 setenv 之后启动的进程**。已运行的 System Settings 不受污染——下一步会先杀再拉起。

## 3. 取证通道（两路并行，登录前就绪）

终端 A —— unified log（launchd 会捕获 GUI 进程 stderr，VMACCT 行在这里出现）：

```sh
log stream --info \
  --predicate 'eventMessage CONTAINS[c] "VMACCT"' \
  > ~/vmacct-stream.log 2>&1 &
```

终端 B —— 兜底直捕（如果 A 路一条都没有，说明 stderr 没进 unified log；用此法重测）：

```sh
# Terminal/agent shell 已继承 gui 域 env（先 echo $DYLD_INSERT_LIBRARIES 确认非空）
pkill -x "System Settings" 2>/dev/null; sleep 1
"/System/Applications/System Settings.app/Contents/MacOS/System Settings" \
  2>&1 | tee ~/vmacct-stderr.log &
```

再开一个终端 C 收集 Apple 服务侧对照日志（判断死在哪步的关键上下文）：

```sh
log stream --info \
  --predicate 'process == "accountsd" OR process == "akd" OR process CONTAINS[c] "appleid" OR process CONTAINS[c] "authkit"' \
  > ~/appleauth-stream.log 2>&1 &
```

## 4. 走登录流（用户在场输凭据）

1. System Settings → 顶部 "Sign in with your Apple Account"（或 Apple ID 栏）
2. 用户输入真实 Apple ID + 密码，走 2FA
3. **计时观察**：
   - 页面是否在 ~30s 处白屏/转圈失败（= 原版超时，适配器没生效）
   - 是否顺利越过 ~38s 点（= 90s 延长生效的间接证据，须与 VMACCT 日志互证）
   - 空白/黑页是否自动重绘出内容
4. 记录每个阶段的**确切错误**：错误码（如 `-22421`、`动作未能完成`）、弹窗文案、卡住的画面

## 5. 判读 VMACCT 事件（对照表）

| 日志行 | 含义 |
|---|---|
| `{"event":"loaded"}` | 适配器被注入该进程——出现在哪个进程名下面就说明登录 UI 跑在那个进程 |
| `{"event":"web-installed","wait_seconds":90}` | AuthKitUI hook 装上，超时延长生效 |
| `{"event":"la-installed",...}` / `"ctk-installed",...` | LocalAuthentication / CryptoTokenKit 观察器就位 |
| `{"event":"owner-installed"}` / `"owner-bundles"` | AIDA ServiceOwner 观察到 iCloud helper bundle |
| `web-retry` / `*-skipped` / `retry-exhausted` | 类/方法/profile 不匹配——**说明 guest 版本与预期不符，是重要负证据** |
| LA/CTK 调用事件（`la-`、`ctk-` 前缀） | 登录流实际走到了那一步；缺哪个阶段=死在那之前 |
| **完全没有 VMACCT** | DYLD_INSERT 被剥离（平台二进制保护）或登录 UI 在别的进程——用 §3-B 兜底重测一次，仍无则回报"注入未生效" |

死亡点速查：
- `web-installed` 有、但卡在密码提交 → akd/AuthKit 服务端问题（看 appleauth-stream.log 里 akd 的 error）
- `ctk-`/`la-` 全无 → 连本地凭证/Keybag 路径都没走到
- `ctk-aks`/`ctk-bag` 有调用但返回错 → 撞上 SEP/Keybag 天花板（预期内，记录返回值）

## 6. 收集与交付

```sh
mkdir -p ~/.diag/signin-$(date +%Y%m%d-%H%M%S) && cd $_
mv ~/vmacct-stream.log ~/vmacct-stderr.log ~/appleauth-stream.log . 2>/dev/null
cp /Library/VirtualMac/.build build-marker.txt
log show --last 30m --info \
  --predicate 'eventMessage CONTAINS[c] "VMACCT" OR process == "accountsd" OR process == "akd"' \
  > logshow-30m.log
sw_vers > swvers.txt
# 关键结果截图（遮罩个人信息）放同目录
```

报告按此格式（中文，结论先行）：

```
## 登录适配器实测结果
- guest: sw_vers 值 / .build 值
- 注入: loaded 出现在哪些进程
- 安装: web/la/ctk/owner 各 = installed|skipped|retry-exhausted
- 死亡点: 阶段 + 确切错误码/文案
- 结论: 超时延长是否生效（38s 点是否越过）、是否撞上 SEP/keybag
- 附件: ~/.diag/signin-*/
```

## 7. 关闭与回滚（测完必做）

```sh
defaults write com.mac.virtual.guest-tools AccountSignInAdapter -bool false
# 注销重登，然后:
launchctl getenv DYLD_INSERT_LIBRARIES
# 期望: 只剩 OpenGLPVGCompat.dylib（或 unset）
```

适配器默认关，不设回滚也不会影响日常使用；但取证结束后关掉可减少全局注入面。
