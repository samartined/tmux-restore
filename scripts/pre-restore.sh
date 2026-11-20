#!/usr/bin/env bash
# tmux-resurrect pre-restore-all hook: marks that a restore has started (see
# scripts/restore-safety-net.sh), notes the panes already there, which get nothing typed
# (scripts/type-commands.sh), makes sure `last` is a save with panes (resurrect reads it only
# after this hook; scripts/mend-last.sh), then runs the hook you had before tmux-restore, if any.
tmux set-option -g @tmux-restore-restored 1
tmux set-option -g @tmux-restore-existing "$(tmux list-panes -a -F '#{pane_id}' 2> /dev/null | tr '\n' ' ')"
"$(dirname "$0")/mend-last.sh"
next=$(tmux show-option -gqv @tmux-restore-next-pre-restore-hook)
[ -n "$next" ] && eval "$next"
exit 0
