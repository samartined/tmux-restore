#!/usr/bin/env bash
# Started in the background by scripts/post-restore.sh after a restore. Types the commands the
# save hook wrote, the ones starting with TMUX_RESTORE=1 (a coding agent reopening its
# conversation, a venv, a command put back on the prompt), each once its pane's shell is ready.
# tmux-resurrect types a program as soon as its pane exists, and if the shell's startup asks
# something first, that question gets the keys instead and the command is lost. That happens to
# anyone whose startup files run keychain or ssh-add when tmux starts at boot, before anyone logs
# in: "Enter passphrase" takes the command as the passphrase.
# A shell is ready when it waits at its prompt and the screen has been still for a moment (a few
# seconds more if it keeps changing, as a prompt with a clock does). A shell that sources
# scripts/shell-hook.sh says when it reaches its prompt. Otherwise, it's ready when it's the only
# program in its terminal's foreground, asleep (not still running its startup files), and its
# line editor has the terminal. A pane waits up to a week, for an answer typed days later;
# meanwhile its command is in the pane option @tmux-restore-pending, which saves keep while this
# runs (scripts/save-hook.sh), and scripts/trust-home.sh keeps watching.
# Runs with macOS's bash 3.2 too.
MARK="TMUX_RESTORE=1 "
settle=${TMUX_RESTORE_SETTLE_SECS:-2} # ready and the screen still this long: type
busy=${TMUX_RESTORE_BUSY_SECS:-10}    # ready this long, the screen changing or not: type
patience=${TMUX_RESTORE_WAIT_SECS:-604800} # then give up
SHELLS=" sh bash zsh fish dash ksh mksh oksh yash tcsh csh nu xonsh elvish "
PLAIN=" sh dash ksh " # shells that may have no line editor

case $(tmux show-option -gqv @resurrect-processes) in
false | :all:) exit 0 ;; # tmux-resurrect restores no programs, or all of them (these too)
esac

# tmux-resurrect types by itself the commands that match its list (an entry "~x" matches x
# anywhere in a command): leave those to it, or they'd be typed twice. Its own rule, from its
# own scripts.
rscripts=$(dirname "$(tmux show-option -gqv @resurrect-restore-script-path)")
# shellcheck source=/dev/null
if [ -r "$rscripts/process_restore_helpers.sh" ] && . "$rscripts/variables.sh" &&
	. "$rscripts/helpers.sh" && . "$rscripts/process_restore_helpers.sh"; then
	resurrect_types() { _process_on_the_restore_list "$1"; }
else
	resurrect_types() { return 1; }
fi

# The save folder, worked out as tmux-resurrect does (scripts/helpers.sh, resurrect_dir).
dir=$(tmux show-option -gqv @resurrect-dir)
if [ -z "$dir" ]; then
	if [ -d "$HOME/.tmux/resurrect" ]; then dir=$HOME/.tmux/resurrect; else dir=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect; fi
