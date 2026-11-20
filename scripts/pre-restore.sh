#!/usr/bin/env bash
# tmux-resurrect pre-restore-all hook: marks that a restore has started (see
# scripts/restore-safety-net.sh), notes the panes already there, which get nothing typed
# (scripts/type-commands.sh), makes sure `last` is a save with panes (resurrect reads it after
# this hook, but checks that it exists before: tmux-restore.tmux mends it as it loads too;
# scripts/mend-last.sh), makes the session and window names in it safe for a save made before
# tmux-restore did that on every save (scripts/safe-names.sh), then runs the hook you had before
# tmux-restore, if any.
tmux set-option -g @tmux-restore-restored 1
tmux set-option -g @tmux-restore-existing "$(tmux list-panes -a -F '#{pane_id}' 2> /dev/null | tr '\n' ' ')"
"$(dirname "$0")/mend-last.sh"
# shellcheck source=scripts/saves-dir.sh
. "$(dirname "$0")/saves-dir.sh"
"$(dirname "$0")/safe-names.sh" "$(saves_dir)/last"
next=$(tmux show-option -gqv @tmux-restore-next-pre-restore-hook)
[ -n "$next" ] && eval "$next"
exit 0
