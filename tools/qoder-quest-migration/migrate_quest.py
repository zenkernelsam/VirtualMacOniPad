#!/usr/bin/env python3
"""Import a standalone Qoder CN Quest task into Qoder CN IDE's Quest.

RUN WITH BOTH APPS QUIT — this edits the IDE's state.vscdb (SQLite).

    migrate_quest.py --history <ide-history.jsonl> --folder <abs-workspace> \
        --slug <name-hash8> --title <title> --query <first-user-query> \
        [--repo-name <owner/repo>] [--dry-run]

What it does (mirrors exactly what the IDE itself writes for a real-folder task):
  1. NEWID = "task-" + 20 hex, id8 = NEWID[:8]
  2. <qoder>/cache/projects/<slug>/conversation-history/<id8>/<id8>.jsonl  (history)
  3. <qoder>/cache/experts/<NEWID>.session.execution/{metadata.json,agents/,inboxes/}
  4. state.vscdb -> ItemTable.aicoding.questTaskListSnapshot
        folders[<folder>].tasks += [Task]   and updatedAt bumped
  5. writes ./snapshot.before.json (undo data) and appends to ./fabricated-tasks.txt

Rollback of just step 4 (list):  migrate_quest.py --restore-snapshot snapshot.before.json
"""
import argparse
import json
import os
import secrets
import sqlite3
import sys
import time
import uuid

HOME = os.path.expanduser("~")
QODER = os.path.join(HOME, ".qoder-cn")
GS_DB = os.path.join(HOME, "Library", "Application Support", "QoderCN",
                    "User", "globalStorage", "state.vscdb")
SNAP_KEY = "aicoding.questTaskListSnapshot"
RAW_CONFIG = json.dumps({"chatContext": {"preferredLanguage": "zh"},
                         "pluginPayloadConfig": {"isEnableAutoMemory": True}},
                        separators=(",", ":"), ensure_ascii=False)


def load_snapshot():
    con = sqlite3.connect(f"file:{GS_DB}?mode=ro", uri=True)
    try:
        row = con.execute("SELECT value FROM ItemTable WHERE key=?", (SNAP_KEY,)).fetchone()
    finally:
        con.close()
    if row is None:
        raise SystemExit(f"FATAL: key {SNAP_KEY} not found in {GS_DB}")
    value = row[0]
    if isinstance(value, (bytes, bytearray)):
        value = value.decode("utf-8")
    return json.loads(value)


def save_snapshot(snap):
    payload = json.dumps(snap, ensure_ascii=False, separators=(",", ":"))
    con = sqlite3.connect(GS_DB)
    try:
        con.execute("BEGIN")
        cur = con.execute("UPDATE ItemTable SET value=? WHERE key=?", (payload, SNAP_KEY))
        if cur.rowcount != 1:
            raise SystemExit("FATAL: snapshot row not updated (rowcount != 1)")
        con.commit()
    finally:
        con.close()


def existing_machine_id(snap):
    for entry in snap["folders"].values():
        for task in entry.get("tasks", []):
            if task.get("machineId"):
                return task["machineId"]
    return str(uuid.uuid4())


