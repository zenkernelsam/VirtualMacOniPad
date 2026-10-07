# Handover：修复越狱状态下 Personal Hotspot DHCP 死锁（热点/VM NAT 共存）

> 交接对象：负责 VirtualMac 打包的 Agent。基线 commit `3fa6b5e3d816ec78d0d0bd2701a1ca5864babf1f`（即 `VirtualMac_1.2.3_3fa6b5e3d8.deb` 同源）。本文档 = 完整诊断 + 已在真机上验证通过的修复设计 + 施工/验收清单。
> 写作日期：2026-10-07。环境：iPad Pro 11" M1，iPadOS 16.3 (20D47)，Dopamine 3.0.2 rootless，SSH `ssh -p 22 root@192.168.64.1`（2222 亦通，凭据问用户）。

## 1. 症状（用户实测）

越狱后热点即废：手机点 iPad 热点后一直转圈，iPad 右上角热点绿标亮起（802.11 关联成功），但手机永远拿不到 IP → 自分配 169.254.x → 无网络。**不越狱时热点正常；越狱后哪怕从没打开过 VM 也一样坏。**

## 2. 根因（已实锤，不是猜测）

**`vzi.apple.bootpd`（项目部署的 jb DHCP 服务）在越狱 bootstrap 时就由 launchd 独占绑定 UDP `*.67` (bootps)，且其配置 `/tmp/bootpd.plist` 只含 bridge100(192.168.64.x) 子网。** iOS 热点的 DHCP 由 `misd` 按需提交 `com.apple.bootpd`（同样要 bootps/67）——端口被占，这个 job 永远无法 spawn，热点客户端拿不到租约。

机制链证据（逐字，2026-10-07 采集）：

| 事实 | 证据 |
|---|---|
| jb bootpd job 声明 socket=bootps/IPv4/dgram，inetd 模式 | `/var/jb/Library/LaunchDaemons/com.apple.bootpd.plist`（Label=`vzi.apple.bootpd`，Program=`/var/jb/usr/libexec/bootpd`，`Disabled=false`） |
| launchd 加载即绑端口，与 VM 是否运行无关 | `netstat -an -f inet` 只有一个 `udp4 *.67`；`launchctl print user/501/vzi.apple.bootpd`：`state=running, runs=26, immediate reason=ipc (socket)` |
| misd 提交的 stock bootpd 同样要 bootps，但从未运行 | `launchctl print user/501/com.apple.bootpd`：`type=Submitted, path=(submitted by misd[35012]), sockets.Listeners service name=bootps family=ipv4, runs=0, last exit code=(never exited)` |
| 热点侧其余环节完好 | `bridge101` 已建、成员 `ap1`、`inet 172.20.10.1/28`；`hostapd` PID 在跑；`misd` PID 35012 正常 |
| misd 写的热点配置完全正确 | `/Library/Preferences/SystemConfiguration/bootpd.plist`（12:49 刚写）：Subnets 含 bridge101/`172.20.10.0/28`/router+DNS=`172.20.10.1`，dhcp_enabled=bridge101 |
| 客户端 DHCP 失败的落地痕迹 | 路由表 `169.254.85.9 ... bridge101`（手机自分配 link-local）；`/var/db/dhcpd_leases` 里 172.20.10.x 全是越狱前的历史租约 |
| 代码出处 | `vz/patches/patch_internet_sharing.py`（把 InternetSharing 的 bootpd 标签改成 `vzi.apple.bootpd`、配置路径改 `/tmp/bootpd.plist`）；`vz/patches/patch_ipados14_bootpd.py`（bootpd 读 `/tmp/bootpd.plist`）；`packaging/DEBIAN/postinst` iPadOS15/16 分支（~L350-358）**无条件** `enable`+`bootstrap` vzi job——iPadOS14 的按需启停 `bootpd-controller` 没有移植到 15/16 |

**为什么"没开 VM 也坏"**：`/var/jb/Library/LaunchDaemons/*.plist` 在越狱时被 Dopamine bootstrap，`vzi.apple.bootpd` 的 socket 在**加载瞬间**绑定，与 VM 运行状态完全解耦。

## 3. 已验证的 PoC（方案 B 共存，端到端通过）

在 VM 运行中，向 `/tmp/bootpd.plist` 手工追加一个 bridge101 子网项（内容见 §4.2），**没有重启任何服务**。随后手机重新加入热点：

