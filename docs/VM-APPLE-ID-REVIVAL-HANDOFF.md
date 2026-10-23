# 复活交接：VM 内 Apple ID（iCloud 已打通，App Store 未通）

> 写给“下一个被重启/压缩的 Agent”。读完这一份即可接手，不依赖旧会话。
> 现场：**克隆机** `Sequoia-SerialAux.bundle`（iPad 序列号身份）已登录 iCloud；
> 原机 `Sequoia.bundle` 未动。日期 2026-10-24。
> 相关文档：`docs/VM-APPLE-ID-BREAKTHROUGH.md`（完整复盘）、`docs/WORKLOG.md`（逐小时）、`AGENTS.md`。

---

## 0. 三十秒状态

| 项 | 状态 |
|---|---|
| **iCloud / Apple Account** | ✅ **已登录可用**（账户页、设备列表） |
| App Store / Music / TV（媒体服务） | ❌ 未登录；AMS 安全等级校验拦截（详见 §6） |
| 客机身份 | `IOPlatformSerialNumber=R9D3WPY7T5`（iPad 真值）、`IOPlatformUUID=1E03B2C5-6EA3-5850-AD99-4A0D4CD473A8`、`model=VirtualMac2,1` |
| 账户 | `hejiajie9527@gmail.com`（Cisco He，DSID 10118378221） |
| 桥 | 客机 akd 内 `SEPBridgeCompat` + `VM_SEP_BRIDGE=1` + **`VM_SEP_FAKE_NONVM=1`** |
| 网络 | en0 MTU **1400** + pf 封出站 UDP/443（QUIC）——iCloud 设备列表依赖它 |
| 开机自恢复 | `com.vm.sepbridge.autoapply`（env + 网络 + 重启 akd） |
| 关键 commit | `8eccd12`（配方+自恢复）、`e6a49ac`（网络持久化+App Store 结论）、`82bc9c5`（AMS 卡点）、`24e9e52`（staging 教训） |

**一句话原理**：客机 akd 内 interpose `sysctlbyname("kern.hv_vmm_present")` 返回 0
（让 DeviceIdentity 认为“不是 VM”），AuthKit 于是走真机 BAA 路径，anisette/签名
由既有 SEP 桥转发到 **iPad 真 SEP**，完成真实 2FA。不是伪造身份。

---

## 1. 当前运行状态快速验证

```sh
# 身份
ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'IOPlatformSerialNumber|IOPlatformUUID|"model"'

# 桥与开关（期望 loaded + fake-nonvm + install-pass swizzled:18）
grep -E '"event":"(loaded|fake-nonvm|install-pass)"' /tmp/sepbridge-events.log | tail -3
pgrep -xl akd

# 环境（期望含三库、VM_SEP_BRIDGE=1、VM_SEP_FAKE_NONVM=1）
launchctl asuser 501 launchctl print gui/501 | grep -A6 environment

# 网络（期望 mtu 1400、pf Enabled）
ifconfig en0 | grep mtu
sudo pfctl -s info | grep Status
sudo pfctl -sr | grep 'udp.*443'

# 账户
defaults read MobileMeAccounts | grep -E 'AccountID|DisplayName'
pgrep -xl cloudd; pgrep -xl appleaccountd
```

iPad 侧：

```sh
ssh root@192.168.64.1 -p 2222 'ps aux | grep -E "[s]epbridge-helper|[A]uthKit.framework/akd"'
# helper 监听 18443/18444/18445；akd 已被 sepinject 注入并回链
```

---

## 2. 从零复现（完整步骤）

### 2.1 iPad 侧（一次装好，重启 iPad 后需重来）

- App：`/var/jb/Applications/VirtualMac.app`（payload 在 `/var/root/VirtualMac/payload/`）
- `sepbridge-helper`：`/var/jb/sepbridge/sepbridge-helper`，launchd `user/501/com.vm.sepbridge`
  - 18443：客机入口；18444：iPad akd 回链；18445：HTTP 文件服务
  - 行为：akd 存活时**不再** `kickstart -k`；每个请求不再杀 akd（关键修复）
- `sepinject.dylib` 注入 iPad akd：helper watchdog 每 3s 检查 pid 变化后
  `opainject <akd-pid> /var/jb/sepbridge/sepinject.dylib`
- 源码：`VirtualMac/vz/guest/{sepbridge-helper,sepinject}.m`
- iPad 侧辅助资产（本次会话留下）：
  - `/var/jb/tmp/compat/{Hypervisor,ParavirtualizedGraphics,Virtualization}`（VZ 私有 API 探针用）
  - `/var/jb/tmp/serial.mid`（带 iPad 序列号的 MachineIdentifier）
  - `/var/jb/tmp/{vzid*,vzgen*,vzload,vzclone,vzaux,patch_clone.sh}`

