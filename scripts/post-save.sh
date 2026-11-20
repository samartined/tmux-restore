#!/usr/bin/env bash
# tmux-resurrect post-save-all hook: makes sure `last` is a save with panes after every save,
# whoever made it (scripts/mend-last.sh), that only you can read the saves, which resurrect writes
# with your umask (scripts/private-saves.sh), then runs the hook you had before tmux-restore, if any.
"$(dirname "$0")/mend-last.sh"
"$(dirname "$0")/private-saves.sh"
next=$(tmux show-option -gqv @tmux-restore-next-post-save-hook)
[ -n "$next" ] && eval "$next"
exit 0