- 手机获租约 **`172.20.10.2`**（落在 172.20.10.2–.14 池内）；
- 手机关蜂窝、纯走 iPad 热点，访问 ip.sb 成功，出口公网 IP `104.28.83.101` → **misd 的 NAT/转发链路完全正常，无第二处冲突**；
- VM 同时在线（本次会话本身就是 VM 内跑的）。

结论：**只需让 jb bootpd 的配置同时覆盖 bridge101，即可与热点共存。** 不需要抢占/释放端口，不需要动 misd，不动 stock 文件。

⚠️ 当前 iPad 上 `/tmp/bootpd.plist` 留有我手工注入的 bridge101 条目（`_creator=vzi-hotspot-compat`）——这就是热点现在能用的原因。它会被 InternetSharing 在下次 VM 网络变化时整文件重写而丢失；正式修复落地前属临时态。备份在 `/tmp/bootpd.plist.bak`。

## 4. 修复设计：bootpd 配置合并 watcher

### 4.1 新 launchd job `vzi.apple.bootpd-hotspot-merge`

- 域：**user/501**（与现有 vzi.bootpd / NetworkSharing 在 iPadOS15/16 的部署域一致；见 `postinst` `network_domain` 逻辑）。
- `ProgramArguments`: `/bin/sh /var/jb/usr/libexec/VirtualMac/bootpd-hotspot-merge.sh`
- `RunAtLoad=true`（越狱 bootstrap 时立即收敛一次状态）
- `WatchPaths`: 
  - `/tmp/bootpd.plist` —— InternetSharing 每次 VM 网络 attach/detach 会重写，必须在它写完后重新合并
  - `/Library/Preferences/SystemConfiguration/bootpd.plist` —— misd 在热点开/关时写/删
- `ProcessType=Interactive`、`StandardOutPath/StandardErrorPath` 指到 `/tmp/` 便于调试。
- **幂等要求（硬性）**：脚本在内容已正确时不得写文件，否则 WatchPaths 自触发形成空转写循环（跑一次 → 无变化不写 → 收敛，是安全的；每次跑都重写文件也是安全的，但白白消耗；做成"先比对再写"）。

### 4.2 合并脚本语义（参考逻辑，sh+awk 实现）

检测与动作：

```
hotspot_active = ifconfig bridge101 存在且含 "inet 172.20.10.1"
                 （或更通用地取 ifconfig bridge101 的 inet 地址；
                   stock plist /Library/Preferences/SystemConfiguration/bootpd.plist
                   里 misd 写的 dhcp_enabled 含 bridge101 可作辅助判据）

if hotspot_active:
    确保 /tmp/bootpd.plist 中存在：
      - Subnets[] 里 interface=bridge101 的子网 dict
      - dhcp_enabled / detect_other_dhcp_server / ignore_allow_deny 各含 bridge101
    若 /tmp/bootpd.plist 不存在（VM 从未跑过/被清）：创建骨架文件，只含 bridge101 项
else:
    若 /tmp/bootpd.plist 存在且含 bridge101：剥掉 bridge101 的 dict 与三个数组里的条目
      （热点关闭后留着一个不存在接口的子网项无害，但清理干净更稳）
```

**已实测可用的静态子网块**（直接粘贴级，2026-10-07 实测手机获 172.20.10.2）：

```xml
<dict>
    <key>_creator</key>
    <string>vzi-hotspot-compat</string>
    <key>allocate</key>
    <true/>
    <key>dhcp_domain_name_server</key>
    <array>
        <string>172.20.10.1</string>
    </array>
    <key>dhcp_router</key>
    <string>172.20.10.1</string>
    <key>interface</key>
    <string>bridge101</string>
    <key>lease_max</key>
    <integer>86400</integer>
    <key>lease_min</key>
    <integer>86400</integer>
    <key>name</key>
    <string>172.20.10.1/28</string>
    <key>net_address</key>
    <string>172.20.10.0</string>
    <key>net_mask</key>
    <string>255.255.255.240</string>
    <key>net_range</key>
    <array>
        <string>172.20.10.2</string>
        <string>172.20.10.14</string>
    </array>
</dict>
```

v1 可直接用此静态块（iOS 热点网段多年恒为 172.20.10.0/28）。更稳的 v1.1：从 stock plist 的 `Subnets` 里抽取含 `bridge101` 的 dict 原样合并，保留 carrier/Apple 未来变更的数值。

