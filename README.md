![tmux-workspace-recovery: Restore one tmux session. Leave the rest alone.](assets/readme-banner.webp)

# tmux-workspace-recovery

Restore one tmux session without feeding the rest of your server to a global
restore script.

For installations that need dependable snapshots, the plugin also ships an
opt-in full-server save scheduler and a coordinated workspace-startup command.

tmux-resurrect is very good at rebuilding an entire server. That is not always
the job in front of you. If someone closes eight windows from one session while
four other sessions are still useful, `prefix C-r` has a much wider blast radius
than the repair requires.

This plugin previews one saved session, extracts only its pane and window
records, creates a safety checkpoint, restores the missing pieces, and verifies
that every other session kept the same topology.

## Safety model

The default command is a dry run. An applied restore adds a few more controls:

- Binds the checksum shown in the preview to the applied restore.
- Copies the selected snapshot into a private temporary directory before saving
  anything.
- Stages a full-server checkpoint outside the rolling archive, then publishes it
  under a collision-free name without pruning older snapshots.
- Disables captured pane contents because the rolling archive may not match an
  older layout snapshot.
- Suppresses tmux-resurrect restore hooks and client switching.
- Limits the upstream restore process to an explicit set of tmux commands and
  rejects destructive shorthand aliases, separators, and every kill command.
- Preserves existing panes, then creates only the missing panes and windows.
- Supplies safety options only to the private save and restore processes, so
  global tmux-resurrect options remain unchanged.
- Verifies names, pane counts, compatible layouts, active panes, and zoom state,
  then compares every other session before and after the restore.

The proxy records the stable pane ID created by every session, window, and pane
operation. If verification fails or the command is interrupted, rollback removes
only those recorded panes, then reapplies the target session's previous names
and layouts. A created parent disappears when its last recovery pane is removed,
but remains when it contains a concurrent user-created pane. The safety
checkpoint remains in the normal tmux-resurrect directory.

## Requirements

