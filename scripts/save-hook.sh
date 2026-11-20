#!/usr/bin/env bash
# tmux-resurrect post-save-layout hook: runs after every save, with the save file as $1, and
# rewrites the command saved for each pane so that a restore does the right thing:
#   coding agent   -> the agent's resume command (agents/*.sh): reopens the same conversation
#   safe program   -> unchanged; resurrect re-runs it (its defaults plus @resurrect-processes)
#   restartable    -> re-run as it was, with any shell: monitors and log followers resurrect
#                     doesn't list (btop, nvtop, iotop, nethogs, journalctl -f, ...)
#   anything else  -> with zsh, typed on the prompt and waiting for Enter; with other shells
#                     unchanged, and resurrect doesn't re-run it
# Rewritten commands start with TMUX_RESTORE=1, and after a restore tmux-restore types them
# itself, each once its pane's shell is ready (scripts/type-commands.sh).

if ((BASH_VERSINFO[0] < 4)); then # macOS ships bash 3.2
	for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x $b ]] && exec "$b" "$0" "$@"; done
	exit 0
fi
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib.sh"
MARK="TMUX_RESTORE=1 "
AGENTS=() RESTORE_LIST=()

# Source agents/*.sh, then yours from ~/.config/tmux-restore/agents/ (the same name replaces ours).
load_agents() {
	local f name
	for f in "$ROOT"/agents/*.sh "${XDG_CONFIG_HOME:-$HOME/.config}"/tmux-restore/agents/*.sh; do
		[[ -r $f ]] || continue
		name=${f##*/}
		name=${name%.sh}
		# shellcheck source=/dev/null
		source "$f" || continue
		declare -F "${name}_match" "${name}_session" "${name}_resume" > /dev/null || continue
		[[ " ${AGENTS[*]} " == *" $name "* ]] || AGENTS+=("$name")
	done
}

# zsh code that puts $1 on the next prompt's edit line without running it.
prefill() {
	printf "print -rz -- '%s'" "${1//\'/\'\\\'\'}"
}

# RESTORE_LIST: the entries resurrect picks programs to restart by, its defaults plus
# @resurrect-processes.
restore_list() {
	local list
	list=$(tmux show -gqv @resurrect-default-processes)
	list="${list:-vi vim view nvim emacs man less more tail top htop irssi weechat mutt} $(tmux show -gqv @resurrect-processes)"
	eval "RESTORE_LIST=($list)"
}

# safe CMD: resurrect restarts CMD by itself, so it's left as it is. By resurrect's own rules,
# "a b" matches a command starting with "a b", "x->y" matches by its x, and "~x" matches x
# anywhere. A ~pattern counts only with "->": resurrect relaunches those anyway, taking their
# arguments from the saved command, which must stay as it was. A plain ~pattern comes back typed.
safe() {
	local entry match re1 re2
	for entry in "${RESTORE_LIST[@]}"; do
		match=${entry%%->*}
		if [[ $match == '~'* ]]; then
			[[ $entry == *'->'* ]] || continue
			re1="(${match#\~})" re2=$re1
		else
			re1="(^$match )" re2="(^$match\$)"
		fi
		[[ $1 =~ $re1 || $1 =~ $re2 ]] && return 0
	done
	return 1
}

# "systemd-run ... MemoryMax=N " when PID runs in a memory-capped systemd scope
# (e.g. started via `systemd-run --user --scope -p MemoryMax=8G claude`).
scope_prefix() {
	local cgroup max
	cgroup=$(cut -d: -f3- "$PROC/$1/cgroup" 2>/dev/null) || return 0
	[[ $cgroup == */run-*.scope ]] || return 0
	max=$(< "/sys/fs/cgroup$cgroup/memory.max") 2>/dev/null || return 0
	[[ $max == max ]] || printf 'systemd-run --user --scope -q -p MemoryMax=%s ' "$max"
}