### 2.2 克隆机（身份 + 启动）

必须满足三条，缺一黑屏/失败：

1. **Disk.img**：源盘 APFS clonefile
2. **AuxiliaryStorage**：**直接复制源机**（新建 AuxStorage 会黑屏，已对照验证）
3. **MachineIdentifier**：`{ECID, SerialNumber:"R9D3WPY7T5", DisableECIDChecks:true}`（121B）

生成方法（宿主侧 VZ 私有 API，工具已在库）：
`VirtualMac/vz/development/probes/vz-identity/`
- `vz_identity_gen`：调 `_machineIdentifierWithSerialNumber:`，
  并把 `_serialNumber` ivar 换成真正的 `_VZMacSerialNumber`（payload 的 bug 绕法），
  得到 bplist `{ECID, SerialNumber, DisableECIDChecks}`
- `make_identity_clone.sh`：clonefile Disk.img + **clonefile 源 AuxStorage** + 写身份
- `vz_aux_create` 仅用于“全新 VM”，不要用于克隆

### 2.3 客机桥部署

```sh
cd ~/Desktop/VirtualMacOniPad/VirtualMac
VZ_SEPBRIDGE_GUEST_BUILD=/tmp/sepbuild bash scripts/development/build-sepbridge-compat.sh
# 产物：/tmp/sepbuild/SEPBridgeCompat.dylib（universal）

sudo sh -c '
cp /tmp/sepbuild/SEPBridgeCompat.dylib /Library/VirtualMac/.sbc.$$
chmod 755 /Library/VirtualMac/.sbc.$$
rm -f /Library/VirtualMac/SEPBridgeCompat.dylib
mv /Library/VirtualMac/.sbc.$$ /Library/VirtualMac/SEPBridgeCompat.dylib   # fresh inode 必须
uid=$(stat -f %u /dev/console)
launchctl asuser $uid launchctl setenv DYLD_INSERT_LIBRARIES \
  "/Library/VirtualMac/OpenGLPVGCompat.dylib:/Library/VirtualMac/AppleAccountSignInCompat.dylib:/Library/VirtualMac/SEPBridgeCompat.dylib"
launchctl asuser $uid launchctl setenv VM_SEP_BRIDGE 1
launchctl asuser $uid launchctl setenv VM_SEP_FAKE_NONVM 1
killall -9 akd
'
defaults write com.mac.virtual.guest-tools SEPIdentityBridge -bool true
sudo launchctl kickstart gui/501/com.apple.akd
```

### 2.4 网络修复（iCloud 设备列表必需）

热点 NAT 下 QUIC（UDP/443）不可靠；TCP 正常。开机脚本已自动做，手动等价：

```sh
sudo ifconfig en0 mtu 1400
cat > /tmp/noquic.rules <<'R'
block return out quick proto udp from any to any port 443
pass out quick all keep state
R
sudo /sbin/pfctl -e
sudo /sbin/pfctl -f /tmp/noquic.rules
```

### 2.5 登录

System Settings → Apple 账户 → 输入 email/密码 → 继续。
预期：iPad 弹 Apple ID 授权窗、iPhone 要求密码（真实 2FA）→ 客机落库。

**注意**：App Store 的登录弹窗（AuthKitUI）在本 VM 里**不会把密码交给 akd**，
不要用它来验证桥；用 Settings 的 Apple 账户页登录。

### 2.6 成功判据

```sh
defaults read MobileMeAccounts | grep -E 'AccountID|DisplayName|status = active'
sqlite3 ~/Library/Accounts/Accounts4.sqlite \
  "select Z_PK,ZUSERNAME,ZACCOUNTTYPE,ZACTIVE,ZAUTHENTICATED from ZACCOUNT;"
# 期望：idms(9)/AppleIDAuthentication(54)/AppleAccount(56)/… 均 active
pgrep -xl cloudd; pgrep -xl appleaccountd
```

---

## 3. 重启恢复

### 3.1 自动（已装）

- `/Library/LaunchDaemons/com.vm.sepbridge.autoapply.plist`
- `/Library/VirtualMac/apply-sep-bridge.sh`
- 行为：等真实登录用户（uid≠0、`/Users/<name>` 存在、`gui/<uid>` 可 print）
  → 设三库 env + `VM_SEP_BRIDGE=1` + `VM_SEP_FAKE_NONVM=1` → 写偏好
  → `ifconfig en0 mtu 1400` + pf 规则 → `kickstart -k gui/$uid/com.apple.akd`
