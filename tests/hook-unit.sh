#!/usr/bin/env bash
# Unit tests for scripts/save-hook.sh and scripts/lib.sh: flag filtering, quoting, prefill, and
# which saved commands get rewritten (on a throwaway tmux server). Needs zsh.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/save-hook.sh
source "$here/../scripts/save-hook.sh"
load_agents
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
ka() { keep_flags claude "$@"; }
check "flags kept"           " --dangerously-skip-permissions --effort max" "$(ka --dangerously-skip-permissions --effort max)"
check "prompt dropped"       " --dangerously-skip-permissions"              "$(ka --dangerously-skip-permissions 'fix the bug')"
check "prompt between flags" " --model opus --effort high"                  "$(ka --model opus 'do x' --effort high)"
check "-c dropped"           " --dangerously-skip-permissions"              "$(ka -c --dangerously-skip-permissions)"
check "--resume id dropped"  " --effort max"                                "$(ka --resume abc-123 --effort max)"
check "-r w/o value dropped" " --effort max"                                "$(ka -r --effort max)"
check "= forms"              " --model=sonnet"                              "$(ka --resume=abc --model=sonnet)"
check "session-id/fork drop" " --name my\\ session"                         "$(ka --session-id 1111 --fork-session --name 'my session')"
check "variadic then prompt" " --add-dir /a /b --model x"                   "$(ka --add-dir /a /b --model x prompt words)"
check "optional value"       " --debug api"                                 "$(ka --debug api hello)"
check "-- ends options"      ""                                             "$(ka -- 'prompt')"
check "no args"              ""                                             "$(ka)"
quoted=$(ka --append-system-prompt "be terse; it's \$fine" --effort max "a prompt"); eval "set -- $quoted"
check "roundtrip argc" "4" "$#"; check "roundtrip value" "be terse; it's \$fine" "$2"
pid=$(for p in $(pgrep -x claude); do [[ -e ~/.claude/sessions/$p.json ]] && { echo "$p"; break; }; done)
[[ -n $pid ]] && check "proc_start vs registry" "$(jq -r .procStart ~/.claude/sessions/"$pid".json)" "$(proc_start "$pid")"
for cmd in 'sleep 100000' "python3 -c import\\ time\;\\ time.sleep\\(1e6\\) it\\'s\\ a\\ test" "echo \$'a\\nb' \"double\" 'single'" 'grep -r foo\ bar . | wc -l'; do
	check "prefill: $cmd" "$cmd" "$(zsh -fc "$(prefill "$cmd"); read -rz got; print -rn -- \$got")"
done

# main(): an unsafe command becomes a pre-typed prompt only when restored panes run zsh
tmux() { command tmux -L hook-unit "$@"; }
D=$(mktemp -d); trap 'command tmux -L hook-unit kill-server 2>/dev/null; rm -rf "$D" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/hook-unit"' EXIT
command tmux -L hook-unit -f /dev/null new-session -d
for shell in zsh bash; do
	tmux set -g default-shell "$(command -v "$shell")"
	printf 'pane\tmain\t0\t1\t:*\t%s\tzsh\t:/tmp\t1\t%s\t:%s\n' 0 make 'make deploy' 1 vim 'vim notes.txt' > "$D/save"
	main "$D/save"
	[[ $shell == zsh ]] && want=":TMUX_RESTORE=1 print -rz -- 'make deploy'" || want=":make deploy"
	check "main ($shell): unsafe" "$want" "$(sed -n 1p "$D/save" | cut -f11)"
	check "main ($shell): safe" ":vim notes.txt" "$(sed -n 2p "$D/save" | cut -f11)"
done
# a program that renamed itself: resurrect records "npm\ run\ dev '' '' ''"
tmux set -g default-shell "$(command -v zsh)"
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tnpm\t:%s\n' "npm\\ run\\ dev '' '' '' " > "$D/save"
main "$D/save"
check "renamed process: typed as its name" ":TMUX_RESTORE=1 print -rz -- 'npm run dev'" "$(cut -f11 "$D/save")"
check "tidy leaves real arguments alone" "grep -r foo\\ bar ." "$(tidy "grep -r foo\\ bar .")"
# a program you list in @resurrect-processes is left as it is, for resurrect to run again
tmux set -g @resurrect-processes 'my-agent'
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tmy-agent\t:%s\n' 'my-agent --resume-last' > "$D/save"
main "$D/save"
check "@resurrect-processes: left as it is" ":my-agent --resume-last" "$(cut -f11 "$D/save")"
# ...matched by resurrect's own rules: "a b" matches commands that start with "a b", "x->y" matches
# x, and "~x->y" matches x anywhere. A plain "~pattern" still comes back typed.
tmux set -g @resurrect-processes '"btop->btop --utf-force" "git log" "~rails server->rails server *" "~npm run dev"'
printf 'pane\tmain\t0\t1\t:*\t%s\tzsh\t:/tmp\t1\t%s\t:%s\n' 0 btop btop 1 git 'git log --oneline' 2 git 'git push' \
	3 topgrade topgrade 4 bundle 'bundle exec rails server -p 3001' 5 npm 'npm run dev' > "$D/save"
