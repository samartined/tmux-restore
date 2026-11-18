#!/usr/bin/env bash
# tmux-resurrect post-restore-all hook: with @tmux-restore-trust-home on, answers Claude Code's
# home-folder trust prompt in the restored panes (scripts/trust-home.sh, in the background, as
# the restored programs are still starting), then runs the hook you had before tmux-restore.
if [ "$(tmux show-option -gqv @tmux-restore-trust-home)" = on ]; then
	nohup "${TMUX_RESTORE_TRUST_HOME_SCRIPT:-$(dirname "$0")/trust-home.sh}" > /dev/null 2>&1 &
fi
next=$(tmux show-option -gqv @tmux-restore-next-post-restore-hook)
[ -n "$next" ] && eval "$next"
exit 0
