#!/usr/bin/env bash
# tmux-resurrect post-save-all hook: makes sure `last` is a save with panes after every save,
# whoever made it (scripts/mend-last.sh), then runs the hook you had before tmux-restore, if any.
"$(dirname "$0")/mend-last.sh"
next=$(tmux show-option -gqv @tmux-restore-next-post-save-hook)
[ -n "$next" ] && eval "$next"
exit 0
