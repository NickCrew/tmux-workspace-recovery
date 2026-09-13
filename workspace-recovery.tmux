#!/usr/bin/env bash
# tmux-workspace-recovery: TPM entry point.

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux_option() {
	local value
	value="$(tmux show-option -gqv "$1" 2>/dev/null)"
	if [ -n "$value" ]; then printf '%s' "$value"; else printf '%s' "$2"; fi
}

KEY="$(tmux_option '@workspace-recovery-key' '')"
WIDTH="$(tmux_option '@workspace-recovery-popup-width' '80%')"
HEIGHT="$(tmux_option '@workspace-recovery-popup-height' '70%')"
printf -v PICKER '%q pick' "$CURRENT_DIR/scripts/workspace-recovery"

tmux set-option -g @workspace_recovery_command "$CURRENT_DIR/scripts/workspace-recovery"
tmux set-option -g @workspace_recovery_lifecycle_command "$CURRENT_DIR/scripts/session-lifecycle"
tmux set-option -g @workspace_recovery_scheduler_command "$CURRENT_DIR/scripts/workspace-recovery-scheduler"

if [ -n "$KEY" ]; then
	tmux bind-key -N 'Recover one saved session' "$KEY" display-popup -E -w "$WIDTH" -h "$HEIGHT" \
		-T ' Workspace recovery ' "$PICKER"
fi