- tmux 3.2 or newer
- [TPM](https://github.com/tmux-plugins/tpm)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- Python 3.9 or newer
- Bash
- fzf, only for the popup picker

### Platforms

macOS and WSL are the intended environments. Native Windows is not supported
because tmux does not run there. Local validation qualifies macOS, and CI is
configured for a Debian container. WSL still needs a direct exercise.

## Install

Declare tmux-resurrect first, then this plugin, above TPM's run line:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'git@github.com:NickCrew/tmux-plugins/tmux-workspace-recovery.git'

run -b '~/.tmux/plugins/tpm/tpm'
```

Press `prefix I` to install the plugins. The SSH identity running TPM needs
project access.

No keys are claimed by default. Name one if you want the bordered popup picker:

```tmux
set -g @workspace-recovery-key 'R'
```

With that option, `prefix R` opens a snapshot picker, followed by a session
picker and an exact-name confirmation prompt.

Installing the plugin does not create or enable a background service. Host
scheduling is always a separate, explicit step.

## Automatic snapshots and workspace startup

The optional lifecycle command saves the complete tmux server through
tmux-resurrect and records success metadata under
`~/.local/state/tmux-workspace-recovery/lifecycle`. It skips cleanly when no
tmux server is running and coalesces overlapping saves with a per-socket lock.

Install a ten-minute per-user scheduler on macOS or Linux:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery-scheduler install
```

The macOS installer generates and loads
`~/Library/LaunchAgents/com.atlascrew.tmux-workspace-recovery.save.plist`. On
Linux, it generates and enables `tmux-workspace-recovery-save.timer` under the
systemd user directory. Neither scheduler restores sessions or starts a tmux
server. They only save an already-running server.

Choose a different interval, expressed in seconds, at installation time:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery-scheduler \
  install --interval 900
```

Inspect or remove the scheduler with:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery-scheduler status
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery-scheduler uninstall
```

The installer detects and embeds the absolute tmux and plugin paths. It refuses
to replace a service file it did not generate. Use `--no-enable` to generate
the files without loading or enabling them.

For Linux or WSL installations without a usable systemd user manager, print a
cron entry and add it manually with `crontab -e`:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery-scheduler \
  cron --interval 600
```

The command only prints the entry. It never modifies the crontab. Cron fallback
intervals must be whole minutes between one and 59 minutes.

Check snapshot freshness, checksum binding, the latest save error, and whether
the current tmux server has been saved:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/session-lifecycle health
```

The command exits nonzero when an active server has no current successful save,
the latest scheduled attempt failed, the snapshot changed after saving, or the
last success is older than twice the configured scheduler interval. A manual
save uses the same lock and health metadata:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/session-lifecycle save
```

Workspace launchers can coordinate one full restore before attaching several
tabs. For example, each Ghostty or Raycast tab can call the same command with a
different session name:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/session-lifecycle attach Platform
```

The first caller starts a temporary tmux server when necessary and restores the
latest valid snapshot. Concurrent callers wait on the same lock, then attach to
their requested sessions after that single restore completes. A missing
snapshot is a normal first-run state. An invalid snapshot or failed restore is
reported and stops attachment instead of silently creating an empty workspace.
Lifecycle session names may contain letters, numbers, underscores, and hyphens.

Full startup restore follows the global tmux-resurrect process configuration,
including `@resurrect-processes`. Review those commands before using `attach`.
This differs from the targeted restore command, which leaves process recovery
off unless `@workspace-recovery-restore-processes` is explicitly enabled.

## Recover a session

List the available snapshots:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery list
```

Preview the latest saved version of session `0`:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery \
  preview 0
```

The plan reports the source path and SHA-256 checksum, saved and live counts,
missing windows and panes, the number of existing layouts that will be updated,
and whether process restoration is enabled.

Apply the plan only after reading it:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery \
  restore 0 --apply
```

Choose an older snapshot by filename:

```bash
~/.tmux/plugins/tmux-workspace-recovery/scripts/workspace-recovery \
  restore 0 --snapshot tmux_resurrect_20260905T224347.txt --apply
```

Snapshot names must resolve inside the configured tmux-resurrect directory.
Symlinks that leave that directory, malformed files, duplicate records, unsafe
session names, and grouped sessions fail before tmux changes.

Literal-safe session names start with a Unicode letter, number, or underscore.
The remaining characters may also contain spaces and hyphens. Names with tmux
target metacharacters or dots are rejected because the pinned upstream restore
builds tmux targets from the saved name, and tmux canonicalizes dots to
underscores during session creation.

## Restore processes

The safe default restores layouts, names, panes, windows, and working
directories. It does not run saved processes.

To use the process strategies already configured for tmux-resurrect:

```tmux
set -g @workspace-recovery-restore-processes 'on'
```

Review `@resurrect-processes` before enabling this. tmux-resurrect sends those
commands into newly created panes. Existing panes and their processes are never
replaced.

Agent restoration remains best-effort when a strategy uses `claude --continue`
or `codex resume --last`. Both select by recent history rather than an exact
conversation ID, so several panes in one working directory can collide or open
the wrong conversation. Layout recovery does not depend on agent recovery.

## Commands

| Command | Behavior |
| --- | --- |
| `list` | Show snapshots with session, window, and pane counts |
| `preview SESSION` | Describe a targeted restore without changing tmux |
| `restore SESSION` | Print the same dry-run plan |
| `restore SESSION --apply` | Save, apply, and verify the targeted restore |
| `pick` | Choose a snapshot and session through fzf, then confirm by exact name |
| `doctor` | Show the active socket, plugin path, snapshot directory, and safety defaults |

`--snapshot NAME` selects a file from the resurrect directory. `--socket PATH`
targets a specific tmux socket and is useful for testing or repairing a server
that is not your current one.

## Options

Set options before TPM loads the plugin.

| Option | Default | Meaning |
| --- | --- | --- |
| `@workspace-recovery-key` | unset | Prefix key for the popup picker |
| `@workspace-recovery-popup-width` | `80%` | Picker width |
| `@workspace-recovery-popup-height` | `70%` | Picker height |
| `@workspace-recovery-restore-processes` | `off` | Use configured tmux-resurrect process strategies |
| `@workspace-recovery-resurrect-path` | auto-detected | Explicit tmux-resurrect plugin directory |

The TPM entry point also publishes the resolved executable path as
`@workspace_recovery_command` for custom bindings. It publishes the lifecycle
and scheduler paths as `@workspace_recovery_lifecycle_command` and
`@workspace_recovery_scheduler_command`.

## What changes during restore

For the selected session, the plugin may:

- Create saved windows that no longer exist.
- Add saved panes missing from an existing window.
- Reapply saved window names, active panes, and zoom state.
- Reapply a saved layout when the live and saved pane counts match. Verification
  checks the split topology because tmux rescales dimensions to the current
  window size. Extra live panes are preserved, so their window keeps its current
  compatible layout.
- Start configured processes in newly created panes when process restoration is
  explicitly enabled.

It does not remove extra live windows or panes. Grouped sessions are rejected in
the first release because restoring one member can mutate another session.

## Storage and privacy

tmux-resurrect snapshots contain working directories, titles, and process
commands. Keep the snapshot directory private. This plugin creates temporary
files with mode `0600` under a mode `0700` directory in `~/tmp`, then removes
them after the command ends.

Captured pane contents are always disabled during targeted restore. This avoids
mixing one layout snapshot with tmux-resurrect's single rolling contents archive,
and it prevents stale terminal output from being replayed into recovered panes.

## Development

Run the same checks as CI:

```bash
shellcheck --shell=bash workspace-recovery.tmux scripts/workspace-recovery \
  scripts/tmux-socket-proxy tests/integration/run.sh
bash -n workspace-recovery.tmux scripts/workspace-recovery \
  scripts/tmux-socket-proxy tests/integration/run.sh
python3 -m py_compile scripts/snapshot.py scripts/process-group.py
python3 -m unittest discover -s tests -p 'test_*.py'
RESURRECT_PLUGIN_PATH="$HOME/.config/tmux/plugins/tmux-resurrect" \
  tests/integration/run.sh
```

The integration test owns a throwaway tmux socket under `~/tmp`. It saves two
sessions, removes part of one, runs the real tmux-resurrect restore through the
plugin's safety proxy, and proves the sentinel session did not move.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the recovery invariants and release
workflow.
