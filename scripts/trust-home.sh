#!/usr/bin/env bash
# Started in the background by scripts/post-restore.sh after a restore, when the option
# @tmux-restore-trust-home is on. Claude Code asks whether to trust the folder it works in, and for
# the home folder it never keeps the answer ("This is your home folder, so Yes lasts for this
# session only"), so every restored session working in $HOME would wait at that prompt, out of
# reach of the Claude app. For 2 minutes, this answers "Yes, I trust this folder" in panes that
# work in $HOME and show exactly that prompt for $HOME, and logs each one. Nothing else is touched:
# other folders, other prompts, other panes. A command can be typed later than that, once a
# question at shell startup is answered (scripts/type-commands.sh): this keeps watching while
# commands wait to be typed, and for 2 minutes after the last one.
# Runs with macOS's bash 3.2 too.
secs=${TMUX_RESTORE_TRUST_SECS:-120}
log=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore/trust.log
handled=" "
end=$((SECONDS + secs))

# flat SCREEN: the screen as one line, every run of spaces and line breaks made one space. Claude
# Code wraps its own text to the pane's width (80 columns with no client attached), so a phrase
# can be split across lines.
flat() {
	local IFS=$' \t\n' words
	read -rd '' -a words <<< "$1"
	printf '%s' "${words[*]}"
}

# home_prompt SCREEN: SCREEN is the trust prompt for $HOME, with "No, exit" selected
home_prompt() {
	local screen folder
	screen=$(flat "$1")
	[[ $screen == *"Accessing workspace: "* && $screen == *"This is your home folder"* ]] || return 1
	[[ $screen == *"❯ No, exit"* && $screen == *"Yes, I trust this folder"* ]] || return 1
	[[ $screen != *"❯ Yes, I trust this folder"* ]] || return 1
	folder=${screen#*Accessing workspace: } folder=${folder%% *}
	[[ $folder == "$HOME" ]]
}

# exact PANE_PID: the Claude Code in the pane reopens a given conversation (--resume <id> or
# --session-id <id>). A plain `claude` or `claude --continue` in $HOME would open whichever
# conversation was last there, maybe one already open in another pane: left at the prompt.
exact() {
	local child
	for child in $(pgrep -P "$1" 2> /dev/null) "$1"; do
		case " $(ps -o args= -p "$child" 2> /dev/null) " in
		*" --resume "[!-]* | *" --resume="?* | *" -r "[!-]* | *" --session-id "[!-]* | *" --session-id="?*) return 0 ;;
		esac
	done
	return 1
}

note() {
	mkdir -p "$(dirname "$log")" && chmod 700 "$(dirname "$log")"
	echo "$(date '+%F %T') $(tmux display-message -p -t "$1" '#{session_name}') $1 $2" >> "$log"
}

# more: keep watching
more() {
	((SECONDS < end)) && return 0
	local last typing
	last=$(tmux show-option -gqv @tmux-restore-last-typed)
	[[ $last =~ ^[0-9]+$ ]] && (($(date +%s) - last < secs)) && return 0
	typing=$(tmux show-option -gqv @tmux-restore-typing)
	[[ -n $typing ]] && kill -0 "$typing" 2> /dev/null || return 1
	sleep 4 # nothing typed lately: look less often
}

while more; do
	while IFS=$'\t' read -r pane path pid; do
		[[ $path == "$HOME" && $handled != *" $pane "* ]] || continue
		home_prompt "$(tmux capture-pane -p -t "$pane")" || continue
		handled+="$pane "
		if ! exact "$pid"; then
			note "$pane" "left alone: its claude doesn't reopen a given conversation (--resume)"
			continue
		fi
		tmux send-keys -t "$pane" Down
		sleep 0.5
		if [[ $(flat "$(tmux capture-pane -p -t "$pane")") == *"❯ Yes, I trust this folder"* ]]; then
			tmux send-keys -t "$pane" Enter
			note "$pane" "trusted $HOME (Claude Code's home folder prompt, after a restore)"
		else
			note "$pane" "left alone: the prompt's menu didn't move to Yes"
		fi
	done < <(tmux list-panes -a -F $'#{pane_id}\t#{pane_current_path}\t#{pane_pid}')
	sleep 1
done
