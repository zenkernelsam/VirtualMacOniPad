#!/usr/bin/env python3
"""Build a paste-ready context pack from an exported archive, so the work can be
continued in a NEW Quest task.

The `state.vscdb` injection route is ABANDONED (it froze the Quest UI). The
supported path is: create a normal Quest task, then paste this pack as context.

Usage:
    make_paste_pack.py <archive-dir> [--max-bytes 12000]
Writes <archive-dir>/paste-context.md (idempotent, overwrites).
"""
import argparse
import glob
import json
import os
import re


def load_history(path):
    msgs = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            role = obj.get("role") or (obj.get("message") or {}).get("role")
            if role in ("user", "assistant") and isinstance(obj.get("message"), dict):
                msgs.append((role, obj["message"]))
    return msgs


def text_of(message, cap=None):
    parts = []
    content = message.get("content")
    if isinstance(content, str):
        parts.append(content)
    for part in content or []:
        if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
            parts.append(part["text"])
    out = "\n".join(parts).strip()
    if cap and len(out) > cap:
        out = out[:cap] + f"\n…（已截断，完整内容见归档原文）"
    return out


def load_plan(archive_dir):
    items = []
    for path in glob.glob(os.path.join(archive_dir, "plan", "*.json")):
        try:
            d = json.load(open(path, encoding="utf-8"))
        except Exception:
            continue
        if isinstance(d, dict) and "subject" in d:
            items.append(d)
    items.sort(key=lambda d: (len(str(d.get("id", ""))), str(d.get("id", ""))))
    return items


def build(archive_dir, max_bytes):
    hist = os.path.join(archive_dir, "ide-history.jsonl")
    msgs = load_history(hist)
    users = [(r, m) for r, m in msgs if r == "user"]
    plan = load_plan(archive_dir)
    title = os.path.basename(os.path.normpath(archive_dir))

    head = [
        f"# 上下文还原：{title}",
        "",
        "> 本文件由 Qoder CN 归档自动生成，用于在**新建的 Quest 任务**里恢复上下文。",
        f"> 完整会话原文（IDE 格式，{len(msgs)} 条）：`{hist}`",
        "",
        "**请据此继续工作**：先通读下面的“原始需求 / 进度计划 / 最后进展”，然后接着未完成的步骤做。",
        "",
    ]

    sec1 = ["## 1. 原始需求（用户最初的要求）", ""]
    for _, m in users[:3]:
        t = text_of(m, cap=1800)
        if t:
            sec1 += [t, ""]

    sec2 = []
    if plan:
        sec2 = ["## 2. 原会话的进度计划（来自 tasks/*.json）", ""]
        for it in plan:
            mark = {"completed": "✅", "in_progress": "⏳", "pending": "⬜"}.get(
                it.get("status", ""), "•")
            sec2.append(f"- {mark} {it.get('subject', '')}")
            desc = (it.get("description") or "").strip()
            if desc:
                sec2.append(f"    - {desc[:300]}")
        sec2.append("")

    tail_msgs = msgs[-6:]
    sec3 = ["## 3. 最后进展（结尾若干条，用于定位断点）", ""]
    for role, m in tail_msgs:
        t = text_of(m, cap=1500)
        if t:
            sec3 += [f"### {'User' if role == 'user' else 'Assistant'}", "", t, ""]

    sec4 = ["## 4. 统计与索引", "",
            f"- 消息总数：{len(msgs)}（user {len(users)} / assistant {len(msgs) - len(users)}）",
            f"- 计划项：{len(plan)}",
            f"- 归档目录：`{archive_dir}`",
            f"- 可读全文：`{os.path.join(archive_dir, 'readable.md')}`",
            f"- IDE 格式会话流：`{hist}`",
            ""]

    doc = "\n".join(head + sec1 + sec2 + sec3 + sec4)
    if len(doc.encode("utf-8")) > max_bytes:
        # trim: drop section 1 beyond the first message, then shorten tails
        sec1 = sec1[:6]
        doc = "\n".join(head + sec1 + sec2 + sec3 + sec4)
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archive_dir")
    ap.add_argument("--max-bytes", type=int, default=12000)
    args = ap.parse_args()
    doc = build(args.archive_dir, args.max_bytes)
    out = os.path.join(args.archive_dir, "paste-context.md")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(doc)
    print(f"wrote {out} ({len(doc.encode('utf-8'))} bytes)")


if __name__ == "__main__":
    main()
