#!/usr/bin/env bash
# Exercise a targeted restore against a throwaway tmux socket.

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECOVERY="$ROOT_DIR/scripts/workspace-recovery"
RESURRECT="${RESURRECT_PLUGIN_PATH:-$HOME/.config/tmux/plugins/tmux-resurrect}"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ -x "$RESURRECT/scripts/save.sh" ] || fail "set RESURRECT_PLUGIN_PATH to tmux-resurrect"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

mkdir -p "$HOME/tmp"
CASE_DIR="$(mktemp -d "$HOME/tmp/tmux-workspace-recovery-test.XXXXXX")"
SOCKET="$CASE_DIR/tmux.sock"
DATA_DIR="$CASE_DIR/resurrect"
SPECIAL_SOCKET="$CASE_DIR/special.sock"
mkdir "$DATA_DIR"

cleanup() {
	tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true
	tmux -S "$SPECIAL_SOCKET" kill-server >/dev/null 2>&1 || true
	case "$CASE_DIR" in
	"$HOME/tmp/tmux-workspace-recovery-test."*) rm -rf -- "$CASE_DIR" ;;
	esac
}
trap cleanup EXIT INT TERM

tx() {
	tmux -S "$SOCKET" "$@"
}

topology() {
	local session="$1"
	tx list-panes -s -t "=$session" -F \
		'#{session_name}|#{window_index}|#{window_name}|#{window_layout}|#{pane_index}|#{pane_id}' | sort
}

tx -f /dev/null new-session -d -s keep -n sentinel -c "$CASE_DIR" 'sleep 600'
tx split-window -t '=keep:0' -c "$CASE_DIR" 'sleep 600'
tx set-option -w -t '=keep:0' automatic-rename off
tx set-option -w -t '=keep:0' @sentinel untouched
tx new-session -d -s race -n concurrent-save -c "$CASE_DIR" 'sleep 600'
tx split-window -t '=race:0' -c "$CASE_DIR" 'sleep 600'
tx set-option -g @workspace-recovery-key R
TMUX="$SOCKET,0,0" "$ROOT_DIR/workspace-recovery.tmux"
tx list-keys -T prefix | grep -F 'bind-key' | grep -F ' R ' | grep -Fq 'workspace-recovery pick' ||
	fail "TPM entry point did not bind the configured key"
[ "$(tx show-option -gqv @workspace_recovery_lifecycle_command)" = \
	"$ROOT_DIR/scripts/session-lifecycle" ] || fail "TPM entry point did not publish lifecycle command"
[ "$(tx show-option -gqv @workspace_recovery_scheduler_command)" = \
	"$ROOT_DIR/scripts/workspace-recovery-scheduler" ] ||
	fail "TPM entry point did not publish scheduler command"

tx new-session -d -s recover -n mapping -c "$CASE_DIR" 'sleep 600'
tx split-window -t '=recover:0' -c "$CASE_DIR" 'sleep 600'
tx set-option -w -t '=recover:0' automatic-rename off
tx new-window -d -t '=recover:1' -n data -c "$CASE_DIR" 'sleep 600'
tx set-option -w -t '=recover:1' automatic-rename off
tx set-option -g @resurrect-dir "$DATA_DIR"
tx set-option -g @resurrect-capture-pane-contents off
tx set-option -g @resurrect-processes false
HOOK_COMMAND='tmux set-option -g @workspace-recovery-hook-ran yes'
tx set-option -g @resurrect-hook-pre-restore-all "$HOOK_COMMAND"
tx set-buffer -b workspace-recovery-sentinel 'leave me alone'

if WORKSPACE_RECOVERY_REAL_TMUX="$(command -v tmux)" \
	WORKSPACE_RECOVERY_TMUX_SOCKET="$SOCKET" \
	"$ROOT_DIR/scripts/tmux-socket-proxy" kill-session -t keep >/dev/null 2>&1; then
	fail "socket proxy allowed kill-session"
fi
if WORKSPACE_RECOVERY_REAL_TMUX="$(command -v tmux)" \
	WORKSPACE_RECOVERY_TMUX_SOCKET="$SOCKET" \
	"$ROOT_DIR/scripts/tmux-socket-proxy" killw -t '=keep:0' >/dev/null 2>&1; then
	fail "socket proxy allowed a kill-window alias"
