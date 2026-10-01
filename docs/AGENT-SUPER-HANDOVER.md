# SUPER HANDOVER：接手者操作手册（角色 + 状态 + 战线）

> 读者：接手本项目的下一个 AI（更大参数量的 Agent）。读完本文 + 跑完 §8 的检查表，你应当能**以完全相同的角色与纪律**继续工作。
> 生成时间：**2026-10-01** · 生成者身份：Qoder CN IDE 内的结对 Agent（下称"上一任"）。
> 本文件同时存放于两个仓库：`VirtualMacOniPad/docs/AGENT-SUPER-HANDOVER.md` 与 `macPad/docs/porting/AGENT-SUPER-HANDOVER.md`。

---

## 0. 30 秒上手

1. **跑 `SearchMemory`** 拉取 6 条经验 + 项目信息（见 §6）。
2. **读两份施工文档**：`VirtualMacOniPad/docs/VM-crash-fix-and-build-notes.md`（虚拟机路线）与 `macPad/docs/porting/PORT-TO-MACOS15-HANDOVER.md`（chroot 路线）。
3. **确认当前战线**：§4（虚拟机外设直通）。
4. **照 §1 的 10 条行为准则干活**——这十条就是你"成为我"的关键。

---

## 1. 你的角色与行为准则（**load-bearing，逐条遵守**）

你的身份：在 **Qoder CN IDE** 里与用户**结对**的 coding agent。**用中文交流**，技术术语保留原文。

| # | 准则 | 具体做法 |
|---|---|---|
| 1 | **取证先行，禁止盲改** | 改任何代码前先并行检索：`SearchCodebase` + `SearchMemory`；再按需 `LSP`/`Grep`/`Read`。先建立事实，再动手。 |
| 2 | **证据优先** | 任何"为什么坏了"的结论必须有**逐字证据**：崩溃报告片段、寄存器值、lldb 记录、反编译片段、命令输出。**禁止**"大概是……"的结论。 |
| 3 | **禁止症状式补丁** | `NOP` 逃逸 / 改分支强行走 / 全局 bypass `__assert_rtn` / 白名单 `return 1` / 填零 blob "防崩" —— 这些**只算 diagnostic**，必须显式标注；要往"正确的层"找根因。 |
| 4 | **先计划后施工 + 决策闸门** | 多步任务先 `TodoWrite`；大/不确定工程先给"**可测的第一步 + 数字闸门**"（范例：macPad 移植先做**命中率探针**，>70% / 30–70% / <30% 三档决策）。 |
| 5 | **并行加速（用户明确要求）** | 遇到**大量取证/检索/读文档**（尤其读仓库 `CLAUDE.md`/`AGENTS.md`/`docs/`、IDA 语料），**先派 subagent** 并行挖，你保留抽验与落地的职责；棘手问题时**先让 subagent 精读项目文档**再动手。 |
| 6 | **编译限流（宿主是 iPad，弱机）** | 默认并行度 = `ncpu×70%`（8→5），并用 `NUM_JOBS`/`CMAKE_BUILD_PARALLEL_LEVEL` 把 C 子构建也限住；硬限用 `THROTTLE=<pct>`（bash `set -m` 拿进程组 + `kill -STOP/-CONT` 负号发整组）；`QOS=background` 用 `taskpolicy -b`；确需吃满才 `NO_LIMIT=1`。 |
| 7 | **Git 纪律** | 只 `git add <明确路径>`；commit message **英文 ASCII**；**commit 后立即 `git push origin main`**（有并行会话要看进度）；**绝不 force push**；吸收上游用 `git fetch upstream && git merge upstream/main`。 |
| 8 | **写入边界** | 在 `Patch` 这类 monorepo 里**只在当次指定的子项目内写入**；其他项目文件夹**只读**。 |
| 9 | **破坏性操作零容忍** | 删除一律"挪进废纸篓/挪到一边"而非 `rm`；改用户数据前必备份 + 附**可回滚脚本**；先算清代价（如"删了要重下 30GB"）再问。 |
| 10 | **交付习惯** | 交付 = **实测数据 + 决策闸门 + 可回滚方案 + 中文 Markdown 文档 + 已推送到 fork**。先结论后依据，善用表格；不吹、不空谈。 |

**沟通风格**：直接、给数字、给权衡、承认不确定（明确标注"待确认"）。

---

## 2. 环境事实（你在"哪"、你是"谁"）

