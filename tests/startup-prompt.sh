#!/usr/bin/env bash
# A shell whose startup asks something, end to end, with bash and with zsh. When tmux starts at
# boot, before anyone logs in, a startup file running keychain or ssh-add stops at "Enter
# passphrase", and whatever is typed into the pane then goes to that question. So the commands
# the save hook wrote (TMUX_RESTORE=1 ...) must be typed only once the pane's shell is at its
# prompt: not into the question, then right after it's answered, and kept in saves meanwhile.
# Here the startup files ask through an outside program reading the terminal, as ssh-add does
# (a script run by sh: under zsh it has the terminal to itself, and it's a shell, asleep).
# Also: a startup busy for a while before it asks, a startup that starts another shell, a shell
# whose output goes through a process substitution (it says when it's ready through
# scripts/shell-hook.sh), an entry of the user's in @resurrect-processes that matches the
# commands (resurrect types those, once), giving up after TMUX_RESTORE_WAIT_SECS, a question the
# startup files ask with the shell's own `read`, and dash, which has no line editor.
# Throwaway servers in their own socket directory and HOME.
# PLUGINS_DIR (default ~/.tmux/plugins) must contain tmux-resurrect. Needs zsh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PLUGINS_DIR=${PLUGINS_DIR:-$HOME/.tmux/plugins}
[[ -d $PLUGINS_DIR/tmux-resurrect ]] || { echo "FAIL: $PLUGINS_DIR/tmux-resurrect not found (set PLUGINS_DIR)"; exit 1; }
D=$(mktemp -d)
t() { TMUX_TMPDIR=$D/sock command tmux -L ask "$@"; }
trap 't kill-server 2> /dev/null; rm -rf "$D" /tmp/tmux-resurrect-restore-ask.lock' EXIT
mkdir -p "$D/sock" "$D/home" "$D/proj" "$D/plugins"
cp -rL "$PLUGINS_DIR/tmux-resurrect" "$D/plugins/" 2> /dev/null
cp -r "$here/.." "$D/plugins/tmux-restore"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# With $D/ask present, the startup files ask for a passphrase the way ssh-add does: another
# program reads it from the terminal, without echo, and here writes down what it got.
cat > "$D/ask.sh" <<EOF
#!/bin/sh
printf 'Enter passphrase for key: '
stty -echo; IFS= read -r answer; stty echo; echo
printf '%s\n' "\$answer" >> "$D/answers"
EOF
chmod +x "$D/ask.sh"
# $D/<flag> files turn on each case
rc="PS1='$ '
[ -e '$D/hook' ] && . '$D/plugins/tmux-restore/scripts/shell-hook.sh'
[ -e '$D/tee' ] && [ -n \"\$BASH_VERSION\" ] && exec > >(tee -a '$D/tee.log')
[ -e '$D/busy' ] && { e=\$((SECONDS + 4)); while [ \$SECONDS -lt \$e ]; do :; done; }
[ -e '$D/ask' ] && sh '$D/ask.sh' < /dev/tty
[ -e '$D/askb' ] && { printf 'Name: '; read -r n; echo \"\$n\" >> '$D/answers'; }
[ -e '$D/nest' ] && [ -n \"\$BASH_VERSION\" ] && zsh"
echo 'unsetopt GLOBAL_RCS' > "$D/home/.zshenv"
printf '%s\n' "$rc" > "$D/home/.zshrc"
printf '%s\n' "$rc" > "$D/home/.bashrc"
echo '. ~/.bashrc' > "$D/home/.bash_profile" # tmux-resurrect starts bash as a login shell

start() {
	cat > "$D/test.conf" <<EOC
set -g default-shell '$1'
set -g default-size 200x50
set -g @resurrect-dir '$D/resurrect'
set -g @continuum-restore 'off'
${EXTRA_CONF:-}
run-shell '$D/plugins/tmux-resurrect/resurrect.tmux'
run-shell '$D/plugins/tmux-restore/tmux-restore.tmux'
EOC
	shift
	env -i HOME="$D/home" PATH="$PATH" TERM=xterm-256color LANG="${LANG:-C.UTF-8}" TMUX_TMPDIR="$D/sock" \
		${WAIT_SECS:+"TMUX_RESTORE_WAIT_SECS=$WAIT_SECS"} tmux -L ask -f "$D/test.conf" "$@"
}
# until_ok [SECS] CMD...: wait up to SECS (default 10) for CMD to succeed
until_ok() {
	local n=100 _
	[[ $1 =~ ^[0-9]+$ ]] && n=$(($1 * 10)) && shift
	for _ in $(seq $n); do "$@" && return 0; sleep 0.1; done
	return 1
}
# stop: kill the server and wait for it to be gone, so the next one doesn't meet it on its way out
stop() {
	local pid
	pid=$(t display-message -p '#{pid}' 2> /dev/null)
	t kill-server 2> /dev/null
	[[ -n $pid ]] && until_ok 5 eval "! kill -0 $pid 2> /dev/null"
}
prompt() { t capture-pane -p -t "$1" | grep -q '\$$'; }
shows() { [[ $(t capture-pane -p -t "$1") == *"$2"* ]]; }
asking() { t capture-pane -p -t "$1" | grep -q 'Enter passphrase for key:'; }
ran() { [[ -e $D/ran.$1 ]]; }
times_ran() { cat "$D/ran.$1" 2> /dev/null | wc -l | tr -d ' '; }
ran_list() { local p out=""; for p in 0 1 2; do ran $p && out+="$p"; done; echo "$out"; }
pending() { t show-option -pqv -t "$1" @tmux-restore-pending; }
# no longer waiting in these panes: the command runs a moment before type-commands.sh lets go
settled() { local p; for p in "$@"; do [[ -z $(pending "$p") ]] || return 1; done; }
cmd_of() { awk -F'\t' -v p="$1" '$1 == "pane" && $6 == p { print $11 }' "$D/resurrect/last"; }

# Earlier versions had resurrect type these commands, through an entry in @resurrect-processes:
# loading this one takes it out (they'd be typed twice), and leaves the user's own entries.
EXTRA_CONF="set -g @resurrect-processes 'vim \"~^TMUX_RESTORE=1 \" htop'" start "$(command -v bash)" new-session -d -s main
check "an earlier version's entry taken out of @resurrect-processes" "vim htop" "$(t show-option -gqv @resurrect-processes)"
stop
EXTRA_CONF="set -g @resurrect-processes '\"~^TMUX_RESTORE=1 \"'" start "$(command -v bash)" new-session -d -s main
check "... and the option unset if it was the only one" "" "$(t show-option -gqv @resurrect-processes)"
stop

for sh in bash zsh; do
	rm -rf "$D/resurrect" "$D"/ran.* "$D/answers" "$D/ask" "$D/busy"
	start "$(command -v $sh)" new-session -d -s main -c "$D/proj"
	t split-window -t main:0 -c "$D/proj"
	t split-window -t main:0 -c "$D/proj"
	until_ok prompt main:0.2 || bad "$sh: no prompt"
	check "$sh: resurrect doesn't type tmux-restore's commands itself" "" \
		"$(t show-option -gqv @resurrect-processes | grep -F 'TMUX_RESTORE=1')"
	t run-shell "$D/plugins/tmux-resurrect/scripts/save.sh quiet"
	# what the save hook writes for an agent, with a command that leaves a mark instead
	save=$(readlink -f "$D/resurrect/last")
	awk -F'\t' -v OFS='\t' -v d="$D" '$1 == "pane" { $11 = ":TMUX_RESTORE=1 echo x >> " d "/ran." $6 } { print }' \
		"$save" > "$save.new" && mv "$save.new" "$save" && cp "$save" "$D/crafted.txt"
	stop

	# 1. Nothing asked: each command runs, as before
	start "$(command -v $sh)" new-session -d -s scratch
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok ran 0 && until_ok ran 1 && until_ok ran 2 || bad "$sh: nothing asked, but a command didn't run"
	until_ok 3 settled main:0.0 main:0.1 main:0.2
	check "$sh: nothing asked, nothing left waiting" "" "$(pending main:0.0)$(pending main:0.1)$(pending main:0.2)"
	stop
	rm -f "$D"/ran.*

	# 2. The startup is busy for 4 seconds, then asks for a passphrase: nothing is typed into the
	# question
	: > "$D/ask"; : > "$D/busy"
	start "$(command -v $sh)" new-session -d -s scratch
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok asking main:0.2 || bad "$sh: the startup didn't ask"
	sleep 4
	check "$sh: asking, the command isn't given as the answer" "" "$(cat "$D/answers" 2> /dev/null)"
	check "$sh: asking, nothing ran" "" "$(ran_list)"
	check "$sh: asking, the command waits" "TMUX_RESTORE=1 echo x >> $D/ran.1" "$(pending main:0.1)"
	# a save meanwhile keeps the commands still waiting
	t run-shell "$D/plugins/tmux-resurrect/scripts/save.sh quiet"
	check "$sh: asking, a save keeps the waiting command" ":TMUX_RESTORE=1 echo x >> $D/ran.1" "$(cmd_of 1)"
	# answered in pane 0 only: its command runs, and only there
	t send-keys -t main:0.0 -l 'secret'
	t send-keys -t main:0.0 Enter
	until_ok ran 0 || bad "$sh: answered, the command didn't run"
	check "$sh: answered, the question got the answer" "secret" "$(cat "$D/answers" 2> /dev/null)"
	until_ok 3 settled main:0.0
	check "$sh: answered, no longer waiting" "" "$(pending main:0.0)"
	sleep 1
	check "$sh: the panes not answered still wait" "0" "$(ran_list)"
	t send-keys -t main:0.1 C-c # given up on: the shell goes on to its prompt
	until_ok ran 1 || bad "$sh: question cancelled, the command didn't run"
	check "$sh: each command ran once" "11" "$(times_ran 0)$(times_ran 1)"
	stop
	rm -f "$D/ask" "$D/busy"

	# 3. Panes that were there before the restore (restoring into a running server) get nothing
	# typed, as tmux-resurrect does for the programs it restores. (With a single pane in the
	# server, resurrect replaces it, so there are two.)
	cp "$D/crafted.txt" "$D/resurrect/crafted.txt" && ln -fs crafted.txt "$D/resurrect/last"
	rm -f "$D"/ran.*
	start "$(command -v $sh)" new-session -d -s main -c "$D/proj"
	t split-window -t main:0 -c "$D/proj"
	until_ok prompt main:0.1
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok ran 2 || bad "$sh: restored into a running server, the new pane's command didn't run"
	sleep 1
	check "$sh: the panes that were already there: nothing typed" "2" "$(ran_list)"
	stop
	[[ $sh == bash ]] || continue

	# 4. An entry of the user's in @resurrect-processes matches the commands: resurrect types
	# them, and tmux-restore doesn't type them again
	again() { # again: restore the crafted save on a new server, and wait for each command to run
		cp "$D/crafted.txt" "$D/resurrect/crafted.txt" && ln -fs crafted.txt "$D/resurrect/last"
		rm -f "$D"/ran.*
		start "$(command -v $sh)" new-session -d -s scratch
		t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
		until_ok ran 0 && until_ok ran 1 && until_ok ran 2
	}
	EXTRA_CONF="set -g @resurrect-processes '\"~ran\"'" again || bad "$sh: a user's entry matches: a command didn't run"
	sleep 4
	check "$sh: a user's entry matches: each command ran once" "111" "$(times_ran 0)$(times_ran 1)$(times_ran 2)"
	stop

	# 5. The startup starts another shell (zsh, without exec): commands go to that one
	: > "$D/nest"
	again || bad "$sh: a shell in a shell: a command didn't run"
	stop
	rm -f "$D/nest"

	# 6. Output through a process substitution (tee): that process shares the terminal with the
	# shell, but a shell that sources the shell hook says when it's at its prompt
	: > "$D/tee"; : > "$D/hook"
	again || bad "$sh: output through tee, with the shell hook: a command didn't run"
	stop
	rm -f "$D/tee" "$D/hook"

	# 7. Nobody answers: after TMUX_RESTORE_WAIT_SECS, the commands are given up, and saves no
	# longer keep them
	cp "$D/crafted.txt" "$D/resurrect/crafted.txt" && ln -fs crafted.txt "$D/resurrect/last"
	rm -f "$D"/ran.* "$D/answers"
	: > "$D/ask"
	WAIT_SECS=3 start "$(command -v $sh)" new-session -d -s scratch
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok asking main:0.2 || bad "$sh: the startup didn't ask"
	sleep 6
	check "$sh: given up: no longer waiting" "" "$(pending main:0.0)$(pending main:0.1)$(pending main:0.2)"
	t run-shell "$D/plugins/tmux-resurrect/scripts/save.sh quiet"
	[[ $(cmd_of 1) != *"ran.1"* ]] || bad "$sh: given up: a save still keeps the command"
	t send-keys -t main:0.0 -l 'secret'
	t send-keys -t main:0.0 Enter
	sleep 4
	check "$sh: given up: answered later, nothing typed" "secret" "$(cat "$D/answers" 2> /dev/null)"
	check "$sh: given up: nothing ran" "" "$(ran_list)"
	stop
	rm -f "$D/ask"

	# 8. The startup asks with the shell's own `read`: nothing typed until it's answered
	cp "$D/crafted.txt" "$D/resurrect/crafted.txt" && ln -fs crafted.txt "$D/resurrect/last"
	rm -f "$D"/ran.* "$D/answers"
	: > "$D/askb"
	start "$(command -v $sh)" new-session -d -s scratch
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok shows main:0.0 'Name:' || bad "$sh: the startup didn't ask with read"
	sleep 5
	check "$sh: read: the command isn't given as the answer" "" "$(cat "$D/answers" 2> /dev/null)"
	t send-keys -t main:0.0 -l 'me'
	t send-keys -t main:0.0 Enter
	until_ok ran 0 || bad "$sh: read answered, the command didn't run"
	check "$sh: read: the question got the answer" "me" "$(cat "$D/answers" 2> /dev/null)"
	stop
	rm -f "$D/askb"
done

# 9. dash has no line editor: its prompt leaves the terminal in canonical mode, like a question,
# but a dash that is the pane's own shell counts
if command -v dash > /dev/null; then
	rm -rf "$D/resurrect" "$D"/ran.*
	start "$(command -v dash)" new-session -d -s main -c "$D/proj"
	until_ok prompt main:0.0 || bad "dash: no prompt"
	t run-shell "$D/plugins/tmux-resurrect/scripts/save.sh quiet"
	save=$(readlink -f "$D/resurrect/last")
	awk -F'\t' -v OFS='\t' -v d="$D" '$1 == "pane" { $11 = ":TMUX_RESTORE=1 echo x >> " d "/ran." $6 } { print }' \
		"$save" > "$save.new" && mv "$save.new" "$save"
	stop
	start "$(command -v dash)" new-session -d -s scratch
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok ran 0 || bad "dash: the command didn't run"
	stop
fi
echo "passed=$pass failed=$fail"; ((fail == 0))
