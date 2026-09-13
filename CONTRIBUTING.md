# Contributing

## Release profile

**Plugin or local tool.** TPM installs it by cloning the repository, so there is
no package registry or generated release artifact. Consumers can pin a tag or
commit.

The project lives in `cosential/tmux-plugins`. If it moves again, transfer the
existing GitLab project instead of creating a replacement. A namespace transfer
preserves repository history, issues, tags, and releases. Update documented and
consuming repository URLs after the move.

## Deferred from the dev-tools baseline

These items are intentionally deferred while the plugin has one maintainer and
no publication target:

| Item | Why deferred |
| --- | --- |
| Automatic versioning and releases | TPM clones the repository and there is no separate artifact to publish |
| `CHANGELOG.md` | Add it with versioned releases when consumers need stable tags |
| `mise.toml` | The repository has no dependencies and the validation commands are short |
| `docs/NAVIGATOR.md` | The README remains the complete user entry point |
| `.vscode/` | There is no useful project-specific debug entry point |
| Release badge | There are no releases yet; the pipeline badge lives in GitLab project metadata |

## Local workflow

Work from `master` unless a task calls for a branch. Open a merge request for
shared changes and use a Conventional Commit title.

The validation commands are:

```bash
shellcheck --shell=bash workspace-recovery.tmux scripts/workspace-recovery \
  scripts/tmux-socket-proxy scripts/session-lifecycle \
  scripts/workspace-recovery-scheduler tests/integration/*.sh
bash -n workspace-recovery.tmux scripts/workspace-recovery \
  scripts/tmux-socket-proxy scripts/session-lifecycle \
  scripts/workspace-recovery-scheduler tests/integration/*.sh
python3 -m py_compile scripts/snapshot.py scripts/process-group.py
python3 -m unittest discover -s tests -p 'test_*.py'
RESURRECT_PLUGIN_PATH="$HOME/.config/tmux/plugins/tmux-resurrect" \
  tests/integration/run.sh
RESURRECT_PLUGIN_PATH="$HOME/.config/tmux/plugins/tmux-resurrect" \
  tests/integration/session-lifecycle.sh
tests/integration/scheduler.sh
```

## Recovery invariants

Changes must preserve these contracts:

- `restore` is a dry run unless the caller supplies `--apply`.
- A real restore stages and publishes the full live server before its first
  recovery mutation without exposing the selected source to archive rotation.
- Apply uses the exact checksum printed by the immediately preceding preview.
- Snapshot selection uses exact session names and never evaluates snapshot text.
- The filtered restore file contains only pane and window records for the target.
- Captured pane contents, save and restore hooks, client switching, tmux command
  separators, and tmux kill commands stay disabled inside upstream restore.
- Existing panes remain alive. Missing panes and windows may be created.
- Safety overrides stay process-local and never expose the private restore
  directory through a global tmux option.
- A failed or interrupted restore rolls back only journaled tmux object IDs.
- Non-target sessions retain their window and pane topology.

The restore path is a controlled change. New behavior needs parser tests and a
throwaway-socket integration test, including its material failure case.

Scheduler installation is always opt-in. TPM startup must never install, load,
enable, or remove a host service. Generated launchd and systemd files must call
the plugin by its absolute installed path, carry an absolute tmux path, and use
the lifecycle lock rather than allowing overlapping saves.

## Testing against tmux

Never exercise recovery development against your daily tmux server. Use the
integration harness or start a dedicated socket under `~/tmp`:

```bash
mkdir -p "$HOME/tmp"
case_dir="$(mktemp -d "$HOME/tmp/tmux-workspace-recovery.XXXXXX")"
tmux -S "$case_dir/tmux.sock" -f /dev/null new-session -d -s scratch
```

The integration suite owns its generated socket and removes it when the test
ends. See [tests/README.md](tests/README.md) for the complete workflow.
