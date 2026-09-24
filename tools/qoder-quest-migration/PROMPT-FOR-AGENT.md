# 交给 IDE Agent 的启动 Prompt（降级方案：把归档粘进新 Quest 任务）

> ⛔ **已废弃**：伪写 `state.vscdb` 的注入路线于 2026-09-20 实测失败（任务不显示、Quest 卡死、拖垮 VM），已完整回滚。**请勿重试注入/伪造任何 IDE 状态。**

---

## 复制下面整段发给 Piebald 👇

```text
任务：把独立版 Qoder CN 的 3 个任务，用【归档 + 新建 Quest 任务】的方式在 Qoder CN IDE 里恢复上下文并继续。

【严格禁止】
- 不要写/改 state.vscdb，不要伪造 ~/.qoder-cn/cache/projects|experts 下的任何目录。
- 不要改动独立版 Qoder CN 的数据（~/.qoder-cn/projects|tasks 只读）。
- 不要执行 tools/qoder-quest-migration 下的 run-migration.sh pilot|rest、migrate_quest.py。
- 不做 git 提交/推送；不使用 rm -rf。

【现成素材（已生成，直接用）】
- 归档目录：~/Desktop/QoderCN-Quest-导出/<taskId>/
  · paste-context.md   ← 精简上下文包（2~7KB，整段粘贴用）
  · readable.md        ← 完整可读会话（最大 378KB，按需引用/分次粘贴）
  · ide-history.jsonl  ← IDE 格式完整会话流（备查）
  · plan/              ← 原会话的计划项
- 三个任务：
  1) 0766d3fa-7bbd-4723-9bf9-99264d4891aa —— 仅 2 条消息（请求被中断），内容极少，可选处理
  2) 88d0cabd-dfe8-47ab-81c1-727d838512d2 —— 400 条消息（建议优先）
  3) 8d9eedd7-a6fb-42b0-80df-f00d62a87034 —— 2233 条消息（最大，建议只贴 paste-context.md）

【执行步骤】
1. 在 Qoder CN IDE 的 Quest 里，把工作区切到 /Users/ciscohe/Desktop/Patch，新建一个任务
   （标题建议：CN迁移: <任务主题或 id 前缀>）。
2. 把对应归档的 paste-context.md 全文作为第一条消息发出去，并追加一句：
   “以上是从 Qoder CN 归档恢复的上下文；请先复述你理解的任务与断点，然后从‘进度计划/最后进展’处继续。”
3. 若上下文不够（大任务），再让 Agent 按 paste-context.md 里给出的路径去读 readable.md
   （优先读开头摘要与结尾结论，不要一次性全文灌入）。
4. 对第 2、3 个任务重复 1-3。
5. 汇报：每个新任务的标题、是否成功恢复上下文、Agent 复述的断点是否与原会话一致。

【完成标准】
- 三个（或选定的）任务在 IDE Quest 的 Patch 工作区各有一个新建任务，且 Agent 能复述原任务目标与断点。
- 独立版 CN 数据、IDE 状态文件均未被修改。
```

（把上面代码块内容整段粘给 Piebald 即可。若只需恢复 1 个任务，优先 `88d0cabd`。）