fi
dir=$(echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g")

# ready PANE TTY PANE_PID: the pane's shell waits at its prompt, as far as can be told. Where a
# ps or stty can't tell (BusyBox), type, as resurrect does.
ready() {
	local shell ids fg modes
	# a shell that sources scripts/shell-hook.sh sets this at its first prompt; at its prompt its
	# process group has the terminal (a command it runs gets the terminal instead)
	shell=$(tmux show-option -pqv -t "$1" @tmux-restore-prompt)
	if [ -n "$shell" ] && kill -0 "$shell" 2> /dev/null; then
		ids=$(ps -o pgid= -o tpgid= -p "$shell" 2> /dev/null) || return 0
		awk '{ exit !($1 == $2) }' <<< "$ids"
		return
	fi
	# otherwise the terminal's foreground (ps marks it with a "+") is one program, a shell, asleep:
	# a question is another program (ssh-add, sudo), and a shell running its startup files is
	# awake at times
	fg=$(ps -t "${2#/dev/}" -o pid= -o stat= -o comm= 2> /dev/null) || return 0
	fg=$(awk -v shells="$SHELLS" '
		$2 ~ /\+/ { n++; pid = $1; name = $3; sub(/.*\//, "", name); sub(/^-/, "", name); state = substr($2, 1, 1) }
		END { if (n == 1 && (state == "S" || state == "I") && index(shells, " " name " ")) print pid, name; else exit 1 }' <<< "$fg") || return 1
	# and its line editor has the terminal: zle, readline and fish's turn canonical mode off at the
	# prompt, while a question (read, in a script or in the startup files, ssh-add, sudo) leaves it
	# on. A shell that may have no line editor counts as the pane's own shell.
	modes=$(stty -a -F "$2" 2> /dev/null || stty -a -f "$2" 2> /dev/null) || { [ "${fg%% *}" = "$3" ]; return; }
	case " ${modes//[[:space:]]/ } " in *" -icanon "*) return 0 ;; esac
	[ "${fg%% *}" = "$3" ] && case $PLAIN in *" ${fg#* } "*) return 0 ;; esac
	return 1
}

# The panes this restore made (scripts/pre-restore.sh noted the ones already there; resurrect
# leaves those alone too) and their commands, matched by session, window and pane index.
existing=" $(tmux show-option -gqv @tmux-restore-existing) "
panes=() cmds=() calm=() still=() shot=()
n=0
while IFS=$'\t' read -r id cmd; do
	[ -n "$id" ] || continue
	case $existing in *" $id "*) continue ;; esac
	resurrect_types "$cmd" && continue
	# saves keep a pane's waiting command only while this runs (scripts/save-hook.sh)
	tmux set-option -p -t "$id" @tmux-restore-typer $$ 2> /dev/null || continue
	tmux set-option -p -t "$id" @tmux-restore-pending "$cmd" 2> /dev/null || continue
	panes[n]=$id cmds[n]=$cmd calm[n]=0 still[n]=0 shot[n]=""
	n=$((n + 1))
done < <(awk -F'\t' -v mark=":$MARK" '
	NR == FNR { id[$1 FS $2 FS $3] = $4; next }
	$1 == "pane" && index($11, mark) == 1 { k = $2 FS $3 FS $6; if (k in id) print id[k] "\t" substr($11, 2) }' \
	<(tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}') "$dir/last" 2> /dev/null)
((n > 0)) || exit 0

done_with() {
	tmux set-option -pu -t "${panes[$1]}" @tmux-restore-pending 2> /dev/null
	tmux set-option -pu -t "${panes[$1]}" @tmux-restore-typer 2> /dev/null
	panes[$1]="" left=$((left - 1))
}
finish() { for ((i = 0; i < n; i++)); do [ -n "${panes[i]}" ] && done_with "$i"; done; }
trap finish EXIT

left=$n tick=5 # in tenths of a second; slower after the first two minutes
start=$SECONDS
while ((left > 0 && SECONDS - start < patience)); do
	((SECONDS - start > 120)) && tick=20
	sleep "$((tick / 10)).$((tick % 10))"
	for ((i = 0; i < n; i++)); do
		id=${panes[i]}
		[ -n "$id" ] || continue
		IFS=$'\t' read -r pid tty pending < <(tmux display-message -p -t "$id" $'#{pane_pid}\t#{pane_tty}\t#{@tmux-restore-pending}' 2> /dev/null)
		# the pane is gone (or the server), or its command was dropped: stop waiting for it
		if [ -z "${tty:-}" ] || [ "${pending:-}" != "${cmds[i]}" ]; then
			tmux set-option -pu -t "$id" @tmux-restore-typer 2> /dev/null
			panes[i]="" left=$((left - 1))
			continue
		fi
		if ! ready "$id" "$tty" "$pid"; then
			calm[i]=0 still[i]=0
			continue
		fi
		screen=$(tmux capture-pane -p -t "$id")
		calm[i]=$((calm[i] + tick))
		if [ "$screen" = "${shot[i]}" ]; then still[i]=$((still[i] + tick)); else still[i]=0 shot[i]=$screen; fi
		((still[i] >= settle * 10 || calm[i] >= busy * 10)) || continue
		tmux send-keys -t "$id" -l "${cmds[i]}" && tmux send-keys -t "$id" C-m
		tmux set-option -p -t "$id" @tmux-restore-typed "$(date +%s)" # scripts/trust-home.sh looks at it
		done_with "$i"
	done
done
exit 0
