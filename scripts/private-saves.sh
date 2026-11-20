#!/usr/bin/env bash
# private-saves.sh: only you can read tmux-resurrect's saves. Each one holds every pane's command
# line, and pane_contents.tar.gz what each pane showed, a password or token included (the security
# review's finding 3); resurrect writes them with your umask, usually readable by others. Run by
# tmux-restore.tmux as it loads, so the folder is private before resurrect first saves into it,
# and after every save by the post-save-all hook (scripts/post-save.sh).
# shellcheck source=scripts/saves-dir.sh
. "$(dirname "$0")/saves-dir.sh"
dir=$(saves_dir)
mkdir -p -m 700 "$dir" 2> /dev/null
chmod 700 "$dir" 2> /dev/null
for f in "$dir"/tmux_resurrect_*.txt "$dir"/pane_contents.tar.gz; do
	[ -f "$f" ] && chmod 600 "$f" 2> /dev/null
done
exit 0
