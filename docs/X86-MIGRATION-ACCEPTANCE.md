# X86-MIGRATION-ACCEPTANCE.md — x86 黑苹果迁移验收清单

> **给 x86 侧的接手 agent**：本文档定义"迁移成功"的判定标准与证据要求。
> 阅读顺序：`AGENTS.md`（行为准则+环境事实）→ 根目录 `X86-MIGRATION.md`（排除项+重下清单）→ 本文件。
> 验收结果追加到 `docs/WORKLOG.md`（日期+各 L 级通过/失败+逐字证据），然后 commit + push。

## 迁移包信息（对不上的先停下来找用户）

| 项 | 值 |
|---|---|
| 文件 | `VirtualMacOniPad-x86-migration-20261021.tar.zst`（飞牛 `VirtualMacOniPad_iOS/`) |
| 大小 | 5,877,495,913 bytes |
| SHA256 | `3af505c07441151f7407b76547784ae19efb1d097c8a0b5cfb033bde84a15c79` |
| 解压后 | 11,039,825,920 bytes,~26,000 条目 |
| 打包时点 commit | `a9a804c`；后续 commit（含 `f6a11d0`、本文档）经 `git pull` 获取 |

⚠️ `.diag/`、`VMGPU/`、`VirtualMac/build/`（含 `build/inputs`、`build/release`、`toolchain`）、`.env` **全部 gitignored**——它们只存在于压缩包里。**纯 `git clone` 不算迁移**，丢了这些等于丢了取证档案与全部提取件。

## L0 仓库与压缩包完整性

- [ ] `zstd -t` 通过；解压后 `git -C VirtualMacOniPad log --oneline -3` 有正常历史
- [ ] `git pull` 后 `git status` 干净（≥`f6a11d0` 时 probe 二进制与 X86-MIGRATION.md 已是 tracked，应无 modified/untracked)
- [ ] 必查路径存在（缺一即失败）:

| 路径 | 锚点 |
|---|---|
| `.diag/` | ~7GB、上百个取证目录 |
| `VMGPU/` | ~178MB 黄金基线（**只读**) |
| `VirtualMac/build/inputs/macos11/20G165__MacOS/dyld_shared_cache_arm64e` | ~2.2GB |
| `VirtualMac/build/toolchain/ipsw-src/` | blacktop/ipsw 检出 @`b7229017` |
| `VirtualMac/build/release/` | 3 个 `.deb` |
| `docs/WORKLOG.md` | 进度日志，压缩后从这里恢复 |
| `X86-MIGRATION.md` | 重下清单 |

- [ ] 反向检查：`VirtualMac/build/downloads/`、`VirtualMac/build/toolchain/{bin,venv}` **不应存在**（排除生效；若之后出现则是重建/重下的产物，正常）
- [ ] `file` 抽查：`VirtualMac/build/release/*.deb` 内解出的 dylib 为 arm64/arm64e —— 是**目标产物**，正常；宿主可执行物才看架构

## L1 宿主环境

- [ ] `uname -m` = `x86_64`；记录黑苹果 macOS 版本进 WORKLOG
- [ ] `xcodebuild -version`、`clang --version` 正常（arm64 target 交叉编译不受影响）
- [ ] brew 前缀 `/usr/local`(Intel);`brew bundle --file=VirtualMac/Brewfile` 全部装上
- [ ] `brew list --versions ldid-procursus` 存在 —— **必须是 procursus 版 ldid**，普通 ldid 的双 CodeDirectory 签名会被 iPadOS 拒（`bootstrap.sh` 已处理，别手动改装）
- [ ] `go version` 满足 `toolchain/ipsw-src/go.mod`
- [ ] ⚠️ x86 **无 Rosetta**：任何 `Bad CPU type in executable` = 漏网 arm64 宿主二进制，`file` 确认后按 L2 重建

## L2 工具链重建（`VirtualMac/scripts/bootstrap.sh` 一把梭）

- [ ] `./scripts/bootstrap.sh` exit 0，末尾打印 `toolchain ready`
- [ ] `file VirtualMac/build/toolchain/bin/ipsw-a2sb` = `Mach-O 64-bit executable **x86_64**`
- [ ] `VirtualMac/build/toolchain/bin/ipsw-a2sb dyld a2sb --help` 正常（本地 a2sb 子命令生效）
- [ ] `VirtualMac/build/toolchain/venv/bin/dyldex --help` 正常
- [ ] 补丁生效：`grep -l _buildLocalProtocolMap venv/.../DyldExtractor/converter/objc_fixer.py`
- [ ] 交叉编译冒烟：`clang -arch arm64 -framework Metal -framework IOKit -o /tmp/mtl-caps-dump vz/development/probes/mtl-caps-dump.m` 产出 arm64 Mach-O（宿主跑不了属正常，能编即过）

## L3 资源重下（按 `X86-MIGRATION.md` §2)

- [ ] 每个重下文件 `shasum -a 256` 与表格**逐字**一致，放入 `build/downloads/`
- [ ] 决策闸门：`build/inputs/` 已验收存在 → `UniversalMac_13.2.1_22D68` 可暂缓；只有重新提取 DSC/框架时才必须下
- [ ] 13.4.1 的 SHA256 以 `X86-MIGRATION.md` 表格为准（setup.sh 未收录它）

## L4 端到端构建（强验收，可在 L0-L3 全过后做）

- [ ] `./setup.sh`（或等价脚本）走完 payload 提取→打包，产出 `.deb`
- [ ] `dpkg-deb -I 产出.deb` 结构正常；包内 `OpenGLPVGCompat.dylib` 为 universal/arm64e 切片齐全
- [ ] 不要求与历史 deb 位级一致（构建含时间戳）；要求结构、签名、entitlement 校验通过

## L5 协作面连通

- [ ] `git fetch origin` 通；推一个 WORKLOG 小 commit 实测 `git push` 通
- [ ] ⚠️ **iPad SSH 地址已变**:`192.168.64.1` 是那台 VM 的 NAT 网关，只在 VM 内部有效。x86 在局域网里要用 iPad 的真实 IP——**问用户**，别猜（22/2222 都通，密码问用户）
- [ ] 飞牛 NAS 挂载点确认（黑苹果上路径大概率不再是 `~/Library/CloudStorage/飞牛同步-HomeNAS`)
- [ ] IDA Pro x86 版 + ida-pro-mcp 按需重装

## 不算迁移成功的反例

- 只 `git clone` 了云端仓库，没有 `.diag`/`VMGPU`/`build/inputs` → 取证档案丢失
- `ipsw-a2sb`/`dyldex` 跑不起来，或 dyldextractor 补丁没打上
- `git status` 一片 modified/untracked 异常 → 解压损坏，重解
- 用普通 `ldid` 顶替 ldid-procursus
- 拿别处拷来的 arm64 宿主二进制硬跑（`Bad CPU type`)

## 完工要求

在 `docs/WORKLOG.md` 追加一条：验收日期、L0–L5 各项结果（失败项写明原因）、关键命令输出的逐字证据（SHA256、`file`、`--version` 等），commit + push origin main。
