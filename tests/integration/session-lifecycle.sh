#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
lifecycle="$root_dir/scripts/session-lifecycle"
resurrect=${RESURRECT_PLUGIN_PATH:-$HOME/.config/tmux/plugins/tmux-resurrect}
mkdir -p "$HOME/tmp"
test_root=$(mktemp -d "$HOME/tmp/tmux-session-lifecycle-test.XXXXXX")
socket_path="$test_root/tmux.sock"
state_dir="$test_root/state"
resurrect_dir="$test_root/resurrect"
restore_marker="$test_root/restore.marker"
restore_script="$test_root/restore.sh"
tmux_config="$test_root/tmux.conf"

cleanup() {
  tmux -S "$socket_path" kill-server 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local value=$1
  local fragment=$2
  local label=$3
  [[ "$value" == *"$fragment"* ]] || fail "$label: missing '$fragment'"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

[[ -x "$lifecycle" ]] || fail "session lifecycle command is executable"

mkdir -p "$state_dir" "$resurrect_dir"
no_server_tmux="$test_root/no-server-tmux"
cat >"$no_server_tmux" <<'NO_SERVER_TMUX'
#!/usr/bin/env bash
exit 1
NO_SERVER_TMUX
chmod +x "$no_server_tmux"
env TMUX_BIN="$no_server_tmux" TMUX_STATE_DIR="$state_dir/no-server" \
  "$lifecycle" save || fail "default-socket save skips cleanly when no server exists"

cat >"$restore_script" <<'RESTORE'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore\n' >>"$RESTORE_MARKER"
sleep 0.3
tmux new-session -d -s Recovered
RESTORE
chmod +x "$restore_script"

cat >"$tmux_config" <<CONFIG
set -g base-index 1
set -g default-shell /bin/sh
set -g @resurrect-capture-pane-contents off
set -g @resurrect-dir "$resurrect_dir"
set -g @resurrect-save-script-path "$resurrect/scripts/save.sh"
set -g @resurrect-restore-script-path "$restore_script"
CONFIG

common_env=(
  TMUX_SOCKET_PATH="$socket_path"
  TMUX_CONFIG_FILE="$tmux_config"
  TMUX_STATE_DIR="$state_dir"
  TMUX_RESURRECT_DIR="$resurrect_dir"
  TMUX_WARNING_DELAY_SECONDS=0
  RESTORE_MARKER="$restore_marker"
)

env "${common_env[@]}" "$lifecycle" save
[[ ! -e $state_dir/last-save ]] ||
  fail "saving without a tmux server leaves success metadata untouched"

snapshot="$resurrect_dir/tmux_resurrect_20260912T120000.txt"
cat >"$snapshot" <<'SNAPSHOT'
pane	Saved	1	1	:*	1	saved	:/workspace	1	zsh	:
window	Saved	1	:saved	1	:*	0000,80x24,0,0,1	on
state	Saved
SNAPSHOT
ln -s "${snapshot##*/}" "$resurrect_dir/last"

sessions=(Diagnostics Reviews Platform SCA Tools)
pids=()
for session in "${sessions[@]}"; do
  env "${common_env[@]}" "$lifecycle" prepare "$session" \
    >"$test_root/$session.out" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done

[[ $(wc -l <"$restore_marker" | tr -d ' ') == 1 ]] ||
  fail "concurrent launchers run one restore"
for session in Recovered "${sessions[@]}"; do
  tmux -S "$socket_path" has-session -t "=$session" 2>/dev/null ||
    fail "concurrent preparation creates session $session"
done
if tmux -S "$socket_path" has-session -t '=__workspace_bootstrap__' 2>/dev/null; then
  fail "bootstrap session is removed after preparation"
fi

env "${common_env[@]}" "$lifecycle" save
save_status=$(<"$state_dir/last-save")
assert_contains "$save_status" "result=ok" "scheduled save records success"
assert_contains "$save_status" "snapshot=tmux_resurrect_" \
  "scheduled save records the validated snapshot"
assert_contains "$save_status" "max_age=1200" \
  "scheduled save records its health threshold"
saved_snapshot=$(awk -F= '$1 == "snapshot" { print $2 }' "$state_dir/last-save")
saved_checksum=$(awk -F= '$1 == "sha256" { print $2 }' "$state_dir/last-save")
[[ -L $resurrect_dir/last ]] || fail "latest snapshot pointer is a symlink"
[[ $(readlink "$resurrect_dir/last") == "$saved_snapshot" ]] ||
  fail "success metadata identifies the latest snapshot"
[[ $(python3 "$root_dir/scripts/snapshot.py" checksum "$resurrect_dir/$saved_snapshot") == \
   "$saved_checksum" ]] || fail "success metadata records the snapshot checksum"
[[ $(file_mode "$state_dir") == 700 ]] || fail "lifecycle state directory is private"
[[ $(file_mode "$state_dir/last-save") == 600 ]] ||
  fail "lifecycle save metadata is private"

health_output=$(env "${common_env[@]}" TMUX_SAVE_MAX_AGE_SECONDS=3600 \
  "$lifecycle" health)
assert_contains "$health_output" "save: healthy" "health reports a recent successful save"

env "${common_env[@]}" TMUX_SAVE_MAX_AGE_SECONDS=3600 "$lifecycle" save
past_timestamp=$(($(date +%s) - 1800))
awk -F= -v timestamp="$past_timestamp" \
  'BEGIN { OFS="=" } $1 == "timestamp" { $2=timestamp } { print }' \
  "$state_dir/last-save" >"$state_dir/last-save.adjusted"
chmod 600 "$state_dir/last-save.adjusted"
mv -f -- "$state_dir/last-save.adjusted" "$state_dir/last-save"
health_output=$(env "${common_env[@]}" "$lifecycle" health)
assert_contains "$health_output" "save: healthy" \
  "health reuses the scheduler threshold recorded by the latest save"
env "${common_env[@]}" "$lifecycle" save

printf '\n' >>"$resurrect_dir/$saved_snapshot"
if env "${common_env[@]}" TMUX_SAVE_MAX_AGE_SECONDS=3600 \
    "$lifecycle" health >"$test_root/checksum-health.out" 2>&1; then
  fail "health rejects a snapshot changed after its successful save"
fi
assert_contains "$(<"$test_root/checksum-health.out")" "checksum" \
  "health explains snapshot checksum drift"
env "${common_env[@]}" "$lifecycle" save

save_marker="$test_root/save.marker"
save_release="$test_root/save.release"
save_wrapper="$test_root/save-wrapper.sh"
cat >"$save_wrapper" <<'SAVE'
#!/usr/bin/env bash
set -euo pipefail
printf 'save\n' >>"$SAVE_MARKER"
while [[ ! -e $SAVE_RELEASE ]]; do
  sleep 0.05
done
TMUX="$TMUX" "$REAL_SAVE_SCRIPT" quiet
SAVE
chmod +x "$save_wrapper"
tmux -S "$socket_path" set-option -g @resurrect-save-script-path "$save_wrapper"
status_before_blocked_save=$(<"$state_dir/last-save")
env "${common_env[@]}" \
  SAVE_MARKER="$save_marker" \
  SAVE_RELEASE="$save_release" \
  REAL_SAVE_SCRIPT="$resurrect/scripts/save.sh" \
  "$lifecycle" save >"$test_root/save-leader.out" 2>&1 &
save_leader=$!
for _ in {1..200}; do
  [[ -e $save_marker ]] && break
  sleep 0.05
done
[[ -e $save_marker ]] || fail "blocking save reached the real save boundary"
in_progress_health=$(env "${common_env[@]}" "$lifecycle" health)
assert_contains "$in_progress_health" "save: in progress" \
  "health does not validate a snapshot while a save holds the lifecycle lock"
save_followers=()
for _ in {1..4}; do
  env "${common_env[@]}" \
    SAVE_MARKER="$save_marker" \
    SAVE_RELEASE="$save_release" \
    REAL_SAVE_SCRIPT="$resurrect/scripts/save.sh" \
    "$lifecycle" save >"$test_root/save-follower.$_.out" 2>&1 &
  save_followers+=("$!")
done
for pid in "${save_followers[@]}"; do
  wait "$pid"
done
[[ $(wc -l <"$save_marker" | tr -d ' ') == 1 ]] ||
  fail "overlapping scheduled saves are coalesced"
[[ $(<"$state_dir/last-save") == "$status_before_blocked_save" ]] ||
  fail "success metadata is not published before a save completes"
touch "$save_release"
wait "$save_leader"
assert_contains "$(<"$state_dir/last-save")" "result=ok" \
  "the serialized save publishes success after completion"

failed_save_script="$test_root/failed-save.sh"
cat >"$failed_save_script" <<'FAILED_SAVE'
#!/usr/bin/env bash
exit 17
FAILED_SAVE
chmod +x "$failed_save_script"
tmux -S "$socket_path" set-option -g @resurrect-save-script-path "$failed_save_script"
if env "${common_env[@]}" "$lifecycle" save >"$test_root/failed-save.out" 2>&1; then
  fail "a failed scheduled save returns failure"
fi
if env "${common_env[@]}" "$lifecycle" health >"$test_root/failed-save-health.out" 2>&1; then
  fail "health rejects newer failed-save metadata"
fi
assert_contains "$(<"$test_root/failed-save-health.out")" "save: failed" \
  "health reports the latest scheduled save failure"
tmux -S "$socket_path" set-option -g @resurrect-save-script-path "$resurrect/scripts/save.sh"
env "${common_env[@]}" "$lifecycle" save

tmux -S "$socket_path" kill-server
rm -f -- "$restore_marker" "$resurrect_dir/last"
stale_snapshot="$resurrect_dir/tmux_resurrect_20200101T000000.txt"
cp "$snapshot" "$stale_snapshot"
touch -t 202001010000 "$stale_snapshot"
ln -s "${stale_snapshot##*/}" "$resurrect_dir/last"
stale_output=$(env "${common_env[@]}" TMUX_SAVE_MAX_AGE_SECONDS=1 \
  "$lifecycle" prepare Stale 2>&1)
assert_contains "$stale_output" "stale" "old valid snapshot produces a visible warning"
tmux -S "$socket_path" has-session -t '=Stale' 2>/dev/null ||
  fail "old valid snapshot is restored before the requested session is prepared"

tmux -S "$socket_path" kill-server
rm -f -- "$restore_marker" "$resurrect_dir/last"
printf 'invalid\n' >"$resurrect_dir/invalid.txt"
ln -s invalid.txt "$resurrect_dir/last"
if invalid_output=$(env "${common_env[@]}" "$lifecycle" prepare Broken 2>&1); then
  fail "invalid snapshot prevents workspace attachment"
fi
assert_contains "$invalid_output" "invalid" "invalid snapshot produces a visible warning"
if tmux -S "$socket_path" has-session -t '=Broken' 2>/dev/null; then
  fail "invalid snapshot does not create a replacement session"
fi
[[ ! -e "$restore_marker" ]] || fail "invalid snapshot is never passed to restore"
if env "${common_env[@]}" "$lifecycle" health >"$test_root/invalid-health.out" 2>&1; then
  fail "health fails while the latest restore status is invalid"
fi
assert_contains "$(<"$test_root/invalid-health.out")" "restore: invalid" \
  "health explains the invalid restore"

tmux -S "$socket_path" kill-server 2>/dev/null || true
rm -f -- "$restore_marker" "$resurrect_dir/last"
ln -s "${snapshot##*/}" "$resurrect_dir/last"
failed_restore_script="$test_root/failed-restore.sh"
failed_restore_config="$test_root/failed-restore.conf"
cat >"$failed_restore_script" <<'FAILED_RESTORE'
#!/usr/bin/env bash
tmux new-session -d -s Partial
exit 17
FAILED_RESTORE
chmod +x "$failed_restore_script"
cat >"$failed_restore_config" <<FAILED_CONFIG
set -g base-index 1
set -g default-shell /bin/sh
set -g @resurrect-dir "$resurrect_dir"
set -g @resurrect-save-script-path "$resurrect/scripts/save.sh"
set -g @resurrect-restore-script-path "$failed_restore_script"
FAILED_CONFIG
if failed_restore_output=$(env "${common_env[@]}" \
    TMUX_CONFIG_FILE="$failed_restore_config" \
    "$lifecycle" prepare Unrestored 2>&1); then
  fail "a failed restore prevents workspace attachment"
fi
assert_contains "$failed_restore_output" "restore command failed" \
  "failed restore produces a visible warning"
if tmux -S "$socket_path" has-session -t '=Unrestored' 2>/dev/null; then
  fail "failed restore does not create a replacement session"
fi
if tmux -S "$socket_path" has-session -t '=Partial' 2>/dev/null; then
  fail "failed restore does not leave a partially restored server running"
fi

rm -f -- "$resurrect_dir/last"
missing_output=$(env "${common_env[@]}" "$lifecycle" prepare Fresh 2>&1)
assert_contains "$missing_output" "missing" "a first-run workspace reports the missing snapshot"
tmux -S "$socket_path" has-session -t '=Fresh' 2>/dev/null ||
  fail "a first-run workspace creates the requested session"
if env "${common_env[@]}" "$lifecycle" health >"$test_root/pending-health.out" 2>&1; then
  fail "health remains pending until the new tmux server is saved"
fi
assert_contains "$(<"$test_root/pending-health.out")" "current tmux server has not been saved" \
  "health binds save metadata to the current server"
env "${common_env[@]}" "$lifecycle" save
assert_contains "$(env "${common_env[@]}" "$lifecycle" health)" "save: healthy" \
  "health becomes healthy after the current server is saved"

printf 'PASS: tmux session lifecycle\n'