main "$D/save"
got() { sed -n "$1p" "$D/save" | cut -f11; }
check "@resurrect-processes: x->y matches x"            ":btop"                                   "$(got 1)"
check "@resurrect-processes: \"git log\" matches"       ":git log --oneline"                      "$(got 2)"
check "@resurrect-processes: \"git log\" isn't all git" ":TMUX_RESTORE=1 print -rz -- 'git push'" "$(got 3)"
check "@resurrect-processes: top isn't topgrade"      ":TMUX_RESTORE=1 print -rz -- 'topgrade'" "$(got 4)"
check "@resurrect-processes: ~x->y left for resurrect"  ":bundle exec rails server -p 3001"       "$(got 5)"
check "@resurrect-processes: plain ~pattern typed"      ":TMUX_RESTORE=1 print -rz -- 'npm run dev'" "$(got 6)"
# a program you list wins over tmux-restore's own: left as it is, for resurrect to run
tmux set -g @resurrect-processes '"journalctl -f"'
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tjournalctl\t:%s\n' 'journalctl -f -u nginx' > "$D/save"
main "$D/save"
check "@resurrect-processes: wins over restartable" ":journalctl -f -u nginx" "$(got 1)"
tmux set -g @resurrect-processes ''
# monitors and commands that follow logs restart with any shell, though resurrect doesn't list
# them; commands that only look like them don't
restarts=('btop' 'nvtop' 'iotop -o' 'nethogs wlan0' 'journalctl -f' 'journalctl -fu nginx' 'journalctl -u nginx -f'
	'journalctl -xef' 'journalctl --follow -n 50' 'journalctl -u my\ unit -f' 'docker logs -f web'
	'docker logs web --follow' 'docker logs -tf web' 'docker compose logs -f' 'docker-compose logs -f api'
	'kubectl logs -f deploy/api' 'kubectl logs api-0 -n prod -f')
not_restarted=('kubectl apply -f x.yaml' 'kubectl delete -f x.yaml' 'kubectl -n logs delete -f x.yaml'
	'kubectl -n prod logs -f api' 'docker rm -f web' 'docker compose -f prod.yml up' 'journalctl --vacuum-size=1G'
	'journalctl -u nginx' 'journalctl -F _SYSTEMD_UNIT' 'journalctl-upload -f' 'sudo iotop' 'nvtopx' 'make -f ci.mk')
for shell in zsh bash; do
	tmux set -g default-shell "$(command -v "$shell")"
	n=0
	for cmd in "${restarts[@]}" "${not_restarted[@]}"; do
		printf 'pane\tmain\t0\t1\t:*\t%s\tzsh\t:/tmp\t1\t%s\t:%s\n' "$n" "${cmd%% *}" "$cmd"
		n=$((n + 1))
	done > "$D/save"
	main "$D/save"
	n=0
	for cmd in "${restarts[@]}"; do
		n=$((n + 1))
		check "restarts ($shell): $cmd" ":TMUX_RESTORE=1 $cmd" "$(got $n)"
	done
	for cmd in "${not_restarted[@]}"; do
		n=$((n + 1))
		[[ $shell == zsh ]] && want=":TMUX_RESTORE=1 $(prefill "$cmd")" || want=":$cmd"
		check "not restarted ($shell): $cmd" "$want" "$(got $n)"
	done
