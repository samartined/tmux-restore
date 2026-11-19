#!/usr/bin/env bash
# Started in the background by scripts/post-restore.sh after a restore. Types the commands the
# save hook wrote, the ones starting with TMUX_RESTORE=1 (a coding agent reopening its
# conversation, a venv, a command put back on the prompt), each once its pane's shell is ready.
# tmux-resurrect types a program as soon as its pane exists, and if the shell's startup asks
# something first, that question gets the keys instead and the command is lost. That happens to
# anyone whose startup files run keychain or ssh-add when tmux starts at boot, before anyone logs
# in: "Enter passphrase" takes the command as the passphrase.
# A shell is ready when it's the only program in its terminal's foreground and the screen has
# been still for a moment (a few seconds more if it keeps changing, as a prompt with a clock
# does). A pane waits as long as it needs to, an answer typed hours later included. Until then its
# command is in the pane option @tmux-restore-pending, which saves keep (scripts/save-hook.sh).
# A question the shell asks itself, with its `read` builtin, can't be told from its prompt.
# Runs with macOS's bash 3.2 too.
MARK="TMUX_RESTORE=1 "
settle=${TMUX_RESTORE_SETTLE_SECS:-2} # still and alone this long: ready
busy=${TMUX_RESTORE_BUSY_SECS:-10}    # alone this long, the screen changing or not: ready

case $(tmux show-option -gqv @resurrect-processes) in
false | :all:) exit 0 ;; # tmux-resurrect restores no programs, or all of them (these too)
esac

# The save folder, worked out as tmux-resurrect does (scripts/helpers.sh, resurrect_dir).
dir=$(tmux show-option -gqv @resurrect-dir)
if [ -z "$dir" ]; then
	if [ -d "$HOME/.tmux/resurrect" ]; then dir=$HOME/.tmux/resurrect; else dir=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect; fi
fi
dir=$(echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g")

# alone PID TTY: PID is the only program in TTY's foreground (ps marks those with a "+")
alone() {
	ps -t "${2#/dev/}" -o pid= -o stat= 2> /dev/null | awk -v pid="$1" '
		$2 ~ /\+/ { if ($1 == pid) me = 1; else other = 1 }
		END { exit !(me && !other) }'
}

# The panes this restore made (scripts/pre-restore.sh noted the ones already there; resurrect
# leaves those alone too) and their commands, matched by session, window and pane index.
existing=" $(tmux show-option -gqv @tmux-restore-existing) "
panes=() cmds=() calm=() still=() shot=()
n=0
while IFS=$'\t' read -r id cmd; do
	[ -n "$id" ] || continue
	case $existing in *" $id "*) continue ;; esac
	tmux set-option -p -t "$id" @tmux-restore-pending "$cmd" 2> /dev/null || continue
	panes[n]=$id cmds[n]=$cmd calm[n]=0 still[n]=0 shot[n]=""
	n=$((n + 1))
done < <(awk -F'\t' -v mark=":$MARK" '
	NR == FNR { id[$1 FS $2 FS $3] = $4; next }
	$1 == "pane" && index($11, mark) == 1 { k = $2 FS $3 FS $6; if (k in id) print id[k] "\t" substr($11, 2) }' \
	<(tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}') "$dir/last" 2> /dev/null)

left=$n tick=5 # in tenths of a second; slower after the first two minutes
start=$SECONDS
while ((left > 0)); do
	((SECONDS - start > 120)) && tick=20
	sleep "$((tick / 10)).$((tick % 10))"
	for ((i = 0; i < n; i++)); do
		id=${panes[i]}
		[ -n "$id" ] || continue
		IFS=$'\t' read -r pid tty pending < <(tmux display-message -p -t "$id" $'#{pane_pid}\t#{pane_tty}\t#{@tmux-restore-pending}' 2> /dev/null)
		# the pane is gone (or the server), or its command was dropped: stop waiting for it
		if [[ ! ${pid:-} =~ ^[0-9]+$ || ${pending:-} != "${cmds[i]}" ]]; then
			panes[i]="" left=$((left - 1))
			continue
		fi
		if ! alone "$pid" "$tty"; then
			calm[i]=0 still[i]=0
			continue
		fi
		screen=$(tmux capture-pane -p -t "$id")
		calm[i]=$((calm[i] + tick))
		if [ "$screen" = "${shot[i]}" ]; then still[i]=$((still[i] + tick)); else still[i]=0 shot[i]=$screen; fi
		((still[i] >= settle * 10 || calm[i] >= busy * 10)) || continue
		tmux send-keys -t "$id" -l "${cmds[i]}" && tmux send-keys -t "$id" C-m
		tmux set-option -pu -t "$id" @tmux-restore-pending
		panes[i]="" left=$((left - 1))
	done
done
exit 0