# tmux-resurrect records a program that renamed itself (process.title, e.g. `npm run dev`) as
# its new name, escaped, plus one '' per leftover byte of the old command line:
# "npm\ run\ dev '' '' ...". Drop the ''s, and show a lone escaped name as typed.
tidy() {
	local cmd=$1
	while [[ $cmd == *" ''" ]]; do cmd=${cmd% \'\'}; done
	[[ $cmd == *[!\\]" "* ]] || cmd=${cmd//\\ / }
	printf '%s' "$cmd"
}

# restartable CMD: safe to run again, though resurrect doesn't list it: a monitor, or a command
# that follows logs (-f, --follow, or a group of short flags with f in it, like journalctl -fu).
# "logs" must come right after the program: in `kubectl -n logs delete -f x.yaml` it's a value.
restartable() {
	local monitor='^(btop|nvtop|iotop|nethogs)( |$)'
	local logs='^(journalctl|docker logs|docker compose logs|docker-compose logs|kubectl logs)'
	local follows='( [^ ]+)* (-[[:alpha:]]*f[[:alpha:]]*|--follow)( |$)'
	[[ $1 =~ $monitor || $1 =~ $logs$follows ]]
}

# What to save for a command that isn't an agent's conversation.
plain() {
	local cmd=$1
	if [[ -z $cmd ]] || safe "$cmd"; then
		printf '%s' "$cmd"
	elif restartable "$cmd"; then
		printf '%s%s' "$MARK" "$cmd"
	elif [[ -n $ZSH ]]; then
		printf '%s%s' "$MARK" "$(prefill "$cmd")"
	else
		printf '%s' "$cmd"
	fi
}

# rewrite PANE_PID CMD: set NEW to the command to save for the pane, and KEY to what it reopens
# when that was worked out by a heuristic (a conversation, or "the latest in this directory").
rewrite() {
	local pane_pid=$1 cmd=$2 pid agent id
	NEW="" KEY=""
	if [[ -n $pane_pid ]]; then
		for pid in "$pane_pid" $(proc_children "$pane_pid"); do
			for agent in "${AGENTS[@]}"; do
				"${agent}_match" "$pid" 2> /dev/null || continue
				# Not a conversation, but something the agent says to start again as it was
				if declare -F "${agent}_restart" > /dev/null &&
					NEW=$("${agent}_restart" "$pid" 2> /dev/null) && [[ -n $NEW ]]; then
					NEW="$MARK$(scope_prefix "$pid")$NEW"
					return
				fi
				if id=$("${agent}_session" "$pid" 2> /dev/null) && [[ -n $id ]] &&
					NEW=$("${agent}_resume" "$pid" "$id" 2> /dev/null) && [[ -n $NEW ]]; then
					NEW="$MARK$(scope_prefix "$pid")$NEW"
					# An exact adapter's id is real even when two panes share it (one conversation open
					# twice); only a guess can collide.
					local exact=${agent}_exact
					[[ -n ${!exact:-} ]] || KEY="$agent:$id"
					return
				fi
				if declare -F "${agent}_continue" > /dev/null &&
					NEW=$("${agent}_continue" "$pid" 2> /dev/null) && [[ -n $NEW ]]; then
					NEW="$MARK$(scope_prefix "$pid")$NEW"
					KEY="$agent:latest:$(proc_cwd "$pid")"
					return
				fi
				break 2 # an agent we can't reopen: save its command as a plain one
			done
		done
	fi
	NEW=$(plain "$cmd")
}

# A post-save-layout hook you had before tmux-restore runs after ours (tmux-restore.tmux keeps it).
run_next_hook() {
	local next
	next=$(tmux show -gqv @tmux-restore-next-hook)
	[[ -n $next ]] && eval "$next $(printf '%q' "$1")"
	return 0
}

# ". '<venv>/bin/activate' 2> /dev/null": activates venv $1 in zsh or bash, silently if it's gone.
activate() {
	printf ". '%s/bin/activate' 2> /dev/null" "${1//\'/\'\\\'\'}"
}

# keep_last SAVE_FILE: make this save a copy of `last`, so resurrect sees no change and deletes
# it. resurrect also rebuilds the scrollback archive next, from save/pane_contents, so put the old
# scrollback there.
keep_last() {
	local dir last
	dir=$(dirname "$1") last="$(dirname "$1")/last"
	if [[ -s $last && ! $last -ef $1 ]]; then
		cat "$last" > "$1"
		if [[ -s $dir/pane_contents.tar.gz ]]; then
			mkdir -p "$dir/save" && gzip -dc "$dir/pane_contents.tar.gz" | tar xf - -C "$dir/save/" 2> /dev/null
		fi
	fi
}

# shutting_down: the system (or your systemd user manager) is stopping. Its units stop in
# parallel, so the programs in the panes may already be gone; tmux.service (@continuum-boot)
# saves as it stops, and a save then loses every conversation. The save at shutdown that counts
# is the one before any of that (scripts/shutdown-save.sh, which sets TMUX_RESTORE_SHUTDOWN_SAVE).
shutting_down() {
	[[ -z ${TMUX_RESTORE_SHUTDOWN_SAVE:-} ]] && command -v systemctl > /dev/null || return 1
	[[ $(systemctl is-system-running 2> /dev/null) == stopping ||
		$(systemctl --user is-system-running 2> /dev/null) == stopping ]]
}

main() {
	local save_file=$1 line cmd target pid venv i title typer
	local -a lines out heads cmds keys fields targets
	local -A pane_pids venvs count pendings
	# The save folder also gets every pane's scrollback, which can hold secrets: keep it private,
	# and what this writes too (scripts/private-saves.sh does the files resurrect writes).
	umask 077
	chmod 700 "$(dirname "$save_file")" 2> /dev/null
	# No panes means tmux was read wrong (in the C locale tmux turns resurrect's tabs into "_").
	# resurrect would make this save `last` and lose the good one, so keep `last`. (A save after
	# the server went away never gets here, as resurrect can't look this hook up;
	# scripts/pre-restore.sh mends `last` for that one.) Same for a save while the system shuts
	# down.
	if ! grep -q $'^pane\t' "$save_file" 2> /dev/null; then
		keep_last "$save_file"
		run_next_hook "$save_file"
		return
	fi
	if shutting_down; then
		echo "tmux-restore: the system is shutting down, so this save is dropped and the last one kept" >&2
		keep_last "$save_file"
		run_next_hook "$save_file"
		return
	fi
	load_agents
	restore_list
	ZSH=""
	[[ $(tmux show -gqv default-shell) == */zsh ]] && ZSH=1 # restored panes run default-shell
	while IFS=$'\t' read -r target pid venv; do pane_pids[$target]=$pid venvs[$target]=$venv; done \
		< <(tmux list-panes -a -F $'#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{@tmux-restore-venv}')
	# the commands a restore hasn't typed yet, waiting for their shell, while the
	# scripts/type-commands.sh that waits to type each one still runs
	while IFS=$'\t' read -r target typer cmd; do
		[[ -n $cmd && $typer =~ ^[0-9]+$ ]] && kill -0 "$typer" 2> /dev/null && pendings[$target]=$cmd
	done < <(tmux list-panes -a -F $'#{session_name}:#{window_index}.#{pane_index}\t#{@tmux-restore-typer}\t#{@tmux-restore-pending}')

	mapfile -t lines < "$save_file"
	for i in "${!lines[@]}"; do
		line=${lines[i]}
		keys[i]=""
		if [[ $line != pane$'\t'* ]]; then
			out[i]=$line
			continue
		fi
		heads[i]=${line%$'\t'*}
		cmd=${line##*$'\t':} # last field minus resurrect's ":" prefix
		cmds[i]=$(tidy "${cmd% }")
		mapfile -td $'\t' fields < <(printf '%s' "${heads[i]}")
		# resurrect reads its fields with `read`, which merges two tabs in a row: a pane with an
		# empty title (a program clears it as it exits) comes out shifted, with the folder where
		# the title goes and the pane's pid added, and would be restored in the wrong folder.
		# Put a title back (tmux's default, the host name). The command, worked out from the
		# wrong pid, is dropped.
		if ((${#fields[@]} == 10)) && [[ ${fields[6]} == :* && ${fields[7]} != :* ]]; then
			title=$(hostname -s 2> /dev/null || hostname)
			heads[i]=$(printf '%s\t' "${fields[@]:0:6}" "${title:-tmux}" "${fields[@]:6:3}")
			heads[i]=${heads[i]%$'\t'}
			cmds[i]=""
		fi
		target="${fields[1]}:${fields[2]}.${fields[5]}"
		targets[i]=$target
		rewrite "${pane_pids[$target]:-}" "${cmds[i]}"
		# still waiting for its shell (its startup asked something nobody has answered yet): what
		# runs there now is that startup, so keep the command the restore is waiting to type
		if [[ -n ${pendings[$target]:-} ]]; then
			NEW=${pendings[$target]} KEY=""
			unset 'targets[i]' # nor a venv put in front again: it already has its own
		fi
		out[i]="${heads[i]}"$'\t'":$NEW"
		keys[i]=$KEY
		[[ -n $KEY ]] && count[$KEY]=$((${count[$KEY]:-0} + 1))
	done
	# Two panes that would reopen the same conversation (or "the latest" in the same directory)
	# would show it twice and lose the other one, so save them as plain commands instead.
	for i in "${!keys[@]}"; do
		if [[ -n ${keys[i]} ]] && ((count[${keys[i]}] > 1)); then
			out[i]="${heads[i]}"$'\t'":$(plain "${cmds[i]}")"
		fi
	done
	# A pane with a Python venv active (scripts/shell-hook.sh records it) activates it again, before
	# the command tmux-restore wrote for it, or alone if it was idle. A command left for resurrect
	# to run as it is (vim, htop, ...) stays as it is.
	for i in "${!targets[@]}"; do
		venv=${venvs[${targets[i]}]:-}
		[[ -n $venv && -r $venv/bin/activate ]] || continue
		cmd=${out[i]#"${heads[i]}"$'\t':}
		if [[ -z $cmd ]]; then
			cmd=$MARK$(activate "$venv")
		elif [[ $cmd == "$MARK"* ]]; then
			cmd="$MARK$(activate "$venv"); ${cmd#"$MARK"}"
		else
			continue
		fi
		out[i]="${heads[i]}"$'\t'":$cmd"
	done
	((${#out[@]})) && printf '%s\n' "${out[@]}" > "$save_file.tmp" && mv -f "$save_file.tmp" "$save_file"
	# No session or window name a shell would read as code (scripts/safe-names.sh says why)
	"$ROOT/scripts/safe-names.sh" "$save_file"
	run_next_hook "$save_file"
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