done
tmux set -g default-shell "$(command -v zsh)"
# the save folder also holds every pane's scrollback, so the hook makes it private
mkdir -m 755 "$D/resurrect"
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:\n' > "$D/resurrect/save"
main "$D/resurrect/save"
check "save folder: private" "$D/resurrect" "$(find "$D/resurrect" -maxdepth 0 -perm 700)"
# the venv a pane has active is a pane option (scripts/shell-hook.sh sets it)
mkdir -p "$D/venv/bin" && : > "$D/venv/bin/activate"
target=$(tmux list-panes -F '#{session_name}	#{window_index}	#{pane_index}' | head -1)
tmux set-option -p -t "$(printf '%s:%s.%s' $target)" @tmux-restore-venv "$D/venv"
printf 'pane\t%s\t%s\t1\t:*\t%s\tzsh\t:/tmp\t1\tzsh\t:\n' $target > "$D/save"
main "$D/save"
check "venv: read from the pane option" ":TMUX_RESTORE=1 . '$D/venv/bin/activate' 2> /dev/null" "$(cut -f11 "$D/save")"
# A command a restore hasn't typed yet, waiting for the pane's shell (its startup asked something:
# scripts/type-commands.sh), is kept as it is, whatever runs there meanwhile; no venv put in front.
tmux set-option -p -t "$(printf '%s:%s.%s' $target)" @tmux-restore-pending "TMUX_RESTORE=1 claude --resume U1 --name x"
tmux set-option -g @tmux-restore-typing $$ # while it runs
printf 'pane\t%s\t%s\t1\t:*\t%s\tzsh\t:/tmp\t1\tssh-add\t:ssh-add /home/u/.ssh/id_ed25519\n' $target > "$D/save"
main "$D/save"
check "waiting command: kept" ":TMUX_RESTORE=1 claude --resume U1 --name x" "$(cut -f11 "$D/save")"
# once it's gone (killed), a waiting command left behind is ignored
tmux set-option -pu -t "$(printf '%s:%s.%s' $target)" @tmux-restore-venv
sh -c 'exit 0' & dead=$!; wait $dead
tmux set-option -g @tmux-restore-typing $dead
printf 'pane\t%s\t%s\t1\t:*\t%s\tzsh\t:/tmp\t1\tzsh\t:\n' $target > "$D/save"
main "$D/save"
check "waiting command, nothing typing it: ignored" ":" "$(cut -f11 "$D/save")"
tmux set-option -gu @tmux-restore-typing
tmux set-option -pu -t "$(printf '%s:%s.%s' $target)" @tmux-restore-pending
# A save with no panes (tmux couldn't be read: the server was going away) must not replace the
# good save: the hook makes it a copy of `last`, so resurrect sees no change and deletes it.
mkdir -p "$D/rs"
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:\nwindow\tmain\t0\t:zsh\t1\t:*\tlayout\t:\n' > "$D/rs/good.txt"
ln -s good.txt "$D/rs/last"
: > "$D/rs/empty.txt"
main "$D/rs/empty.txt"
check "empty save: becomes a copy of last" "$(cat "$D/rs/good.txt")" "$(cat "$D/rs/empty.txt")"
printf 'state\t\t\n' > "$D/rs/state-only.txt"
main "$D/rs/state-only.txt"
check "save without panes: becomes a copy of last" "$(cat "$D/rs/good.txt")" "$(cat "$D/rs/state-only.txt")"
check "good save: untouched" "$(printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:')" "$(head -1 "$D/rs/good.txt")"
# the scrollback archive is rebuilt from save/pane_contents after the save: put the old one back
mkdir -p "$D/arc/pane_contents" && echo HELLO > "$D/arc/pane_contents/pane-main:0.0"
tar cf - -C "$D/arc" ./pane_contents/ | gzip > "$D/rs/pane_contents.tar.gz"
: > "$D/rs/empty2.txt"
main "$D/rs/empty2.txt"
check "empty save: old scrollback put back for the archive" HELLO "$(cat "$D/rs/save/pane_contents/pane-main:0.0" 2> /dev/null)"
ln -fs empty3.txt "$D/rs/last"; : > "$D/rs/empty3.txt"
main "$D/rs/empty3.txt"
check "last is this very save: left alone" "" "$(cat "$D/rs/empty3.txt")"
ln -fs good.txt "$D/rs/last"
rm "$D/rs/last"; : > "$D/rs/first.txt"
main "$D/rs/first.txt"
check "empty save with no last: left as it is" "" "$(cat "$D/rs/first.txt")"
# While the system shuts down, the panes' programs are being stopped in parallel: a save then
# (tmux.service saving as it stops) must not replace the good one. The save at shutdown that
# comes first (scripts/shutdown-save.sh) says so, and is kept.
ln -fs good.txt "$D/rs/last"
systemctl() { echo stopping; }
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:\n' > "$D/rs/dying.txt"
main "$D/rs/dying.txt" 2> /dev/null
check "save while the system stops: becomes a copy of last" "$(cat "$D/rs/good.txt")" "$(cat "$D/rs/dying.txt")"
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tmake\t:make deploy\n' > "$D/rs/shutdown.txt"
TMUX_RESTORE_SHUTDOWN_SAVE=1 main "$D/rs/shutdown.txt"
check "the save at shutdown: kept and rewritten" ":TMUX_RESTORE=1 print -rz -- 'make deploy'" "$(cut -f11 "$D/rs/shutdown.txt")"
systemctl() { echo running; }
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:\n' > "$D/rs/normal.txt"
main "$D/rs/normal.txt"
check "save while running: kept" "$(printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:')" "$(cat "$D/rs/normal.txt")"
unset -f systemctl
# resurrect merges two tabs in a row, so a pane with an empty title is saved shifted: the folder
# where the title goes, and the pid after the command name. The hook puts a title back.
printf 'pane\tmain\t0\t1\t:*\t0\t:/srv/app\t1\tclaude\t4242\t:rm -rf build\n' > "$D/save"
main "$D/save"
IFS=$'\t' read -r _ _ _ _ _ _ title dir _ cmd full < "$D/save"
check "empty title: a title back" "$(hostname -s 2> /dev/null || hostname)" "$title"
check "empty title: folder in its place" ":/srv/app" "$dir"
check "empty title: command name in its place" "claude" "$cmd"
check "empty title: command from the wrong pid dropped" ":" "$full"
check "empty title: 11 fields" 11 "$(awk -F'\t' '{print NF}' "$D/save")"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