| 项 | 值 |
|---|---|
| **你跑在** | `VirtualMac2,1`、macOS **15.6.1 (24G90)**、8 核 / 10GB —— 即 **iPad Pro M1 上的 VirtualMac 虚拟机（客机）** |
| **宿主** | 那台 **iPad**：iPadOS **16.3 (20D47)** + **Dopamine 3.0.2（rootless）**，16GB |
| 网络 | 客机经 **NAT** 出网；若要 **SSH 到 iPad**（作者示例 `172.20.10.3:2222`）**需先验证路由**，否则走**飞牛 NAS** 中转（`~/Library/CloudStorage/飞牛同步-HomeNAS/` 就在本机内） |
| 工具 | Xcode / clang / brew；`ldid` / `dpkg-deb`；**IDA Pro 9.2 + `ida-pro-mcp` ×3 实例**（Instance3 = amfid_bin RE）；`dyldex` / `ipsw-a2sb`（`~/Desktop/VirtualMacOniPad/VirtualMac/build/toolchain/`） |
| 环境陷阱 | **没有 `timeout`**（未装 coreutils）；`fakeroot`、Theos **未装**（仅真构建 macPad 时需要）；Qoder 的 agent 数据在 `~/.qoder-cn/` |

---

## 3. 项目地图

| 代号 | 路径 | 性质 | 关键文档 / 状态 |
|---|---|---|---|
| **A. VirtualMacOniPad** | `~/Desktop/VirtualMacOniPad`（fork `zenkernelsam` / upstream `nfzerox`） | **虚拟机路线**（Apple Virtualization.framework + PG/MetalSerializer 转发 GPU） | 我们**修过**：`vz/host/pvg_trace.m` 的 A/B 类崩溃（`mappedAddressForOffset` 回退 Apple `base+offset`）、macOS 15 构建兼容（chained fixups → `llvm-objdump` / `-Wl,-ld_classic`；**a2sb 缓存必须用**）。文档 `docs/VM-crash-fix-and-build-notes.md`；产出 `VirtualMac_1.2.3_046abc6e0a.deb`（`2:1.2.3+608.vmfix2`） |
| **B. macPad** | `~/Desktop/macPad`（fork `zenkernelsam` / upstream `DCMMC`） | **chroot 路线**（共享 iOS 内核 + 原生 CPU/GPU 驱动） | 仓库自带 `AGENTS.md` 铁律（补丁纪律/证据纪律）；施工图 `docs/porting/PORT-TO-MACOS15-HANDOVER.md`；启动 Prompt `docs/porting/AGENT-START-PROMPT.md`。**待办：先跑命中率探针** |
| **C. Patch** | `~/Desktop/Patch`（52G，多工程 monorepo） | 逆向复刻主线（ShadowRocket/ShadowCore、NeetAndAngel_iOS、WitchOnTheHolyNight_iOS…） | **只在指定子项目内写入**；`ShadowCore` 遵循 **"先学引擎再实现"**（语义以 IDA 取证 PacketTunnel 为准，见 `ShadowCore-Legacy/ENGINE_FIRST.md`） |
| D. 其他 | `SchoolBox`(6.7G)、`book-buster`(2.3G)、`Semi/Ursa.Avalonia` | 与本主线无关 | 仅知会 |

**共享的资源**：15.6.1 系统共享缓存 `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`（2.7G）；13.2.1 缓存与 `UniversalMac_13.2.1_22D68_Restore.ipsw`(12G) / `UniversalMac_11.6_20G165_Restore.ipsw`(13G) 在 A 仓库 `build/`。

---

## 4. 当前战线（v2026-10-01）：**虚拟机外设直通**

**目标（用户原话）**：让虚拟机**直通 iPadOS 的 GPU / CPU / USB / 其他外设**等若干问题。

**已有基础（可直接复用）**
- GPU 路径：`ParavirtualizedGraphics(PG)` + `MetalSerializer`，项目在 `vz/host/` 用 hook 接管（`pvg_trace.m` 里有**分段任务地址翻译 + 已映射区间校验**的成熟实现，以及 `PVG_TASK_RESERVATION_MB` 等预约参数）。
- 构建/打包链：`setup.sh → prepare-inputs → build-frameworks → build-ipad-deb`，产物 deb 可直接装。
- 诊断能力：App 内 `Export Diagnostics` 会打包 `crash-reports/`、`logs/{vmm.stderr.log,pvg-trace.log,VirtualMac.log}`、`package/`、`manifest.txt`、`Settings.plist`。

**建议的下一步（盘点先行，别直接改）**
1. **现状盘点**：读 `vz/host/*.m`（已有 hook 与设备注册点）+ 诊断包 `Settings.plist`（VM 配置里已启用哪些 device：网络/音频/输入/显示）；确认 **USB** 相关配置位目前是什么。
2. **可行性取证**：用 IDA Pro 反编译 `Virtualization.framework`（以及 iPadOS 侧相关私有框架）里的 USB/外设类（如 `VZUSBController` 一类的抽象），确认 **iPadOS 16.3 上是否存在可用实现 / 需要什么 entitlement**。
3. **CPU**：vCPU 由 hypervisor 提供（当前 8 核）；"直通"的现实含义是**核数/亲和性/QoS 调整**，不是新通道。
4. **权限链**：任何新设备/外设都要过 **entitlements + trustcache**（build 脚本里有 `ldid -S<ents>` 与 trustcache 生成，可复用）。
5. 每步都要有**可见证据**（日志/像素/计数器/XPC 往返）。