环境注意（实测）：stock iPadOS `/usr/bin` 仅约 25 个二进制，**没有 ifconfig/awk/sed/plutil/grep/python 于系统路径**；全部工具在 `/var/jb` 前缀。脚本开头必须 `export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/sbin:/usr/sbin:/bin:/usr/bin`。iPadOS 16.3 的 `plutil -insert` 有坑（打印结果但不落盘、exit 0），**不要用 plutil 修改 plist，用 awk 文本处理 + 写临时文件 + mv 原子替换**。

### 4.3 端口行为（不用改）

`vzi.apple.bootpd` 维持现状：常驻 enable、`*.67` 常绑。jb bootpd 按 inetd 模式逐包 spawn、每次启动重读 `/tmp/bootpd.plist`（`runs=26` 佐证），配置合并后**下一次 DHCPDISCOVER 即生效**，无需重启任何守护进程。misd 提交的 `com.apple.bootpd` 永远起不来（无害，被动 job）。

## 5. 需要动的文件（锚点以 commit 3fa6b5e3d8 为准）

| 文件 | 动作 |
|---|---|
| `VirtualMac/packaging/rootless/` 或就近目录 | 新增 `bootpd-hotspot-merge.sh`（上节语义）+ `vzi.apple.bootpd-hotspot-merge.plist`（上节 job 定义） |
| `VirtualMac/scripts/build-ipad-deb.sh` ~L127-138 | 把两个新文件 install 进 `$STAGE/var/jb/Library/LaunchDaemons/`（plist，644）和 `$STAGE/var/jb/usr/libexec/VirtualMac/`（脚本，755，目录需新建）。是否同步进 `var/jb/basebin/LaunchDaemons/`（Dopamine userspace-reboot 自举面）——参考 L129-138 对 NetworkSharing 的做法，**建议同步**，保证 respring 后不用重装包也生效 |
| `VirtualMac/packaging/DEBIAN/postinst` ~L319-358 | 顶部 bootout 循环加 `vzi.apple.bootpd-hotspot-merge`；iPadOS15/16 else 分支里 bootstrap 新 plist 到 `user/501`。iPadOS14 分支也建议 bootstrap（system 域）——14 的 controller 模式下 VM 关闭时 67 释放、热点走 stock；VM 开着时合并文件让 jb bootpd 顺带服务热点，行为同样改善，无回退风险 |
| `VirtualMac/packaging/DEBIAN/prerm` ~L21-28 | bootout 循环加新 label |
| （可选）`scripts/install-ipad-deb.sh` / 审计脚本 | 若存在文件清单/审计断言，加新文件 |

不需要改的：`bootpd`/`InternetSharing` 二进制、现有两个 plist、`trustcache.txt`（sh+plist 不是 Mach-O，不进 trustcache）。

## 6. 验收清单（iPad 实测）

1. 装新 deb（正常关闭 VM 先）。`launchctl print user/501/vzi.apple.bootpd-hotspot-merge` 应为 loaded。
2. **VM 运行中**开热点，手机重连：应获 `172.20.10.x`，蜂窝关后能用 iPad 网络上网（复测 ip.sb）。
3. **关 VM 后**开热点重连：同样应获租约+上网（此场景检验"文件不存在时创建骨架"分支）。
4. VM guest DHCP 回归：客机 `ipconfig getpacket en0` 仍有 192.168.64.x 租约。
5. 关热点 → `/tmp/bootpd.plist` 中 bridge101 条目被剥除；再开 → 重新出现。
6. userspace reboot / 重新越狱：job 自举，热点仍可用（验证 basebin/Library 双投递是否必要）。
7. 幂等性：连续多次触发 WatchPaths，`/tmp/bootpd.plist` 不应被无意义重写（看 mtime 与 stderr 日志）。

## 7. 回滚

- 包级：`prerm` 已 bootout 新 label；装回旧 deb 即恢复原行为（热点复坏，无其他副作用）。
- 手动应急：`launchctl bootout user/501/vzi.apple.bootpd-hotspot-merge` + 删 plist/脚本；`vzi.apple.bootpd` 本体不受影响，VM NAT 不回退。

## 8. 遗留问题（不属于本次修复，但记录在案）

- 若将来要"stock bootpd 服务 VM"这条路：不可行，stock iPadOS bootpd 沙箱看不到 `/var/db/dhcpd_leases`（patch 注释已载明），这正是当初做 jb 副本的原因。
- iPadOS 14 rootful 路径已有 `bootpd-controller` 做按需启停；本修复与它正交、可共存。
- misd 对 `com.apple.bootpd` spawn 失败是否上报警告/回退——未验证（iPadOS 无 `log` 命令，统一日志不可取），但实测全链路工作，属无害噪音。
