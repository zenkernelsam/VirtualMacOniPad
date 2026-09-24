#!/bin/bash
# One-click orchestrator: standalone Qoder CN Quest  ->  Qoder CN IDE Quest.
#
#   ./run-migration.sh check      # preflight (read-only)
#   ./run-migration.sh pilot      # backup + import the pilot task
#   ./run-migration.sh rest       # import the remaining 2 tasks
#   ./run-migration.sh rollback   # restore from the last backup (non-destructive)
#   ./run-migration.sh status     # what has been imported so far
#
# IMPORTANT: run this in Terminal.app with BOTH "Qoder CN" apps QUIT.
# Never delete user data here; rollback moves state aside instead of removing it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXPORT="$HOME/Desktop/QoderCN-Quest-导出"
FOLDER="/Users/ciscohe/Desktop/Patch"
SLUG="Patch-5ea91c46"
STATE="$HERE/.migration-state"
PY="/usr/bin/python3"
PILOT="0766d3fa-7bbd-4723-9bf9-99264d4891aa"
REST=("88d0cabd-dfe8-47ab-81c1-727d838512d2" "8d9eedd7-a6fb-42b0-80df-f00d62a87034")

msg() { printf '\n=== %s ===\n' "$*"; }

apps_running() {
  local procs
  procs="$(pgrep -fl "Qoder CN" 2>/dev/null | grep -v run-migration || true)"
  [ -n "$procs" ] || return 0
  printf '%s\n' "$procs" \
    | sed -nE 's#^[0-9]+ (/Applications/[^/]*\.app).*#\1#p' | sort -u
  return 0
}

ensure_apps_closed() {
  local running; running="$(apps_running)"
  if [ -n "$running" ]; then
    printf '!! 请先完全退出以下进程（Cmd+Q 两个 App）后重试：\n%s\n' "$running" >&2
    exit 1
  fi
}

import_one() { # $1 = CN task id (uuid), $2 = title
  local id="$1" title="$2" hist="$EXPORT/$1/ide-history.jsonl"
  [ -f "$hist" ] || { echo "!! missing archive: $hist" >&2; exit 1; }
  msg "importing $id"
  ( cd "$HERE" && "$PY" migrate_quest.py \
      --history "$hist" --folder "$FOLDER" --slug "$SLUG" \
      --title "$title" --query "$title" )
  [ -f "$HERE/snapshot.before.json" ] && mv "$HERE/snapshot.before.json" \
      "$HERE/snapshot.before-$id.json"
  echo "$id" >> "$HERE/.imported-ids"
}

case "${1:-check}" in
  check)
    msg "preflight"
    for f in backup.sh rollback.sh migrate_quest.py README.md; do
      [ -e "$HERE/$f" ] || echo "  missing: $f"
    done
    [ -d "$EXPORT" ] && echo "  export dir OK: $EXPORT" || { echo "  !! export dir missing"; exit 1; }
    for id in "$PILOT" "${REST[@]}"; do
      [ -f "$EXPORT/$id/ide-history.jsonl" ] \
        && echo "  archive OK: $id ($(wc -l < "$EXPORT/$id/ide-history.jsonl") lines)" \
        || echo "  !! archive missing: $id"
    done
    running="$(apps_running)"
    if [ -n "$running" ]; then
      echo "  !! apps still running (quit them before 'pilot'):"; echo "$running"
    else
      echo "  apps are closed ✔"
    fi
    ;;

  pilot)
    ensure_apps_closed
    msg "backup"
    BK="$("$HERE/backup.sh")"
    BK="$(printf '%s\n' "$BK" | sed -n 's/^BACKUP COMPLETE: //p' | tail -1)"
    [ -n "$BK" ] || { echo "!! could not determine backup dir" >&2; exit 1; }
    printf 'BACKUP=%s\n' "$BK" > "$STATE"
    echo "backup dir: $BK"
    import_one "$PILOT" "CN迁移: ShadowCore 上下文恢复"
    msg "NEXT"
    echo "1) 启动 Qoder CN IDE → Quest → 工作区 $FOLDER"
    echo "2) 确认任务出现且能打开"
    echo "3) 通过 → 退出 App 后运行:  bash run-migration.sh rest"
    echo "   失败 → 退出 App 后运行:  bash run-migration.sh rollback"
    ;;

  rest)
    ensure_apps_closed
    for id in "${REST[@]}"; do import_one "$id" "CN迁移: ${id%%-*}"; done
    msg "DONE"
    echo "启动 App 验证 3 个任务；若异常： bash run-migration.sh rollback"
    ;;

  rollback)
    [ -f "$STATE" ] || { echo "!! no $STATE (nothing recorded)"; exit 1; }
    BK="$(sed -n 's/^BACKUP=//p' "$STATE" | tail -1)"
    [ -n "$BK" ] || { echo "!! backup dir not recorded"; exit 1; }
    ensure_apps_closed
    msg "rollback from $BK"
    "$HERE/rollback.sh" "$BK"
    ;;

  status)
    msg "state"
    [ -f "$STATE" ] && cat "$STATE" || echo "  (no state yet)"
    echo "  imported: $( [ -f "$HERE/.imported-ids" ] && tr '\n' ' ' < "$HERE/.imported-ids" || echo none )"
    echo "  fabricated paths:"; [ -f "$HERE/fabricated-tasks.txt" ] && sed 's/^/    /' "$HERE/fabricated-tasks.txt" || echo "    (none)"
    ;;

  *) echo "usage: $0 {check|pilot|rest|rollback|status}" >&2; exit 2 ;;
esac
