#!/bin/bash
# Invoked with positional arguments by the app, never interpolated shell commands.
set -eu
umask 077
update_pid="$1"
update_target="$2"
update_staged="$3"
update_backup="$4"
update_work="$5"
exec >"$update_work/install.log" 2>&1
update_failure_title="${6:-更新未完成}"
update_failure_message="${7:-已保留原本的 App，請重新開啟後再試一次。}"
update_pending_title="${8:-更新已安裝}"
update_pending_message="${9:-尚未確認新版已開啟。請手動開啟 App；舊版備份仍保留。}"
show_update_alert() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  display alert (item 1 of argv) message (item 2 of argv)
end run
APPLESCRIPT
}

# Wait for the app's normal save / GPU shutdown sequence. Do not force-quit it.
for ((attempt=0; attempt<120; attempt++)); do
  if ! /bin/kill -0 "$update_pid" 2>/dev/null; then break; fi
  /bin/sleep 1
done
if /bin/kill -0 "$update_pid" 2>/dev/null; then exit 1; fi

update_moved=0
update_installed=0
restore() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    if [[ "$update_installed" -eq 1 ]]; then /bin/mv "$update_target" "$update_staged" || true; fi
    if [[ "$update_moved" -eq 1 && ! -e "$update_target" ]]; then /bin/mv "$update_backup" "$update_target" || true; fi
    /usr/bin/open -n -a "$update_target" || true
    show_update_alert "$update_failure_title" "$update_failure_message" || true
  fi
  exit "$status"
}
trap restore EXIT
[[ -d "$update_target" && ! -L "$update_target" && -d "$update_staged" && ! -L "$update_staged" && ! -e "$update_backup" ]]
/usr/bin/codesign --verify --deep --strict "$update_staged"
/bin/mv "$update_target" "$update_backup"
update_moved=1
/bin/mv "$update_staged" "$update_target"
update_installed=1
/usr/bin/open -n -a "$update_target" --args --finish-update "$update_work"
# Keep the backup until the new app has actually started and accepted the receipt.
for ((attempt=0; attempt<60; attempt++)); do
  if [[ -f "$update_work/confirmed" ]]; then
    /bin/rm -rf "$update_backup"
    /bin/rm -rf "$update_work"
    exit 0
  fi
  /bin/sleep 1
done
# LaunchServices may be slow; retain both the new app and backup without replacing a running app.
trap - EXIT
show_update_alert "$update_pending_title" "$update_pending_message" || true
exit 0
