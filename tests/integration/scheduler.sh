#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scheduler="$root_dir/scripts/workspace-recovery-scheduler"
mkdir -p "$HOME/tmp"
test_root=$(mktemp -d "$HOME/tmp/tmux-workspace-scheduler-test.XXXXXX")
bin_dir="$test_root/bin"
manager_log="$test_root/manager.log"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local fragment=$2
  local label=$3
  grep -Fq "$fragment" "$file" || fail "$label: missing '$fragment'"
}

mkdir -p "$bin_dir"
special_tmux_dir="$test_root/tmux & <special>"
mkdir -p "$special_tmux_dir"
printf '#!/usr/bin/env bash\nexit 0\n' >"$special_tmux_dir/tmux"
chmod +x "$special_tmux_dir/tmux"
cat >"$bin_dir/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf '%s\n' "$TEST_PLATFORM"
FAKE_UNAME
cat >"$bin_dir/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$MANAGER_LOG"
FAKE_LAUNCHCTL
cat >"$bin_dir/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MANAGER_LOG"
FAKE_SYSTEMCTL
chmod +x "$bin_dir/uname" "$bin_dir/launchctl" "$bin_dir/systemctl"

mac_home="$test_root/mac-home"
mkdir -p "$mac_home"
env HOME="$mac_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Darwin \
  TMUX_BIN="$special_tmux_dir/tmux" \
  MANAGER_LOG="$manager_log" "$scheduler" install --interval 300
plist="$mac_home/Library/LaunchAgents/com.atlascrew.tmux-workspace-recovery.save.plist"
[[ -f $plist ]] || fail "macOS install writes the LaunchAgent"
python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$plist" ||
  fail "generated LaunchAgent is valid"
python3 -c 'import plistlib, sys; data=plistlib.load(open(sys.argv[1], "rb")); assert data["EnvironmentVariables"]["TMUX_BIN"] == sys.argv[2]' \
  "$plist" "$special_tmux_dir/tmux" || fail "LaunchAgent preserves XML-sensitive paths"
assert_contains "$plist" '<integer>300</integer>' "LaunchAgent uses the requested interval"
assert_contains "$plist" '<string>600</string>' "LaunchAgent health age follows the interval"
assert_contains "$plist" "$root_dir/scripts/session-lifecycle" \
  "LaunchAgent calls the installed plugin"
assert_contains "$manager_log" 'launchctl bootstrap' "macOS install loads the LaunchAgent"
assert_contains "$manager_log" 'launchctl kickstart -k' "macOS install starts an initial save"

env HOME="$mac_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Darwin \
  MANAGER_LOG="$manager_log" "$scheduler" status >/dev/null
assert_contains "$manager_log" 'launchctl print' "macOS status queries launchd"
env HOME="$mac_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Darwin \
  MANAGER_LOG="$manager_log" "$scheduler" uninstall
[[ ! -e $plist ]] || fail "macOS uninstall removes the generated LaunchAgent"
assert_contains "$manager_log" 'launchctl bootout' "macOS uninstall unloads the LaunchAgent"
: >"$manager_log"
env HOME="$mac_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Darwin \
  TMUX_BIN="$special_tmux_dir/tmux" MANAGER_LOG="$manager_log" \
  "$scheduler" install --no-enable >/dev/null
[[ -f $plist ]] || fail "macOS no-enable install still renders the LaunchAgent"
[[ ! -s $manager_log ]] || fail "macOS no-enable install does not call launchctl"
env HOME="$mac_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Darwin \
  MANAGER_LOG="$manager_log" "$scheduler" uninstall >/dev/null
printf 'not managed by this plugin\n' >"$plist"
if env HOME="$mac_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Darwin \
    MANAGER_LOG="$manager_log" "$scheduler" uninstall >/dev/null 2>&1; then
  fail "macOS uninstall removed an unmanaged LaunchAgent"
fi
[[ -f $plist ]] || fail "unmanaged LaunchAgent remains after refused uninstall"
rm -f -- "$plist"

linux_home="$test_root/linux-home"
linux_config="$test_root/linux-config"
mkdir -p "$linux_home"
: >"$manager_log"
env HOME="$linux_home" XDG_CONFIG_HOME="$linux_config" PATH="$bin_dir:$PATH" \
  TEST_PLATFORM=Linux MANAGER_LOG="$manager_log" TMUX_BIN="$special_tmux_dir/tmux" \
  "$scheduler" install --interval 900
service="$linux_config/systemd/user/tmux-workspace-recovery-save.service"
timer="$linux_config/systemd/user/tmux-workspace-recovery-save.timer"
[[ -f $service && -f $timer ]] || fail "Linux install writes the user service and timer"
assert_contains "$service" "$root_dir/scripts/session-lifecycle" \
  "systemd service calls the installed plugin"
assert_contains "$service" "$special_tmux_dir/tmux" \
  "systemd service preserves a quoted tmux path"
assert_contains "$service" 'TMUX_SAVE_MAX_AGE_SECONDS=1800' \
  "systemd health age follows the interval"
assert_contains "$timer" 'OnUnitActiveSec=900s' "systemd timer uses the requested interval"
assert_contains "$manager_log" 'systemctl --user daemon-reload' "Linux install reloads user units"
assert_contains "$manager_log" 'systemctl --user enable --now tmux-workspace-recovery-save.timer' \
  "Linux install enables the timer"

env HOME="$linux_home" XDG_CONFIG_HOME="$linux_config" PATH="$bin_dir:$PATH" \
  TEST_PLATFORM=Linux MANAGER_LOG="$manager_log" "$scheduler" status >/dev/null
assert_contains "$manager_log" 'systemctl --user status tmux-workspace-recovery-save.timer' \
  "Linux status queries the user timer"
env HOME="$linux_home" XDG_CONFIG_HOME="$linux_config" PATH="$bin_dir:$PATH" \
  TEST_PLATFORM=Linux MANAGER_LOG="$manager_log" "$scheduler" uninstall
[[ ! -e $service && ! -e $timer ]] || fail "Linux uninstall removes generated units"
assert_contains "$manager_log" 'systemctl --user disable --now tmux-workspace-recovery-save.timer' \
  "Linux uninstall disables the timer"

cron_output=$(env HOME="$linux_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Linux \
  "$scheduler" cron --interval 420)
[[ $cron_output == '*/7 '* ]] || fail "cron fallback converts seconds to minutes"
[[ $cron_output == *'TMUX_SAVE_MAX_AGE_SECONDS=840'* ]] ||
  fail "cron fallback configures the health age"
[[ $cron_output == *"$root_dir/scripts/session-lifecycle"* ]] ||
  fail "cron fallback calls the installed plugin"
if env HOME="$linux_home" PATH="$bin_dir:$PATH" TEST_PLATFORM=Linux \
    "$scheduler" cron --interval 421 >/dev/null 2>&1; then
  fail "cron fallback rejects sub-minute remainders"
fi

printf 'PASS: opt-in scheduler integration\n'