- 日志：`/var/log/sepbridge-autostart.log`

### 3.2 手动兜底

```sh
sudo /bin/sh /Library/VirtualMac/apply-sep-bridge.sh
# 然后按 §1 验证
```

### 3.3 若 iCloud 页面失败

先查 §1 的 MTU/pf；热点抖动时 MTU/pf 也可能要重设（脚本会处理）。
仍失败时看 `log stream` 里 `quic_conn_idle_timeout_fired` 是否消失。

---

## 4. 资产清单（关键路径）

| 路径 | 说明 |
|---|---|
| `/Library/VirtualMac/SEPBridgeCompat.dylib` | 客机桥（当前 SHA256 `ccd2e036…a871cb`） |
| `/Library/VirtualMac/AppleAccountSignInCompat.dylib` | 登录适配（SHA256 `bc5018dc…908b1`） |
| `/Library/VirtualMac/OpenGLPVGCompat.dylib` | GPU shim（必需在 env 里） |
| `/Library/VirtualMac/apply-sep-bridge.sh` | 开机恢复脚本 |
| `/Library/LaunchDaemons/com.vm.sepbridge.autoapply.plist` | 开机任务 |
| `/tmp/sepbridge-events.log` | 桥事件（loaded/fake-nonvm/install-pass/forward-ok/call/cred/…） |
| iPad `/var/jb/sepbridge/` | helper、sepinject、serial.mid、VZtest 等 |
| iPad `/var/jb/tmp/compat/` | VZ 私有 API 探针依赖 |
| 源码 | `VirtualMac/vz/guest/*.m`、`VirtualMac/vz/development/probes/vz-identity/` |

当前指纹：`IOPlatformUUID=1E03B2C5-6EA3-5850-AD99-4A0D4CD473A8`，
account DSID `10118378221`，AltDSID `000283-10-c3777a40-2785-404a-b5f2-53fd2420c8c5`。

---

## 5. 环境变量 / 探针参考

| env | 作用 | 默认 |
|---|---|---|
| `VM_SEP_BRIDGE=1` | 启用客机桥 | 开 |
| `VM_SEP_FAKE_NONVM=1` | akd 内把 `kern.hv_vmm_present` 报 0（**iCloud 的关键**） | 开 |
| `VM_SEP_VERBOSE=1` | completion 逐参数日志 | 关 |
| `VM_SEP_PROBE_CALLS=1` | 每个被挂方法入口打 `call` | 关 |
| `VM_SEP_PROBE_CREDS=1` | 记录上下文 username/password 的**长度** | 关 |
| `VM_SEP_PROBE_CTX=1` | 记录缺密码上下文的 bundle/service/reason 指纹 | 关 |
| `VM_SEP_STAGE_PASSWORD=1` + `VM_SEP_STAGE_EMAIL=<id>` | 用 `/tmp/.vmsep-pw`（0600，读取即删，3 分钟清除）给缺密码的上下文补位 | 关 |
| `VM_SEP_DEVID_TEST=1` | 启动时跑 AVP 身份探针 | 关 |
| `VM_SEP_MEDIA_SIGNIN=<id>` | 在 App Store/cdpd/appleaccountd 内做一次性密码认证 | 关 |

诊断用 `amsengagementd` 的**只读**账户探针（`ams-probe`/`ams-accts`/`ams-type`）已在
代码里，只在该进程安装、不加载桥的其它 swizzle。

---

## 6. App Store / 媒体服务：现状与下一步

### 6.1 已确认

- AuthKitUI / `AKAuthorizationRemoteViewService` 的登录 sheet：能弹、能输入（有圆点），
  但**密码从不交给 akd**（akd 只收到 username；`_password` getter 未被调用），
  SRP 报 `M2 missing (bad password)` → `-7013`/4097。
- 同一密码在 **cdpd**（有 auth entitlement 的守护）内驱动
  `AKAppleIDAuthenticationController authenticateWithContext:` **可以成功**
  （拿到 AKIDMSToken/AKIdentityToken/AKDSID…）。
- 媒体账户创建被 AMS 拦截，日志逐字：
  `ACAccountStore: Failed to find a corresponding account (accountTypeIdentifier = com.apple.account.idms)`
  `ACAccount: Security level check failed to find IDMS account`
