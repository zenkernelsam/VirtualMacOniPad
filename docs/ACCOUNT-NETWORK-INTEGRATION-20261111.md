# 2026-11-11：账户、身份界面、热点与上游整合

## 结论与范围

本轮基于本仓库 `39b1708`，合并 netsflex `fd659dd1b5b3574bc61815c5a010b2c52139c366` 的 10 个提交，保留本仓库 GPU 与 SEP 修复。用户确认当前仍运行自己仓库编译的旧版，**尚未安装群友 20261111.2 整合包**。

群友备份的 210 个校验项全部匹配。其已验证成果是独立 Anisette / ADI 机器身份、双端 Octagon Ready、CloudKit 凭据及 23 个 CKKS ready，以及一次真实客机重启。**该备份没有 App Store / Music / TV 系统登录成功证据。** 本轮不能把上述成果或 SDK 的 Store API 等同于系统媒体账户落库。

| 部分 | 本轮改动 | 验证边界 |
|---|---|---|
| 独立身份 | 原生 `independent-identity-provider`，直接用固定版本 SDK，免 Python / 未公开路由插件；联网准备与认证读取分开 | account-free 离线回归、真实 AuthKit secure archive；真实联网准备与登录待验 |
| 现有 SEP 桥 | Anisette 转本地独立身份；设备签名仍由 iPad 原生 SEP 执行；独立状态失败不回退 iPad MID | 传输、头字段保留、类型拒绝回归；宿主签名首启待验 |
| 自动恢复 | Guest Tools 用户登录项发布完整 env；显式 profile 启动自有宿主 helper | 打包 / 编译可验证；原生 iPad akd 的 UID、上下文、注入及新反链须首启验收 |
| 安装 | 验签后 fresh inode 替换，保留旧映射、原代码及可重复 rollback | 真实签名 dylib / mmap / 新进程 / 失败回滚测试 |
| 身份界面 | 显示实际 MID；候选仅预览，克隆实际用所选候选且复制 Aux；CoW 与全量复制空间闸门 | 两架构编译、临时磁盘 CoW / 隔离测试；真实克隆启动待验 |
| 热点 | 保留被 VM 重用的 bridge；partial plist 延后；重写前复查；幂等；声明 Python 依赖 | 15 项离线回归；当前手机 + VM 同时公网访问待验 |
| 上游磁盘写回 | 按 fd 实际 inode / 路径识别；后台持有 dup fd，不误刷复用 fd | 严格 warnings、ASan/UBSan、iOS 编译；性能待验 |

## 独立身份操作与数据边界

在宿主 VM 选项的 Apple Service Adapters 中启用独立身份，然后启动客机。客机 Guest Tools 的 Apple Services Identity 菜单提供「准备独立身份」、打开 Apple Account 设置及关闭适配。准备最多使用 110 秒的独立联网预算；认证请求只读取已准备状态，不在 akd 内启动子进程，也不临时换机器身份。

状态仍保存在 `~/Library/Application Support/VirtualMacIndependentIdentity/`，兼容群友 `vm-state-a` 格式。新 native provider 使用机器 `IOPlatformUUID + uid` 的稳定 hash 绑定。旧无绑定 / 克隆身份保留原样，明确准备时生成另一个身份；不删除旧 ADI、账户数据库、keychain 或个人文件。SDK 与许可证在 `VirtualMac/third-party/apple-auth/`，不包含用户身份或账号令牌。

克隆磁盘必然包含原账号 / ADI 数据。新克隆设置 `AppleServicesIdentityResetRequired=true` 并关闭 profile，只有为当前 UUID 准备的身份可以使用。该 marker 不会在每次启动变化；已准备的匹配绑定可继续复用。真实克隆的首次启动仍需核验，不能把复制 Aux 的历史成功记录当作每一个新候选都已成功。

旧 root `apply-sep-bridge.sh` 改为兼容入口，启动用户 Guest Tools；不再写 root 偏好，不再全局 `pfctl -f`，也不固定改 en0 MTU。既有 MTU / PF 现场状态未被本会话改变。网络兼容策略须有单独证据和可撤销配置，不能继续覆盖用户的全局 PF 规则。

## 宿主签名桥的操作边界

