#!/usr/bin/env bash
# Unit test for scripts/trust-home.sh and scripts/post-restore.sh with a fake tmux. After a
# restore, a Claude Code session working in the home folder stops at the workspace-trust prompt
# (Claude Code never keeps that answer). With @tmux-restore-trust-home on, the panes working in
# $HOME that show exactly that prompt get "Yes, I trust this folder", and each one is logged.
set -u
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/home/dev/x"
H=$D/home
cat > "$D/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
list-panes) if [[ \$* == *@tmux-restore-typer* ]]; then cat "$D/typers" 2> /dev/null; else cat "$D/panes"; fi ;;
capture-pane) cat "$D/screen\${4}" ;;
display-message) echo "session\${4}" ;;
show-option) [[ \$3 == @tmux-restore-trust-home ]] && cat "$D/option" 2> /dev/null ;;
send-keys)
	echo "\$3 \$4" >> "$D/keys"
	if [[ \$4 == Down && ! -e "$D/stuck\$3" ]]; then
		sed -i.bak -e 's/^ ❯ No, exit/   No, exit/' -e 's/^   Yes, I trust this folder/ ❯ Yes, I trust this folder/' "$D/screen\$3"
	elif [[ \$4 == Enter ]]; then
		echo "claude is ready" > "$D/screen\$3"
	fi ;;
esac
exit 0
EOF
chmod +x "$D/bin/tmux"
# each pane's pid is its claude's: ps shows its arguments, from $D/args<pid>
printf '#!/bin/sh\nexit 1\n' > "$D/bin/pgrep"
printf '#!/bin/sh\ncat "%s/args$4" 2> /dev/null\n' "$D" > "$D/bin/ps"
chmod +x "$D/bin/pgrep" "$D/bin/ps"
for p in 101 102 103 104 105 106 107; do echo "claude --resume 1111-2222 --name x" > "$D/args$p"; done
echo "claude --continue --remote-control" > "$D/args108"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
# prompt FOLDER [HEADER] [NOTE]: the workspace-trust prompt as Claude Code shows it
prompt() {
	printf '%s\n' "────────" " ${2:-Accessing workspace:}" "" " $1" "" \
		" Quick safety check: Is this a project you created or one you trust? (Like your own code, a" \
		" well-known open source project, or work from your team). If not, take a moment to review." "" \
		" Claude Code'll be able to read, edit, and execute files here.${3- This is your home folder, so Yes lasts for this session only.}" "" \
		" Security guide" "" " ❯ No, exit" "   Yes, I trust this folder" "" " Enter to confirm · Esc to cancel"
}
prompt "$H" > "$D/screen%1"                                  # the home folder: answered
prompt "$H/dev/x" "" "" > "$D/screen%2"                      # another folder: left alone
prompt "$H" "Adding a new directory:" > "$D/screen%3"        # another prompt: left alone
prompt "$H" > "$D/screen%4"; : > "$D/stuck%4"                # the menu doesn't move: no Enter
printf '%s\n' "claude is ready" > "$D/screen%5"              # no prompt at all
printf '%%1\t%s\t101\n%%2\t%s\t102\n%%3\t%s\t103\n%%4\t%s\t104\n%%5\t%s\t105\n%%6\t%s\t106\n%%7\t%s\t107\n%%8\t%s\t108\n' \
	"$H" "$H/dev/x" "$H" "$H" "$H" "$H/dev/x" "$H" "$H" > "$D/panes"
