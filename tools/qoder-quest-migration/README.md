> ## ⛔ 【已废弃】注入路线不可行，请勿重试
>
> 2026-09-20 实测：伪造写入 `state.vscdb` 的 `aicoding.questTaskListSnapshot`，
> 并伪造 `conversation-history` / `experts` 目录 —— **试点任务不显示、Quest 界面严重卡死、
> 最终拖垮整个虚拟机**。已按预案完整回滚（`ROLLBACK COMPLETE`），各项核验干净。
>
> **不要再运行 `run-migration.sh pilot|rest`；不要手写 `state.vscdb`；不要伪造会话目录。**
> 现改用**降级方案**：在 Quest 里正常新建任务，粘贴
> `~/Desktop/QoderCN-Quest-导出/<taskId>/paste-context.md`（由 `make_paste_pack.py` 生成）。
>
> 以下内容作为**历史记录**保留（含回滚机制），仅供理解存储结构。

# Qoder CN → Qoder CN IDE Quest（历史方案记录：注入路线已废弃）

把**独立版** `Qoder CN.app` 的 Quest 任务，导入到 **`Qoder CN IDE.app` 的 Quest**（同一工作区下可见）。

- 源归档：`~/Desktop/QoderCN-Quest-导出/<taskId>/{readable.md, ide-history.jsonl, plan/}`
- 目标工作区：`/Users/ciscohe/Desktop/Patch`（slug `Patch-5ea91c46`，已存在）
- 3 个任务：`0766d3fa…`(试点) / `88d0cabd…` / `8d9eedd7…`

> 原理（已实测）：IDE 的 Quest 任务列表在 `state.vscdb` 的 `aicoding.questTaskListSnapshot`；
> 会话历史在 `~/.qoder-cn/cache/projects/<slug>/conversation-history/<id8>/<id8>.jsonl`，
> 其中 **`id8` = 会话 id 的前 8 个字符**；运行时在 `~/.qoder-cn/cache/experts/<taskId>.session.execution/`。

---

## 步骤 1 — 备份（**必须退出两个 App**）

```bash
cd /Users/ciscohe/Desktop/VirtualMacOniPad/tools/qoder-quest-migration
bash backup.sh
# 记下输出的备份路径，例如 ~/Desktop/QoderCN-Migration-Backup-20260920-140000
```

校验备份（可选）：`ls -la <备份目录>; tail -3 <备份目录>/BACKUP-MANIFEST.txt`

## 步骤 2 — 试点导入（最小任务 `0766d3fa…`）

```bash
cd /Users/ciscohe/Desktop/VirtualMacOniPad/tools/qoder-quest-migration
python3 migrate_quest.py \
  --history "$HOME/Desktop/QoderCN-Quest-导出/0766d3fa-7bbd-4723-9bf9-99264d4891aa/ide-history.jsonl" \
  --folder  "/Users/ciscohe/Desktop/Patch" \
  --slug    "Patch-5ea91c46" \
  --title   "CN迁移: ShadowCore 上下文恢复" \
  --query   "读 ShadowRocket/ShadowCore/SUPER_HANDOVER.md 并据此恢复上下文"
```

脚本会打印新 `task-<hex>`、历史路径、会话路径；并在**当前目录**留下
`snapshot.before.json`（撤销列表用）与 `fabricated-tasks.txt`（回滚用）。

## 步骤 3 — 启动 App 验证

打开 `Qoder CN IDE` → Quest → 选工作区 `/Users/ciscohe/Desktop/Patch`：
- 任务是否出现在列表？
- 点开是否能看到历史？

**通过** → 步骤 4；**不通过** → 步骤 5 回滚，并改用降级方案（把 `readable.md` 粘进新建任务）。

## 步骤 4 — 批量导入其余 2 个任务

```bash
cd /Users/ciscohe/Desktop/VirtualMacOniPad/tools/qoder-quest-migration
E="$HOME/Desktop/QoderCN-Quest-导出"
python3 migrate_quest.py --history "$E/88d0cabd-dfe8-47ab-81c1-727d838512d2/ide-history.jsonl" \
  --folder "/Users/ciscohe/Desktop/Patch" --slug "Patch-5ea91c46" --title "CN迁移: 88d0cabd" --query "0x88d0cabd"
python3 migrate_quest.py --history "$E/8d9eedd7-a6fb-42b0-80df-f00d62a87034/ide-history.jsonl" \
  --folder "/Users/ciscohe/Desktop/Patch" --slug "Patch-5ea91c46" --title "CN迁移: 8d9eedd7" --query "0x8d9eedd7"
```

每个导完**立即启动 App 验证一次**（便于定位问题）。

## 步骤 5 — 回滚

**整机回滚（推荐，非破坏：先把现状挪到桌面再还原）**
```bash
cd /Users/ciscohe/Desktop/VirtualMacOniPad/tools/qoder-quest-migration
bash rollback.sh "$HOME/Desktop/QoderCN-Migration-Backup-<时间戳>"
```

**只撤列表改动（保留历史文件）**
```bash
python3 migrate_quest.py --restore-snapshot snapshot.before.json
```

**只删某个伪造任务**：按 `fabricated-tasks.txt` 里的路径手动移到废纸篓即可。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `cn2ide.py` | CN 事件流 → IDE 会话格式 + 可读 Markdown |
| `backup.sh` | 备份 `state.vscdb` 与 `~/.qoder-cn/{cache,projects,tasks}` |
| `rollback.sh` | 从备份还原（非破坏：旧状态挪到桌面） |
| `migrate_quest.py` | 试点/批量导入；`--dry-run` 只读预览；`--restore-snapshot` 只撤列表 |

## 风险与已知限制
- 伪造任务**没有服务端 session**：可能被云端刷新覆盖，或打开时提示会话不存在；不保证能"继续跑"，**至少列表与历史可见**。
- 修改 `state.vscdb` **必须 App 关闭**（SQLite 锁）。
- 任何一步出问题，用步骤 5 回滚即可，原始数据（独立版 CN）**全程只读**。