fi
if WORKSPACE_RECOVERY_REAL_TMUX="$(command -v tmux)" \
	WORKSPACE_RECOVERY_TMUX_SOCKET="$SOCKET" \
	"$ROOT_DIR/scripts/tmux-socket-proxy" list-sessions ';' kill-window -t '=keep:0' \
	>/dev/null 2>&1; then
	fail "socket proxy allowed a compound command"
fi
if WORKSPACE_RECOVERY_REAL_TMUX="$(command -v tmux)" \
	WORKSPACE_RECOVERY_TMUX_SOCKET="$SOCKET" \
	"$ROOT_DIR/scripts/tmux-socket-proxy" run-shell true >/dev/null 2>&1; then
	fail "socket proxy allowed an unsupported command"
fi
tx has-session -t '=keep' || fail "socket proxy removed sentinel session"

tx select-pane -t '=recover:0.1'
tx resize-pane -t '=recover:0.1' -Z
tx resize-window -t '=recover:0' -x 120 -y 40
TMUX="$SOCKET,0,0" "$RESURRECT/scripts/save.sh" >/dev/null
SOURCE_NAME="$(readlink "$DATA_DIR/last")"
SOURCE_SNAPSHOT="$DATA_DIR/$SOURCE_NAME"
[ -f "$SOURCE_SNAPSHOT" ] || fail "source snapshot was not created"
SOURCE_HASH="$(python3 "$ROOT_DIR/scripts/snapshot.py" checksum "$SOURCE_SNAPSHOT")"

for archive_index in 1 2 3 4 5; do
	cp "$SOURCE_SNAPSHOT" "$DATA_DIR/tmux_resurrect_20260906T00000${archive_index}.txt"
done
touch -t 202001010000 "$SOURCE_SNAPSHOT"
tx set-option -g @resurrect-delete-backup-after 0

mkdir "$CASE_DIR/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *"session> "*) grep -m 1 "^recover\t" ;; *) head -n 1 ;; esac\n' \
	>"$CASE_DIR/bin/fzf"
chmod +x "$CASE_DIR/bin/fzf"
cp "$SOURCE_SNAPSHOT" "$CASE_DIR/source-original"
mkfifo "$CASE_DIR/picker-input"
LAST_BEFORE_PICKER="$(readlink "$DATA_DIR/last")"
PATH="$CASE_DIR/bin:$PATH" TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" pick --socket "$SOCKET" <"$CASE_DIR/picker-input" \
	>"$CASE_DIR/picker.out" 2>"$CASE_DIR/picker.err" &
picker_pid=$!
exec 3>"$CASE_DIR/picker-input"
for _ in {1..200}; do
	grep -Fq 'Type recover to restore this session' "$CASE_DIR/picker.out" 2>/dev/null && break
	sleep 0.05
done
grep -Fq 'Type recover to restore this session' "$CASE_DIR/picker.out" ||
	fail "picker did not reach confirmation"
printf '\n' >>"$SOURCE_SNAPSHOT"
printf 'recover\n' >&3
exec 3>&-
if wait "$picker_pid"; then
	fail "picker applied a snapshot that changed after preview"
fi
grep -Fq 'snapshot changed after preview' "$CASE_DIR/picker.err" ||
	fail "picker checksum rejection was not reported"
[ "$(readlink "$DATA_DIR/last")" = "$LAST_BEFORE_PICKER" ] ||
	fail "picker checksum rejection created a safety checkpoint"
cp "$CASE_DIR/source-original" "$SOURCE_SNAPSHOT"
touch -t 202001010000 "$SOURCE_SNAPSHOT"
tx resize-window -t '=recover:0' -x 80 -y 24

KEEP_BEFORE="$(topology keep)"
pane_to_close="$(tx list-panes -t '=recover:0' -F '#{pane_id}' | tail -1)"
tx kill-pane -t "$pane_to_close"
tx kill-window -t '=recover:1'

TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" >"$CASE_DIR/dry-run.out"
grep -Fq 'Dry run only' "$CASE_DIR/dry-run.out" || fail "restore did not default to dry run"
[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "dry run created a window"
[ "$(tx list-panes -t '=recover:0' -F '#{pane_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "dry run created a pane"

RACE_RESURRECT="$CASE_DIR/race-resurrect"
RACE_READY="$CASE_DIR/race-ready"
RACE_RELEASE="$CASE_DIR/race-release"
cp -R "$RESURRECT" "$RACE_RESURRECT"
printf '#!/usr/bin/env bash\n: >"%s"\nwhile [ ! -f "%s" ]; do sleep 0.05; done\n"%s" "$@"\n' \
	"$RACE_READY" "$RACE_RELEASE" "$RESURRECT/scripts/restore.sh" \
	>"$RACE_RESURRECT/scripts/restore.sh"
chmod +x "$RACE_RESURRECT/scripts/restore.sh"
TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RACE_RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply \
	>"$CASE_DIR/race.out" 2>"$CASE_DIR/race.err" &
race_recovery_pid=$!
for _ in {1..200}; do
	[ -f "$RACE_READY" ] && break
	sleep 0.05
done
[ -f "$RACE_READY" ] || fail "concurrent save fixture did not reach restore"
[ "$(tx show-option -gqv @resurrect-dir)" = "$DATA_DIR" ] ||
	fail "private restore directory leaked through the global option"
tx set-option -g @resurrect-delete-backup-after 99999
TMUX="$SOCKET,0,0" "$RESURRECT/scripts/save.sh" >/dev/null
tx set-option -g @resurrect-delete-backup-after 0
race_pane_to_close="$(tx list-panes -t '=race:0' -F '#{pane_id}' | tail -1)"
tx kill-pane -t "$race_pane_to_close"
RACE_REMAINING="$(tx display-message -p -t '=race:0' '#{pane_id}')"
touch "$RACE_RELEASE"
if wait "$race_recovery_pid"; then
	fail "restore ignored a concurrent non-target topology change"
fi
[ "$(tx list-panes -t '=race:0' -F '#{pane_id}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "targeted restore recreated a non-target pane from a concurrent save"
[ "$(tx display-message -p -t '=race:0' '#{pane_id}')" = "$RACE_REMAINING" ] ||
	fail "targeted restore replaced the surviving non-target pane"
[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "concurrent-save rollback left the restored window"
[ "$(tx list-panes -t '=recover:0' -F '#{pane_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "concurrent-save rollback left the restored pane"
tx rename-window -t '=recover:0' ''
ROLLBACK_PANE="$(tx display-message -p -t '=recover:0' '#{pane_id}')"
tx select-pane -t "$ROLLBACK_PANE" -T ''

FAILING_RESURRECT="$CASE_DIR/failing-resurrect"
cp -R "$RESURRECT" "$FAILING_RESURRECT"
printf '#!/usr/bin/env bash\n"%s" "$@"\n"%s" -S "%s" split-window -d -P -F "#{pane_id}" -t "=recover:1" -c "%s" "sleep 600" >"%s"\nexit 1\n' \
	"$RESURRECT/scripts/restore.sh" "$(command -v tmux)" "$SOCKET" "$CASE_DIR" \
	"$CASE_DIR/concurrent-pane" \
	>"$FAILING_RESURRECT/scripts/restore.sh"
chmod +x "$FAILING_RESURRECT/scripts/restore.sh"
if TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$FAILING_RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply \
	>"$CASE_DIR/failure.out" 2>"$CASE_DIR/failure.err"; then
	fail "injected restore failure returned success"
fi
[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "2" ] ||
	fail "rollback did not preserve the concurrent pane's window"
[ "$(tx list-panes -t '=recover:0' -F '#{pane_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "rollback left the injected pane"
[ -z "$(tx display-message -p -t '=recover:0' '#{window_name}')" ] ||
	fail "rollback did not restore the empty window name"
[ -z "$(tx display-message -p -t "$ROLLBACK_PANE" '#{pane_title}')" ] ||
	fail "rollback did not restore the empty pane title"
[ -s "$CASE_DIR/concurrent-pane" ] || fail "concurrent pane fixture did not record its ID"
CONCURRENT_PANE="$(cat "$CASE_DIR/concurrent-pane")"
[ "$(tx display-message -p -t "$CONCURRENT_PANE" '#{pane_id}')" = "$CONCURRENT_PANE" ] ||
	fail "rollback removed the concurrent pane"
[ "$(topology keep)" = "$KEEP_BEFORE" ] || fail "failure rollback changed sentinel session"
grep -Fq 'rolling back changes' "$CASE_DIR/failure.err" || fail "rollback message missing"
tx kill-window -t '=recover:1'

INTERRUPT_RESURRECT="$CASE_DIR/interrupt-resurrect"
INTERRUPT_MARKER="$CASE_DIR/restore-ready"
INTERRUPT_CHILD_MARKER="$CASE_DIR/restore-child"
cp -R "$RESURRECT" "$INTERRUPT_RESURRECT"
printf '#!/usr/bin/env bash\n"%s" "$@"\n: >"%s"\nsleep 30 &\nprintf "%%s\\n" "$!" >"%s"\nwait\n' \
	"$RESURRECT/scripts/restore.sh" "$INTERRUPT_MARKER" "$INTERRUPT_CHILD_MARKER" \
	>"$INTERRUPT_RESURRECT/scripts/restore.sh"
chmod +x "$INTERRUPT_RESURRECT/scripts/restore.sh"
TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$INTERRUPT_RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply \
	>"$CASE_DIR/interrupt.out" 2>"$CASE_DIR/interrupt.err" &
recovery_pid=$!
for _ in {1..200}; do
	[ -f "$INTERRUPT_MARKER" ] && [ -s "$INTERRUPT_CHILD_MARKER" ] && break
	sleep 0.05
done
if [ ! -f "$INTERRUPT_MARKER" ] || [ ! -s "$INTERRUPT_CHILD_MARKER" ]; then
	fail "interrupt fixture did not reach the partial restore"
fi
INTERRUPT_CHILD_PID="$(cat "$INTERRUPT_CHILD_MARKER")"
kill -TERM "$recovery_pid"
if wait "$recovery_pid"; then
	fail "interrupted restore returned success"
fi
[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "signal rollback left the restored window"
[ "$(tx list-panes -t '=recover:0' -F '#{pane_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "signal rollback left the restored pane"
[ "$(topology keep)" = "$KEEP_BEFORE" ] || fail "signal rollback changed sentinel session"
grep -Fq 'rolling back changes' "$CASE_DIR/interrupt.err" || fail "signal rollback message missing"
if kill -0 "$INTERRUPT_CHILD_PID" >/dev/null 2>&1; then
	fail "signal cleanup left a restore descendant running"
fi

TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply >"$CASE_DIR/apply.out"

[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "2" ] ||
	fail "apply did not restore both windows"
[ "$(tx list-panes -t '=recover:0' -F '#{pane_index}' | wc -l | tr -d ' ')" = "2" ] ||
	fail "apply did not restore the missing pane"
[ "$(tx display-message -p -t '=recover:0' '#{window_name}')" = "mapping" ] ||
	fail "mapping window name was not restored"
[ "$(tx display-message -p -t '=recover:1' '#{window_name}')" = "data" ] ||
	fail "data window name was not restored"
[ "$(tx display-message -p -t '=recover:0' '#{pane_index}')" = "1" ] ||
	fail "active pane was not restored"
[ "$(tx display-message -p -t '=recover:0' '#{window_zoomed_flag}')" = "1" ] ||
	fail "zoom state was not restored"
[ "$(topology keep)" = "$KEEP_BEFORE" ] || fail "sentinel session changed"
[ "$(tx show-option -wqv -t '=keep:0' @sentinel)" = "untouched" ] ||
	fail "sentinel option changed"
[ "$(tx show-option -gqv @resurrect-dir)" = "$DATA_DIR" ] ||
	fail "resurrect directory option was not restored"
[ "$(tx show-option -gqv @resurrect-capture-pane-contents)" = "off" ] ||
	fail "pane contents option was not restored"
[ "$(tx show-option -gqv @resurrect-processes)" = "false" ] ||
	fail "process option was not restored"
[ "$(tx show-option -gqv @resurrect-hook-pre-restore-all)" = "$HOOK_COMMAND" ] ||
	fail "restore hook option was not restored"
[ -z "$(tx show-option -gqv @workspace-recovery-hook-ran)" ] ||
	fail "restore hook executed"
[ "$(tx show-buffer -b workspace-recovery-sentinel)" = "leave me alone" ] ||
	fail "sentinel buffer changed"
[ "$(readlink "$DATA_DIR/last")" != "$SOURCE_NAME" ] ||
	fail "apply did not create a safety checkpoint"
[ -f "$SOURCE_SNAPSHOT" ] || fail "apply deleted the selected older snapshot"
[ "$(python3 "$ROOT_DIR/scripts/snapshot.py" checksum "$SOURCE_SNAPSHOT")" = "$SOURCE_HASH" ] ||
	fail "apply changed the selected snapshot"
grep -Fq 'Restore complete.' "$CASE_DIR/apply.out" || fail "success output missing"
grep -Fq 'Safety checkpoint:' "$CASE_DIR/apply.out" || fail "checkpoint output missing"

tx kill-session -t '=recover'
rm -f "$CASE_DIR/concurrent-pane"
if TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$FAILING_RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply \
	>"$CASE_DIR/absent-failure.out" 2>"$CASE_DIR/absent-failure.err"; then
	fail "injected absent-session failure returned success"
fi
[ -s "$CASE_DIR/concurrent-pane" ] || fail "absent concurrent pane fixture did not record its ID"
CONCURRENT_PANE="$(cat "$CASE_DIR/concurrent-pane")"
[ "$(tx display-message -p -t "$CONCURRENT_PANE" '#{pane_id}')" = "$CONCURRENT_PANE" ] ||
	fail "absent-session rollback removed the concurrent pane"
[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "1" ] ||
	fail "absent-session rollback left recovery-created windows"
[ "$(topology keep)" = "$KEEP_BEFORE" ] ||
	fail "absent-session failure changed sentinel session"
tx kill-session -t '=recover'
TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply \
	>"$CASE_DIR/absent.out"
[ "$(tx list-windows -t '=recover' -F '#{window_index}' | wc -l | tr -d ' ')" = "2" ] ||
	fail "absent session restore did not create both windows"
[ "$(tx list-panes -s -t '=recover' -F '#{pane_index}' | wc -l | tr -d ' ')" = "3" ] ||
	fail "absent session restore did not create all panes"
[ "$(topology keep)" = "$KEEP_BEFORE" ] || fail "absent restore changed sentinel session"

LAST_BEFORE_GROUPED="$(readlink "$DATA_DIR/last")"
RECOVER_BEFORE_GROUPED="$(topology recover)"
tx new-session -d -t '=recover' -s recover_alias
ALIAS_BEFORE_GROUPED="$(topology recover_alias)"
if TMUX="$SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SOURCE_NAME" --socket "$SOCKET" --apply \
	>"$CASE_DIR/grouped.out" 2>"$CASE_DIR/grouped.err"; then
	fail "live grouped target returned success"
fi
grep -Fq 'is grouped' "$CASE_DIR/grouped.err" || fail "live grouped rejection was not reported"
[ "$(readlink "$DATA_DIR/last")" = "$LAST_BEFORE_GROUPED" ] ||
	fail "live grouped rejection created a safety checkpoint"
[ "$(topology recover)" = "$RECOVER_BEFORE_GROUPED" ] ||
	fail "live grouped rejection changed the target"
[ "$(topology recover_alias)" = "$ALIAS_BEFORE_GROUPED" ] ||
	fail "live grouped rejection changed the grouped alias"

SPECIAL_DATA="$CASE_DIR/special-resurrect"
mkdir "$SPECIAL_DATA"
tmux -S "$SPECIAL_SOCKET" -f /dev/null new-session -d -s recover -n other -c "$CASE_DIR" 'sleep 600'
tmux -S "$SPECIAL_SOCKET" new-session -d -s '=recover' -n intended -c "$CASE_DIR" 'sleep 600'
tmux -S "$SPECIAL_SOCKET" split-window -t '==recover:0' -c "$CASE_DIR" 'sleep 600'
tmux -S "$SPECIAL_SOCKET" set-option -g @resurrect-dir "$SPECIAL_DATA"
tmux -S "$SPECIAL_SOCKET" set-option -g @resurrect-capture-pane-contents off
TMUX="$SPECIAL_SOCKET,0,0" "$RESURRECT/scripts/save.sh" >/dev/null
SPECIAL_SOURCE="$(readlink "$SPECIAL_DATA/last")"
special_pane="$(tmux -S "$SPECIAL_SOCKET" list-panes -t '==recover:0' -F '#{pane_id}' | tail -1)"
tmux -S "$SPECIAL_SOCKET" kill-pane -t "$special_pane"
SPECIAL_TARGET_BEFORE="$(tmux -S "$SPECIAL_SOCKET" list-panes -t '==recover:0' -F '#{pane_id}' | sort)"
SPECIAL_OTHER_BEFORE="$(tmux -S "$SPECIAL_SOCKET" list-panes -t '=recover:0' -F '#{pane_id}' | sort)"
if TMUX="$SPECIAL_SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore '=recover' --snapshot "$SPECIAL_SOURCE" --socket "$SPECIAL_SOCKET" --apply \
	>"$CASE_DIR/special.out" 2>"$CASE_DIR/special.err"; then
	fail "tmux target metacharacter session returned success"
fi
grep -Fq 'unsafe session name' "$CASE_DIR/special.err" ||
	fail "tmux target metacharacter rejection was not reported"
[ "$(tmux -S "$SPECIAL_SOCKET" list-panes -t '==recover:0' -F '#{pane_id}' | sort)" = "$SPECIAL_TARGET_BEFORE" ] ||
	fail "tmux target metacharacter rejection changed the intended session"
[ "$(tmux -S "$SPECIAL_SOCKET" list-panes -t '=recover:0' -F '#{pane_id}' | sort)" = "$SPECIAL_OTHER_BEFORE" ] ||
	fail "tmux target metacharacter rejection changed the similarly named session"

tmux -S "$SPECIAL_SOCKET" kill-server
SPECIAL_PREFIX_DATA="$CASE_DIR/special-prefix-resurrect"
mkdir "$SPECIAL_PREFIX_DATA"
tmux -S "$SPECIAL_SOCKET" -f /dev/null new-session -d -s recover -n intended -c "$CASE_DIR" 'sleep 600'
tmux -S "$SPECIAL_SOCKET" rename-window -t '=recover:0' ''
tmux -S "$SPECIAL_SOCKET" new-session -d -s recover-more -n other -c "$CASE_DIR" 'sleep 600'
tmux -S "$SPECIAL_SOCKET" split-window -t '=recover-more:0' -c "$CASE_DIR" 'sleep 600'
tmux -S "$SPECIAL_SOCKET" set-option -g @resurrect-dir "$SPECIAL_PREFIX_DATA"
tmux -S "$SPECIAL_SOCKET" set-option -g @resurrect-capture-pane-contents off
TMUX="$SPECIAL_SOCKET,0,0" "$RESURRECT/scripts/save.sh" >/dev/null
SPECIAL_PREFIX_SOURCE="$(readlink "$SPECIAL_PREFIX_DATA/last")"
DOT_SOURCE="tmux_resurrect_20260906T235959_dot.txt"
awk 'BEGIN { FS=OFS="\t" } ($1 == "pane" || $1 == "window") && $2 == "recover" { $2="foo.bar" } { print }' \
	"$SPECIAL_PREFIX_DATA/$SPECIAL_PREFIX_SOURCE" >"$SPECIAL_PREFIX_DATA/$DOT_SOURCE"
if TMUX="$SPECIAL_SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore foo.bar --snapshot "$DOT_SOURCE" --socket "$SPECIAL_SOCKET" --apply \
	>"$CASE_DIR/dot.out" 2>"$CASE_DIR/dot.err"; then
	fail "session name canonicalized by tmux returned success"
fi
grep -Fq 'unsafe session name' "$CASE_DIR/dot.err" ||
	fail "canonicalized session name rejection was not reported"
if tmux -S "$SPECIAL_SOCKET" has-session -t '=foo_bar' 2>/dev/null; then
	fail "canonicalized session rejection left an unintended session"
fi
SPECIAL_PREFIX_OTHER_BEFORE="$(tmux -S "$SPECIAL_SOCKET" list-panes -s -t '=recover-more' \
	-F '#{window_index}|#{window_name}|#{window_layout}|#{pane_index}|#{pane_id}' | sort)"
tmux -S "$SPECIAL_SOCKET" kill-session -t '=recover'
TMUX="$SPECIAL_SOCKET,0,0" RESURRECT_PLUGIN_PATH="$RESURRECT" \
	"$RECOVERY" restore recover --snapshot "$SPECIAL_PREFIX_SOURCE" --socket "$SPECIAL_SOCKET" --apply \
	>"$CASE_DIR/special-prefix.out"
tmux -S "$SPECIAL_SOCKET" has-session -t '=recover' ||
	fail "exact target restore did not recreate the intended prefix session"
[ -z "$(tmux -S "$SPECIAL_SOCKET" display-message -p -t '=recover:0' '#{window_name}')" ] ||
	fail "exact target restore did not preserve the empty saved window name"
[ "$(tmux -S "$SPECIAL_SOCKET" list-panes -s -t '=recover-more' \
	-F '#{window_index}|#{window_name}|#{window_layout}|#{pane_index}|#{pane_id}' | sort)" = "$SPECIAL_PREFIX_OTHER_BEFORE" ] ||
	fail "exact target restore changed a session with the same prefix"

printf 'PASS: targeted restore preserved the sentinel session\n'