# 80 columns with no client attached: Claude Code wraps the note across two lines
p=$(prompt "$H"); printf '%s\n' "${p/ This is your home folder,/ This is your$'\n' home folder,}" > "$D/screen%7"
prompt "$H" > "$D/screen%8"                                  # claude --continue: left alone
prompt "$H" > "$D/screen%6"                                  # the prompt, but working elsewhere
: > "$D/keys"
# Time enough for a slow machine to go through every pane (macOS took more than 2 seconds), and
# stopped once the four panes it acts on are logged and a second more has passed
HOME=$H XDG_STATE_HOME=$D/state TMUX_RESTORE_TRUST_SECS=60 PATH="$D/bin:$PATH" bash "$here/../scripts/trust-home.sh" &
watcher=$!
for _ in $(seq 300); do (($(cat "$D/state/tmux-restore/trust.log" 2> /dev/null | wc -l) >= 4)) && break; sleep 0.1; done
sleep 1
kill $watcher 2> /dev/null; wait $watcher 2> /dev/null
check "home folder prompt: answered Yes" "%1 Down"$'\n'"%1 Enter" "$(grep '^%1 ' "$D/keys")"
check "another folder's prompt: left alone" "" "$(grep '^%2 ' "$D/keys")"
check "another kind of prompt: left alone" "" "$(grep '^%3 ' "$D/keys")"
check "menu didn't move to Yes: no Enter" "%4 Down" "$(grep '^%4 ' "$D/keys")"
check "no prompt: nothing sent" "" "$(grep '^%5 ' "$D/keys")"
check "home prompt in a pane working elsewhere: left alone" "" "$(grep '^%6 ' "$D/keys")"
check "wrapped prompt (80 columns): answered Yes" "%7 Down"$'\n'"%7 Enter" "$(grep '^%7 ' "$D/keys")"
check "claude --continue: left alone" "" "$(grep '^%8 ' "$D/keys")"
check "logged: --continue left alone" 1 "$(grep -c "session%8 .*%8 .*left alone: its claude" "$D/state/tmux-restore/trust.log")"
check "logged: accepted" 1 "$(grep -c "session%1 .*%1 .*trusted $H" "$D/state/tmux-restore/trust.log")"
check "logged: left alone" 1 "$(grep -c "session%4 .*%4 .*left alone" "$D/state/tmux-restore/trust.log")"
check "only those four logged" 4 "$(wc -l < "$D/state/tmux-restore/trust.log" | tr -d ' ')"

# A command typed late (its shell's startup asked something, answered after a while): it keeps
# watching while scripts/type-commands.sh still waits to type commands, answers where a command
# was typed lately, and stops after that.
: > "$D/keys"; rm -f "$D/state/tmux-restore/trust.log"
printf '%%8\t%s\t108\t\n%%9\t%s\t109\t\n' "$H" "$H" > "$D/panes"
echo "claude --resume 5555-6666" > "$D/args108" # started by hand: not typed by tmux-restore
echo "claude --resume 3333-4444" > "$D/args109"
echo "zsh" > "$D/screen%8"; echo "zsh" > "$D/screen%9"
sleep 60 & typing=$!
printf '%s|\n' $typing > "$D/typers" # pane %9 waits for its command
HOME=$H XDG_STATE_HOME=$D/state TMUX_RESTORE_TRUST_SECS=5 PATH="$D/bin:$PATH" bash "$here/../scripts/trust-home.sh" &
watcher=$!
sleep 5.5 # past its own time
# claude typed late in %9; one started by hand in %8 shows the prompt too
now=$(date +%s)
printf '%%8\t%s\t108\t\n%%9\t%s\t109\t%s\n' "$H" "$H" "$now" > "$D/panes"
printf '|%s\n' "$now" > "$D/typers"
kill $typing; wait $typing 2> /dev/null
prompt "$H" > "$D/screen%8"; prompt "$H" > "$D/screen%9"
sleep 5 # it was looking every 5 seconds while waiting
check "typed late: answered" "%9 Down"$'\n'"%9 Enter" "$(grep '^%9 ' "$D/keys")"
check "not typed by tmux-restore, after its time: left alone" "" "$(grep '^%8 ' "$D/keys")"
sleep 4
check "nothing left to type: it stopped" "" "$(kill -0 $watcher 2> /dev/null && echo running)"
kill $watcher 2> /dev/null

# post-restore.sh starts it only with @tmux-restore-trust-home on; scripts/type-commands.sh, always
printf '#!/bin/sh\necho started >> "%s/started"\n' "$D" > "$D/fake-trust.sh"; chmod +x "$D/fake-trust.sh"
printf '#!/bin/sh\necho typing >> "%s/typing"\n' "$D" > "$D/fake-type.sh"; chmod +x "$D/fake-type.sh"
run_post() {
	rm -f "$D/started" "$D/typing"
	TMUX_RESTORE_TRUST_HOME_SCRIPT=$D/fake-trust.sh TMUX_RESTORE_TYPE_SCRIPT=$D/fake-type.sh PATH="$D/bin:$PATH" bash "$here/../scripts/post-restore.sh"
	sleep 0.5
}
rm -f "$D/option"; run_post
check "option off: not started" "" "$(cat "$D/started" 2> /dev/null)"
check "option off: commands typed anyway" typing "$(cat "$D/typing" 2> /dev/null)"
echo on > "$D/option"; run_post
check "option on: started" started "$(cat "$D/started" 2> /dev/null)"
check "option on: commands typed too" typing "$(cat "$D/typing" 2> /dev/null)"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
