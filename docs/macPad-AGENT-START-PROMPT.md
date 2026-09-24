# 启动 Prompt：把 macPad 移植到 macOS 15.6.1（交给接手的 AI）

> 用法：把下面 `====PROMPT====` 之间的内容**整段粘贴**给接手的 AI（SWE-2 / Kimi K3 增强版等）。本文件本身也已加入仓库，便于双方引用。

====PROMPT====

**任务：把 macPad 的 macOS 13.4 硬编码补丁移植到 macOS 15.6.1。第一步只做"命中率探针"，用数字决定是否开工。**

## 0. 先读（按顺序，别跳）
1. 本仓 `docs/porting/PORT-TO-MACOS15-HANDOVER.md` —— **施工图**：实测清单（28 条签名 / 66 处 memcmp / 12 个 UUID 闸门 / 48 个目标二进制）、探针命令、施工顺序、验收标准、工期决定点、IDA 逆向清单（§7）。
2. 本仓 `AGENTS.md` —— **补丁纪律 + 证据纪律（load-bearing，先读再动手）**。
3. 同机另一仓库 `~/Desktop/VirtualMacOniPad`：`docs/macPad-PORT-TO-MACOS15-HANDOVER.md`（同内容）、`docs/VM-crash-fix-and-build-notes.md`（了解本机来历）。

## 1. 你的运行环境（关键事实，别搞错）
- 你跑在 **macOS 15.6.1（24G90）**、机型 `VirtualMac2,1` —— 这是 **iPad Pro M1（iPadOS 16.3 + Dopamine，rootless）上的 VirtualMac 虚拟机**；**宿主就是那台 iPad**。
- 因此 **15.6.1 的系统共享缓存就在本机**，可直接用于探针：
  `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`（2.7G）
  对照基线（13.2.1）：`~/Desktop/VirtualMacOniPad/VirtualMac/build/inputs/macos/22D68__MacOS/dyld_shared_cache_arm64e`（1.6G）
- 工具：Xcode/clang ✅、`ldid`/`dpkg-deb` ✅、**IDA Pro 9.2 + `ida-pro-mcp`** ✅、`dyldex`/`ipsw-a2sb`（见 handover §8）。
- 环境陷阱：**本机没有 `timeout`**（未装 coreutils）；`fakeroot`、Theos **未装**（只在真正构建 macPad 时才需要）。

## 2. 第一步（只做这个：约 30 分钟，纯本机，不碰 iPad）
执行 handover **§3 的命中率探针**：从 **15.6.1 与 13.2.1 两套共享缓存**里抽出同一批目标镜像
（`Metal`、`QuartzCore`、`IOKit`、`IOGPU`、`SkyLight`、`AGXCompilerCore`；AGX bundle 在磁盘上有，直接读）
- ① 用 `dwarfdump --uuid` 对照源码里的 **12 个 UUID 闸门**（handover §1.3）；
- ② 用 handover §1.2 的 **28 条字节签名**逐条扫描命中；
- ③ 把结果落成 **`docs/porting/hit-rate-table.md`**（或 `.tsv`）。

## 3. 然后严格按 handover §6 的决定点行动（不要越级开干）
| 15.6.1 命中率 | 行动 |
|---|---|
| >70% | 值得**全量 port**（约 3–7 天） |
| 30–70% | 只做 **MVB（最小可启动）+ 簇 A/B**（约 1–2 周） |
| <30% | **放弃 15.6.1**，改用作者验证过的 **macOS 13.4 rootfs** |

## 4. 纪律（违反等于白干）
- **禁止症状式补丁**（`NOP` 逃逸 / 改分支强行走 / 全局 bypass `__assert_rtn` / 白名单 `return 1`）；若临时使用，**必须标注 `diagnostic`**。
- 每个"为什么坏了"的结论必须有**逐字证据**（崩溃报告/寄存器/lldb 记录/反编译片段）。
- 验收看**可见输出 / 计数器前进 / XPC 往返成功**，**不是**"进程还活着"。
- **台账先行**：每条补丁一行
  `目标镜像 | 符号/函数 | 15.6.1 地址 | 新签名(hex) | 语义依据(decompile 片段) | 动作 | 状态` → `docs/porting/patch-ledger.tsv`。

## 5. Git 纪律
- 每完成一步：`git add <明确路径>` → commit（**英文 ASCII**）→ **立即 `git push origin main`**（有并行会话要看进度）。
- **绝不 force push**；需要吸收上游时先 `git fetch upstream && git merge upstream/main`。
- 本仓：fork = `zenkernelsam/macPad`（origin），upstream = `DCMMC/macPad`。

## 6. 明确不要做
- 不要重写 `state.vscdb` 或伪造应用内部状态（**历史教训**：会让 Qoder 界面卡死并拖垮虚拟机）。
- **不要在拿到探针数字之前大改 `mac_hooks.m`**——很可能白干。
- 不要在 **15.6.1 rootfs 未验证**的前提下假设"能顺利挂起来"（这是与补丁并列的第二条风险线）。
- 别忘了**第二条 port 轴**：README 说测于 iPadOS **16.3**，而 AGENTS.md 写 "hardcoded for iOS **16.5**" —— 先确认 iOS 侧签名是按哪个版本推的。

## 7. 交付物
1. `docs/porting/hit-rate-table.md`（探针结果，含原始命令与输出）；
2. `docs/porting/patch-ledger.tsv`（台账，含 15.6.1 新签名）；
3. 按 §3 决定点产出的结论：**MVB 可启动的证据**（像素/日志/计数器）**或**「建议退回 13.4」的数据化结论。

====PROMPT====