新 helper 与 plist 在 `/var/jb/sepbridge/`，plist 不进入自动 bootstrap 目录。只有显式开启 profile 才由固定 setuid launcher 命令启动自己的 `com.mac.virtual.sepbridge.host` job。该调用使用每次 VM 启动的随机 32 字节 token；guest 请求需鉴权；新反链只在 loopback 接受新协议及核验后的原生 akd PID。guest 端逐个绑定允许接口上的 RFC1918 地址，按接口变化收敛；HTTP 文件服务关闭，不绑定全接口 / 公网作为 fallback，拒绝宿主 erase / sync 身份操作。

现场确认旧自有 `user/501/com.vm.sepbridge` helper PID 420，占用旧端口；新 launcher 仅退役该旧 relay，保留 plist，不停止原生 akd。回退旧服务还需显式重新 enable 该自有 label。

允许的注入对象仅是核验路径、UID、PID 与启动时间后的原生 iPad akd（现场 PID 658、UID 501、路径 `/System/Library/PrivateFrameworks/AuthKit.framework/akd` 已核对）。不得把 macPad 的同名进程当目标，不枚举 guarded fd，不注入 App 或 VMM，不用 `kickstart -k` 重启原生 akd。

关闭 guest 适配撤销后续客机转发，关闭自有 helper 不等于卸载原生 akd 中已经 mmap 的 dylib 或撤销旧 pin。旧 `VMSepBridgeMarker` 已存在时，新库可能未装载：必须看新反链 protocol / PID 证据；不能把 opainject exit 0 当作热升级成功。需要原生 akd 自然重生或用户正常重启后首启验收；本会话未强杀或重启任何 iPad 系统服务。

## 媒体服务：已修的诊断缺陷与剩余闸门

旧记录的逐字错误：

```text
ACAccountStore: Failed to find a corresponding account
accountTypeIdentifier = com.apple.account.idms
ACAccount: Security level check failed to find IDMS account
```

旧 staged password 被后台 IDMS check-in 消费，导致无法验证真正媒体登录。本轮仅修正此**默认关闭的 diagnostic**：必须同时匹配明确 email 与 `com.apple.AppStore` / `com.apple.Music` / `com.apple.TV` 的真实 caller，未知 getter ABI 或 caller 不消费；密码文件还需 owner、0600、regular、单链接、no-follow 检查。profile 不开启 staging，不存密码，不伪造账户、安全等级或成功返回。

当前只读库已有 iCloud 账户，IDMS active/authenticated 为 1；iTunesStore 与 sandbox 各一条 active/authenticated 为 0，均为 `isLocalAccount=true` 的本地占位行。当前 AMS 反汇编证明该错误来自媒体→对应 IDMS 的关联查找（altDSID / DSID / username），而不是该函数直接判断 VM；此前把它当 VM 媒体服务硬限制根因的结论撤回。新静态证据另见 `docs/AMS-MEDIA-ACCOUNT-AUDIT-20261112.md`。

新独立身份准备后，先验证 iCloud 的真实账户 / CloudKit / CKKS 状态；然后分别在三款系统 App 正常登录，读取当前 AMS / IDMS 查询与真实账户行。SDK 会话、库装载、进程存活或「配置就绪」均不算媒体登录成功。不能依据 10 月旧快照宣布 11 月根因已解决。

## 热点根因与本轮修正

主档案：`docs/HOTSPOT-COEXIST-HANDOVER.md`、`docs/WORKLOG.md` 2026-10-07 至 10-09 条目。历史证据在 `.diag/hotspot-20261009*/`。

原根因：jb `vzi.apple.bootpd` 独占 UDP `*.67`，只服务 VM；stock bootpd `runs=0`，手机拿不到租约。历史 PoC 把 stock 热点子网合到运行配置后，手机 `172.20.10.2` 与 VM `192.168.64.2` 同时联网。最终 114 watcher 此前未完整安装验收；手工 `/tmp/bootpd.plist` 改动会被 InternetSharing 重写。

本轮实际修复两个新的退化：旧热点 bridge 名被 VM 重用时误删三个 DHCP 数组中的 VM 接口；运行 plist 正在重写 / 读坏时用空骨架覆盖。离线 red/green 的旧版 12 项中 6 项失败，新版扩充为 15/15 通过；现有 runtime 子网和非 watcher 条目保留，无变化不改原字节 / mtime。

最初 SSH 到 `192.168.64.1:22` 与 `:2222` 超时。用户补充已拔 SIM、iPad 改用 Wi-Fi LAN 后，以 `192.168.68.66` 成功取证；SSH 公钥与旧 iPad 记录一致，未改用户 known_hosts。当前 watcher 已部署，`runs=868`、`last exit code=0`，不能继续断言“没装114”。