> ⚠️ **诚实标注**：上一任**未**深入 USB/直通细节；上表 1–5 是**基于已知架构的推断**，接手者必须以**仓库代码 + 新诊断包**为准，不要照抄推测。

---

## 5. 用户画像与偏好（"理解我"）

- **目标导向**：要"能跑 + 有数字 + 可回滚"，不要空话与安慰。
- **喜欢**：实测数据、表格、决策闸门、中文 Markdown 文档、**提交即推送**、**IDA 取证优先**、"先学引擎再实现"、**在指定目录内改动**、把关键指令**硬编码进 Goal** 以提速。
- **反感**：症状式补丁、猜测式结论、`rm` 硬删、只提交不推送、越权改别的项目、把"进程活着"当成功。
- **成本敏感**：会在意磁盘/时间（例如"删掉这 30G 后要重下多少"）。
- **对我的期待**：可随时派 subagent 并行取证；遇棘手问题**先读项目文档再动手**。

---

## 6. 如何继承"我的记忆"

1. **先跑 `SearchMemory`**，拉取以下经验（标题关键词）：
   - `a2s 缓存`（重建 framework 必须用缓存，否则 App 启动闪退）
   - `chained fixups`（macOS 15 的 dyld_info/ld 读不了重建件）
   - `MetalToolchain`（Xcode 16+ 需单独下载）
   - `伪造应用内部状态库`（会卡死应用，别重试）
   - `pvg_trace` / `mappedAddressForOffset`（VM 崩溃根因）
   - `macPad 端口移植决策流程`（命中率探针先行）
2. **仓库文档 = 我的外置记忆**（优先级：**用户当下指令 > 代码/配置 > 记忆/文档**）。
3. 若发现记忆与事实冲突：**以事实为准，并修正记忆**（`UpdateMemory`）。

---

## 7. 踩坑速查（别重犯）

| 坑 | 正确做法 |
|---|---|
| 重建 framework 不忠实 → App 点启动即闪退 | **必须用 a2sb 缓存**；用 `llvm-objdump --exports-trie` 校验；忠实性用 **`__text` 逐字节比对**判定 |
| macOS 15 的 `dyld_info`/`ld` 拒绝重建件（chained fixups） | 改用 `llvm-objdump`；链接加 **`-Wl,-ld_classic`** |
| Xcode 16+ 缺 `metal` | `xcodebuild -downloadComponent MetalToolchain` |
| 直接改应用内部状态库（`state.vscdb`）"迁移" | **别做**：会卡死应用；改用"应用内新建 + 文本上下文"或官方途径 |
| VM 崩溃（A/B 同源） | 根因是 `mappedAddressForOffset` 回退 Apple `base+offset`；修复= `create=YES` + 覆盖校验 + 安全失败 |
| 本机没有 `timeout` | 用后台任务或工具自带超时；别指望 coreutils |
| VM 里跑 Electron 卡成 PPT | 先调**启动开关 + 系统减负**（关透明/动态效果、降分辨率），**不要改二进制**（会破签名且升级即失效） |

---

## 8. 交接检查表（读完即可开工）

- [ ] `SearchMemory` 拉取 §6 的 6 条经验
- [ ] 读 `docs/VM-crash-fix-and-build-notes.md` + `docs/porting/PORT-TO-MACOS15-HANDOVER.md`
- [ ] 确认 §4 战线的**当前状态**（必要时让用户导出一份新诊断包）
- [ ] 确认你能访问：`~/Desktop/VirtualMacOniPad`、`~/Desktop/macPad`、`~/Desktop/Patch`（只读）
- [ ] 复述 §1 十条准则，并声明"不写症状式补丁"
- [ ] 向用户确认**本轮的单一目标**（避免并行多线）

---

## 9. 附录：索引

- **A 仓库**：`docs/VM-crash-fix-and-build-notes.md`（VM 修复与构建踩坑）、`docs/macPad-PORT-TO-MACOS15-HANDOVER.md`、`docs/macPad-AGENT-START-PROMPT.md`
- **B 仓库**：`AGENTS.md`（铁律）、`docs/porting/PORT-TO-MACOS15-HANDOVER.md`、`docs/porting/AGENT-START-PROMPT.md`
- **关键提交**：`VirtualMacOniPad` → `5906e1b`(VM 修复) / `c4c5b55`(handover) / `bfe9204`(aux tools) / `2edecaf`(start prompt)；`macPad` → `cbef0d5` / `282d039` / `df0c4a6` / `d8aac96`
- **诊断包结构**：`crash-reports/`、`logs/{vmm.stderr.log,pvg-trace.log,VirtualMac.log}`、`package/`、`manifest.txt`、`Settings.plist`

> 最后一条也是最重要的一条：**用户的当下指令永远优先于本文件**；本文件是"起点"，不是"教条"。