def build_task(new_id, folder, machine_id, title, query, repo_name):
    now = int(time.time() * 1000)
    return {
        "id": new_id, "workspaceId": "", "machineId": machine_id,
        "name": title, "prevStatus": "", "status": "Completed",
        "createTime": now, "sourceBranch": "main", "targetBranch": "",
        "headCommitId": "", "executeStartTime": 0, "executeEndTime": 0,
        "endTime": 0, "bootStatus": "", "finishedActionCount": 0,
        "totalActionCount": 0, "rawConfig": RAW_CONFIG,
        "updatedAtTimestamp": now, "lastUserQueryAt": now,
        "filePath": folder, "designFile": "", "userRequirements": "",
        "agentClass": "LocalAgent", "questType": "agent",
        "executionMode": "execute", "designSessionId": "",
        "executionSessionId": f"{new_id}.session.execution",
        "executionSessionStopReason": "Stopped", "executionRequestId": "",
        "query": query, "runtime": None, "taskVersion": "v2",
        "planProgress": {"completedSteps": 0, "totalSteps": 0},
        "repoName": repo_name or "", "workspaceUri": "file://" + folder,
        "title": title, "createdAt": now, "finishedAt": 0,
        "executeStartAt": 0, "executeEndAt": 0, "designRequestId": "",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--history", help="converted ide-history.jsonl")
    ap.add_argument("--folder", help="absolute workspace path, e.g. /Users/x/Desktop/Patch")
    ap.add_argument("--slug", help="project cache slug, e.g. Patch-5ea91c46")
    ap.add_argument("--title", default="")
    ap.add_argument("--query", default="")
    ap.add_argument("--repo-name", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore-snapshot", help="restore list from snapshot.before.json and exit")
    args = ap.parse_args()

    if args.restore_snapshot:
        snap = json.load(open(args.restore_snapshot, encoding="utf-8"))
        save_snapshot(snap)
        print(f"snapshot restored from {args.restore_snapshot}")
        return 0

    for req in ("history", "folder", "slug"):
        if not getattr(args, req):
            ap.error(f"--{req} is required")

    new_id = "task-" + secrets.token_hex(10)          # task-<20 hex>
    id8 = new_id[:8]                                  # naming rule: first 8 chars
    hist_dir = os.path.join(QODER, "cache", "projects", args.slug,
                            "conversation-history", id8)
    hist_file = os.path.join(hist_dir, f"{id8}.jsonl")
    sess_dir = os.path.join(QODER, "cache", "experts", f"{new_id}.session.execution")

    snap = load_snapshot()
    machine_id = existing_machine_id(snap)
    task = build_task(new_id, args.folder, machine_id,
                      args.title or os.path.basename(args.folder),
                      args.query or (args.title or os.path.basename(args.folder)),
                      args.repo_name)
    n_lines = sum(1 for _ in open(args.history, encoding="utf-8"))
    print(f"new id      : {new_id}  (dir id8={id8})")
    print(f"history     : {hist_file}  ({n_lines} lines)")
    print(f"session dir : {sess_dir}")
    print(f"folder key  : {args.folder}")

    if args.dry_run:
        print("\n(dry-run: nothing written)")
        return 0

    # 1) history
    os.makedirs(hist_dir, exist_ok=True)
    with open(args.history, "rb") as src, open(hist_file, "wb") as dst:
        dst.write(src.read())
    os.chmod(hist_dir, 0o700)
    os.chmod(hist_file, 0o600)

    # 2) experts runtime (mirrors the IDE template)
    os.makedirs(os.path.join(sess_dir, "agents"), exist_ok=True)
    os.makedirs(os.path.join(sess_dir, "inboxes"), exist_ok=True)
    with open(os.path.join(sess_dir, "metadata.json"), "w", encoding="utf-8") as fh:
        json.dump({"name": "Experts Team",
                   "description": "Multi-agent experts session",
                   "version": "v1",
                   "sessionId": f"{new_id}.session.execution",
                   "members": [{"teamId": "leader", "name": "Leader",
                                "model": "", "description": "", "role": "leader"}]},
                  fh, ensure_ascii=False, indent=2)

    # 3) snapshot
    json.dump(snap, open("snapshot.before.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    now = int(time.time() * 1000)
    entry = snap["folders"].setdefault(args.folder, {"updatedAt": now, "tasks": []})
    entry["tasks"] = [t for t in entry.get("tasks", []) if t.get("id") != new_id] + [task]
    entry["updatedAt"] = now
    snap["updatedAt"] = now
    save_snapshot(snap)

    # verify round-trip
    back = load_snapshot()
    assert back["version"] == snap["version"], "snapshot version changed!"

    with open("fabricated-tasks.txt", "a", encoding="utf-8") as fh:
        fh.write(hist_dir + "\n" + sess_dir + "\n")

    print("\nDONE. Start the IDE and open Quest on the folder to verify.")
    print(f"undo list change : {os.path.abspath('snapshot.before.json')}")
    print("before.json / fabricated-tasks.txt are in the current directory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