2026-11-12 00:31 现场：安装包 `2:1.2.3+224.317567bbc7`，guest `.build=224-6b9c1467accb8a6a`；配置 `NetworkMode=NAT / BridgeInterface=en0`，实际 `bridge100` 成员为 `en0(MACNAT)+vmenet0`。iPad `192.168.68.66/22`、guest `192.168.68.59/22`，运行 bootpd plist 是空子网，stock hotspot plist 不存在。此刻没有蜂窝热点，不能代替 SIM / 热点切换验收。

共享网络头已用于宿主 / guest：不再猜固定网关，HostConfiguration 传实际 iPad 地址，guest 优先同子网；无效 `/0` 或非连续 mask 不抢优先级。实际 iPad 只读原生小探针返回 `relay_addresses=[192.168.68.66]`；实际 injector 探针返回 `trusted_dopamine_injector=1`。探针仅查询文件 / 接口，未触发注入或服务重启。root-owned opainject 正常 alias 通过校验，未知跳转 / 不安全 parent / target 仍拒绝。

复发仍可能包含已经有租约之后的路由 / NAT 状态，不能把每种断网都归为 DHCP。

首启只读取证和闸门：

1. 确认 Python 可执行，watcher job 已加载，实际脚本及两份 bootstrap plist 与本包一致。iPadOS 16 用 `user/501`，当前源码 iPadOS 14 / 15 用 `system`；不要照旧文档硬写所有版本 user/501。
2. 保存切换前、热点开后、手机获租后、热点关后的 ifconfig / route / netstat、两份 bootpd plist、DHCP leases、watcher stderr 与接口计数。
3. 正常热点配置形成后 15 秒内，两子网及对应 DHCP 数组同时存在；关热点只撤 watcher 条目，VM 仍有租约；重复收敛 mtime 不变。
4. 手机关闭蜂窝，纯走 iPad 热点访问公网，同时 VM 公网访问成功。若已获租而不通，再查默认路由、NAT 和计数，不继续重启系统服务。

## 构建、证据、回滚

新构建目录 `.diag/20261111-account-build/`；原始依赖核验、派生构建脚本及缓存列表均记 receipt。缺 Ventura DSC 与 metallib 工具时，只复用逐字未改的 Apple 输入 / 14 Hypervisor / 三个 shader 资源，本轮 App、Guest Tools 与 VMM 兼容源必须重新编译。不得复用旧 iOS App / VMM 冒充新源码。

正式回归在 `VirtualMac/scripts/tests/`：热点、磁盘 fd、独立 provider / client、媒体 context policy 与 payload 安装。`.diag` 保留原始结果但不进 git。完整 ABI 审计在缺 DSC 时明确跳过；离线 / 编译通过不等于宿主首启或长期稳定性。

安装前正常关闭 VM，保留当前可启动旧 deb。新 Guest Tools 的安装输出含 `.VirtualMac-install.*/rollback.sh`，旧代码保留，rollback 可重复执行；它恢复代码，不回退 / 删除账号数据库或独立身份。真实宿主 / 客机部署、iCloud 登录、三种媒体服务以及热点共存均需单独验收。本会话未安装 deb、操作 VM 磁盘或重启设备。


## 最终联网抽验（2026-11-12）

使用本轮相同生产代码、独立 `.diag` 私有临时状态，真实向 Apple 完成 account-free provisioning：lookup、MidService/startMachineProvisioning、MidService/finishMachineProvisioning 三次均 HTTPS 200。完成耗时 **2.576 秒**，随后再次准备及离线 payload 读取验证 identity.json 逐字不变、真实 AKAnisetteData secure archive 存在。**没有登录账号，也没有读取账号密码**。测试状态未进入用户正式身份目录或安装包。

真实联网修正了此前错误的 GsService2/start 路径限制，采用 Apple lookup 实际返回的 MidService/start 与 finish 路径；新增请求阶段/HTTP状态错误码日志，不记录 headers、body、MID或令牌。离线模拟测试仍用同一生产过滤器。

源码合并 `b023599` 已推送 main，主仓库Git已无损同步；首次包抽验发现旧 launcher.previous 混入（仅生成物备份），已移动到构建 archive，旧包标为失败不交付。最终包必须核验没有备份 / 个人状态再交付。
