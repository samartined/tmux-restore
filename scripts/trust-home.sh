#!/usr/bin/env bash
# Started in the background by scripts/post-restore.sh after a restore, when the option
# @tmux-restore-trust-home is on. Claude Code asks whether to trust the folder it works in, and for
# the home folder it never keeps the answer ("This is your home folder, so Yes lasts for this
# session only"), so every restored session working in $HOME would wait at that prompt, out of
# reach of the Claude app. For 2 minutes, this answers "Yes, I trust this folder" in panes that
# work in $HOME and show exactly that prompt for $HOME, and logs each one. Nothing else is touched:
# other folders, other prompts, other panes.
# Runs with macOS's bash 3.2 too.
secs=${TMUX_RESTORE_TRUST_SECS:-120}
log=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore/trust.log
handled=" "
end=$((SECONDS + secs))

# home_prompt SCREEN: SCREEN is the trust prompt for $HOME, with "No, exit" selected
home_prompt() {
	local screen=$1 line folder=""
	[[ $screen == *"Accessing workspace:"* && $screen == *"This is your home folder"* ]] || return 1
	[[ $screen == *"❯ No, exit"* && $screen == *"   Yes, I trust this folder"* ]] || return 1
	while IFS= read -r line; do
		line=${line#"${line%%[![:space:]]*}"} line=${line%"${line##*[![:space:]]}"}
		[[ $line == /* ]] && { folder=$line; break; }
	done <<< "${screen#*Accessing workspace:}"
	[[ $folder == "$HOME" ]]
}

note() {
	mkdir -p "$(dirname "$log")" && chmod 700 "$(dirname "$log")"
	echo "$(date '+%F %T') $(tmux display-message -p -t "$1" '#{session_name}') $1 $2" >> "$log"
}

while ((SECONDS < end)); do
	while IFS=$'\t' read -r pane path; do
		[[ $path == "$HOME" && $handled != *" $pane "* ]] || continue
		home_prompt "$(tmux capture-pane -p -t "$pane")" || continue
		handled+="$pane "
		tmux send-keys -t "$pane" Down
		sleep 0.5
		if [[ $(tmux capture-pane -p -t "$pane") == *"❯ Yes, I trust this folder"* ]]; then
			tmux send-keys -t "$pane" Enter
			note "$pane" "trusted $HOME (Claude Code's home folder prompt, after a restore)"
		else
			note "$pane" "left alone: the prompt's menu didn't move to Yes"
		fi
	done < <(tmux list-panes -a -F $'#{pane_id}\t#{pane_current_path}')
	sleep 1
done
