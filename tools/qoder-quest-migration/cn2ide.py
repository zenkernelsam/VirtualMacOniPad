#!/usr/bin/env python3
"""Convert a standalone Qoder CN task transcript into the Qoder CN IDE Quest
conversation-history format, plus a human-readable Markdown archive.

CN transcript (``~/.qoder-cn/projects/<folder>/<taskId>.jsonl``) is an event
stream, e.g.::

    {"type":"workspace-directories","sessionId":...,"directories":[...]}
    {"type":"runtime-config","sessionId":...,"model":...}
    {"type":"user","uuid":...,"timestamp":...,"message":{"role":"user","content":[...]}}
    {"type":"assistant","timestamp":...,"message":{"role":"assistant","content":[...]}}

IDE Quest history (``.../conversation-history/<id8>/<id8>.jsonl``) is a plain
projection::

    {"role":"user","message":{"content":[{"type":"text","text":"..."}]}}

Usage:
    cn2ide.py <cn-task.jsonl> <out-dir> [title]
Writes ``<out-dir>/ide-history.jsonl`` and ``<out-dir>/readable.md``.
"""
import json
import os
import sys


def _text_of(message):
    """Flatten a message's content parts into Markdown-ish text."""
    out = []
    content = (message or {}).get("content")
    if isinstance(content, str):
        return content
    for part in content or []:
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        if kind == "text" and part.get("text"):
            out.append(part["text"])
        elif kind == "tool_use":
            out.append(f"\n> [tool_use] {part.get('name', '?')}\n")
        elif kind == "tool_result":
            body = part.get("content")
            if isinstance(body, list):
                body = " ".join(p.get("text", "") for p in body if isinstance(p, dict))
            out.append(f"\n> [tool_result] {str(body)[:400]}\n")
    return "\n".join(out).strip()


def convert(src, out_dir, title=""):
    os.makedirs(out_dir, exist_ok=True)
    hist_path = os.path.join(out_dir, "ide-history.jsonl")
    md_path = os.path.join(out_dir, "readable.md")
    kept = skipped = 0
    with open(src, "r", encoding="utf-8", errors="replace") as fin, \
            open(hist_path, "w", encoding="utf-8") as fhist, \
            open(md_path, "w", encoding="utf-8") as fmd:
        fmd.write(f"# {title or os.path.basename(src)}\n\n> source: `{src}`\n\n---\n\n")
        for line in fin:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            msg = obj.get("message")
            role = obj.get("type") or (msg or {}).get("role")
            if role in ("user", "assistant") and isinstance(msg, dict):
                # IDE shape: {role, message:{content:[...]}}
                fhist.write(json.dumps({"role": msg.get("role", role),
                                        "message": msg}, ensure_ascii=False) + "\n")
                text = _text_of(msg)
                if text:
                    fmd.write(f"## {'User' if role == 'user' else 'Assistant'}\n\n{text}\n\n")
                kept += 1
            else:
                skipped += 1
    return kept, skipped, hist_path, md_path


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, out_dir = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else ""
    kept, skipped, hist_path, md_path = convert(src, out_dir, title)
    print(f"kept={kept} skipped={skipped}\n  {hist_path}\n  {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
