# Tests

The suite separates snapshot parsing from live tmux behavior.

## Unit tests

`test_snapshot.py` checks the tmux-resurrect record boundary: exact session
matching, field and layout validation, duplicate detection, grouped-session
rejection, filtering, file permissions, path containment, layout comparison,
and collision-free checkpoint publication.

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

## Integration test

The integration test starts a tmux server on a unique socket under `~/tmp`. It
creates a sentinel session and a recovery session, saves both through the real
tmux-resurrect plugin, removes one pane and one window, and restores only the
recovery session. It covers the proxy command boundary, live grouped-session
refusal, older-source retention, rollback during failure and signal interruption,
concurrent user changes, concurrent tmux-resurrect saves, window-size changes,
target metacharacter rejection, restore-process cleanup, active pane and zoom
verification, partial-session repair, and full-session recreation. Each path
compares the sentinel topology byte for byte.

```bash
RESURRECT_PLUGIN_PATH="$HOME/.config/tmux/plugins/tmux-resurrect" \
  tests/integration/run.sh
```

The test kills only its own tmux server and removes only its generated directory.

`session-lifecycle.sh` exercises serialized saves, one-time startup restore,
failure visibility, snapshot checksum binding, current-server health, and
concurrent workspace preparation against another private socket.

`scheduler.sh` renders and validates the launchd plist and systemd user units,
then exercises install, status, uninstall, interval propagation, and cron
output inside disposable home directories. Fake service-manager executables
record the requested operations; the generated files and lifecycle behavior
remain real.