- `Accounts4.sqlite`：type 9（idms）行 active/authenticated 但 `ZCREDENTIALTYPE` 为空、
  dataclass 属性为空；`com.apple.account.iTunesStore`（type 47）**无账户行**。
- macPad 的 akd 被授予媒体 entitlements（`com.apple.private.applemediaservices`、
  `appstorecomponents`、`appstored`），其 App Store 可用依赖真机 keystore/FairPlay；
  本 VM 没有真 keystore，这是最可能的本质差异。

### 6.2 待做实验（按优先级）

1. **看 AMS 的真实查询**：打开 Music 登录一次，读 `/tmp/sepbridge-events.log`
   里 `ams-accts`/`ams-type`（探针已装），确认它查的 identifier 与返回条数。
2. **给 IDMS 账户补凭据**：用 cdpd 成功认证的结果（AKPassword/AKIDMSToken）通过
   `AKAccountManager _saveAccount:` / `ACAccountCredential` 落库，再试媒体登录。
3. **服务账户映射**：`AKAccountManager _matchingServiceAccountForAuthKitAccount:service:`
   对媒体 service 的返回值；缺 iTunesStore 账户是否就是 AMS 的“找不到 IDMS”根因。
4. **keystore/FairPlay 依赖**：若上述都补上仍失败，基本可判定为本 VM 无真 keystore，
   媒体服务（App Store/Music/TV）在此环境下不可达（与 Apple 官方 VM 限制一致）。

---

## 7. 已知坑（必读）

1. **不要把 `App Store`/`appstored`/`cdpd` 加进桥的注入白名单**（完整桥会让 App Store
   「登入」action 直接哑火，点击零日志）。`amsengagementd` 只装只读账户探针。
2. **全局密码补位会被后台 IDMS check-in 吃掉**（曾消费后仍 401）。要补位必须按
   上下文指纹精确门控；目前默认关闭。
3. **autoapply 的上电陷阱**：`/dev/console` 短暂属于 uid 88（windowserver）；必须等真实
   用户（家目录存在 + gui 域可 print）。已修。
4. **`pfctl` 在 `/sbin/pfctl`**，不是 `/usr/sbin`。写错会静默失败（iCloud 又坏）。
5. **新建 AuxiliaryStorage 会黑屏**；克隆必须复制源机的 AuxStorage。
6. **dylib 必须 fresh inode**（rm + mv），否则 `cs_mtime` 不一致 → 加载者被 SIGKILL。
7. **ExtensionKit appex 会清 env**（AppleIDSettings/AKAuthorizationRemoteViewService
   无法注入）；普通 App（如 App Store）会继承域 env——所以白名单要收窄。
8. **iPad helper 不要用 `kickstart -k` 唤醒**（会杀健康 akd，10s 冷启动）；存活即等待。
9. **证书 pinning**：`gsa.apple.com`/`setup.icloud.com` 会拒绝本地 CA，MITM 路线不可行。
10. **VM 网络经 iPad 热点**：热点抖动会断网；登录态已落盘，恢复网络后自愈。

---

## 8. Git / 文档索引

- 本文件：`docs/VM-APPLE-ID-REVIVAL-HANDOFF.md`（复活入口）
- 完整复盘：`docs/VM-APPLE-ID-BREAKTHROUGH.md`（为什么先判死路、如何突破、死胡同）
- 逐小时日志：`docs/WORKLOG.md`（末尾多条 2026-10-24）
- SEP 桥交接：`docs/SEP-BRIDGE-AGENT-HANDOVER.md`
- 顶层速查：`AGENTS.md` §0/§3 + 2026-10-24 条目
- 关键 commit：`8eccd12`、`e6a49ac`、`82bc9c5`、`24e9e52`、`a639158`、`595ec95`

---

## 9. 复活后的第一条命令清单

```sh
cd ~/Desktop/VirtualMacOniPad
git log --oneline -5
sed -n '1,120p' docs/VM-APPLE-ID-REVIVAL-HANDOFF.md

# 1) 确认自动恢复是否生效
tail -3 /var/log/sepbridge-autostart.log
grep -E '"event":"(loaded|fake-nonvm|install-pass)"' /tmp/sepbridge-events.log | tail -3

# 2) 若未生效，手动兜底
sudo /bin/sh /Library/VirtualMac/apply-sep-bridge.sh
# 3) 按 §1 全面验证
```

**给用户的一句话**：iCloud 已跑通且配置可复现；App Store 卡在 AMS 的 IDMS 安全等级
校验（`amsengagementd`），下一步是看 `ams-accts` 探针输出并尝试补齐 IDMS 凭据。
