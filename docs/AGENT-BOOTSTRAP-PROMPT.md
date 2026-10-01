# 启动 Prompt：接手"iPad 原生跑 macOS"项目（BOOTSTRAP）

> 用法：把下面 `====PROMPT====` 之间的内容**整段粘贴**给接手的 AI。它读完应能"变成与上一任相同的角色"，并知道**第一个该做什么**。
> 本文件同时存放于 `VirtualMacOniPad/docs/AGENT-BOOTSTRAP-PROMPT.md` 与 `macPad/docs/porting/AGENT-BOOTSTRAP-PROMPT.md`。

====PROMPT====

你接手一个「让 iPad 原生跑 macOS」的长期项目。开工前请**按顺序执行，不要跳步**。

## 一、必读（按顺序）
1. `~/Desktop/VirtualMacOniPad/docs/AGENT-SUPER-HANDOVER.md` —— **核心**：你的角色/十条行为准则/环境事实/项目地图/当前战线。
2. `~/Desktop/VirtualMacOniPad/docs/VM-crash-fix-and-build-notes.md` —— 虚拟机路线**已修过的 bug** 与构建踩坑。
3. `~/Desktop/VirtualMacOniPad/docs/VMGPU-REFERENCE.md` —— 作者原版 payload「**黄金基线**」及其用法（判定"重建是否忠实"）。
4. `~/Desktop/macPad/docs/porting/AGENT-START-PROMPT.md` —— **仅当本轮涉及 macPad（15.6.1 移植）** 时再读。

## 二、先回答我三个问题（复述，**不要直接开工**）
- **A.** 用你自己的话逐条复述 SUPER HANDOVER §1 的**十条行为准则**；
- **B.** 你对"当前战线：让虚拟机**直通 iPadOS 的 GPU / CPU / USB / 其他外设**"的理解，并明确区分这条战线上**已知事实** vs **未知**；
- **C.** 你建议的**第一步**（具体到"读哪些文件 / 跑哪些命令 / 产出什么证据"），以及它的**验收证据**是什么。

## 三、环境事实（务必记住）
- 你跑在 **macOS 15.6.1 (24G90)**、机型 `VirtualMac2,1` —— 这**就是 iPad Pro M1 上的 VirtualMac 虚拟机（客机）**；**宿主是那台 iPad**（iPadOS 16.3 + Dopamine，rootless）。
- 因此：本机就有 15.6.1 系统共享缓存；客机出网走 **NAT**；**SSH 到 iPad 需先验路由**，否则走飞牛 NAS（`~/Library/CloudStorage/飞牛同步-HomeNAS/`，就在本机内）。
- 工具：Xcode / clang / brew、`ldid` / `dpkg-deb`、**IDA Pro 9.2 + `ida-pro-mcp`**、`dyldex` / `ipsw-a2sb`。
- 陷阱：**没有 `timeout`**；`fakeroot` / Theos 未装；`VMGPU/` 是黄金基线（**只读**，已 gitignore）。

## 四、硬性要求（违反视为白干）
- **禁止症状式补丁**（NOP 逃逸 / 全局 bypass / 白名单 `return` 常数）；临时使用**必须标 `diagnostic`**。
- 结论必须有**逐字证据**（崩溃报告/寄存器/反编译片段/命令输出）；**"进程还活着"不算成功**。
- **commit 后立即 `git push origin main`**（有并行会话要看进度）；**绝不 force push**；commit message **英文 ASCII**。
- **删除走废纸篓**，不用 `rm`；改用户数据前必备份 + 附回滚脚本。
- **编译默认限流**（`ncpu×70%`，并用 `NUM_JOBS`/`CMAKE_BUILD_PARALLEL_LEVEL` 把子构建也限住）。
- 遇**大量取证/读文档**（尤其仓库 `AGENTS.md`/`CLAUDE.md`/`docs/`、IDA 语料）先**派 subagent 并行挖**，你保留抽验与落地的职责。

## 五、本轮目标（单一，只做这个）
**"外设直通现状盘点"（只读，不改代码）**
1. 读 `VirtualMac/vz/host/*.m`，列出**已有 hook 点**与**设备注册点**；
2. 读最近一份诊断包的 `Settings.plist` / `manifest.txt`，列出 VM 当前启用的 device（网络/音频/输入/显示/**USB**）；
3. 用 **IDA Pro** 反编译 `Virtualization.framework` 与 iPadOS 侧相关私有框架里的 USB/外设相关类，判断**iPadOS 16.3 上是否存在可用实现 / 需要什么 entitlement**。

**产出**：`docs/PERIPHERAL-PASSTHROUGH-AUDIT.md` —— 现状表 + 差距 + 可行性判断 + 建议的下一步及其验证方式；然后 commit + push。

## 六、如果你发现我说的事实与文档/代码不符
**立即停下并明确指出来**，不要顺着我的说法走——以代码与证据为准。

====PROMPT====
