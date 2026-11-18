#!/usr/bin/env bash
# Unit test for scripts/save-now.sh with fake tmux and save.sh. Without arguments (the macOS
# shutdown watcher) it saves whenever a tmux server runs. With --periodic (the timer that saves
# while nobody is attached) it also skips a server that started less than 5 minutes ago (it may
# still be restoring) and a save tmux-continuum made in the last 4 minutes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
cat > "$D/bin/tmux" <<EOF
#!/bin/sh
case "\$*" in
has-session*) [ -e "$D/server" ] ;;
*@resurrect-save-script-path*) echo "$D/save.sh" ;;
*@continuum-save-last-timestamp*) cat "$D/continuum" 2> /dev/null ;;
*start_time*) cat "$D/started" ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >> "%s/saves"\n' "$D" > "$D/save.sh"
chmod +x "$D/bin/tmux" "$D/save.sh"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
now=$(date +%s)
# run SERVER STARTED_AGO CONTINUUM_AGO [ARG]: a server or not, started and last saved by continuum
# that many seconds ago ("" = never); sets rc and saves (what save.sh was called with)
run() {
	rm -f "$D/server" "$D/continuum"; : > "$D/saves"
	[[ $1 == yes ]] && : > "$D/server"
	echo $((now - $2)) > "$D/started"
	[[ -n $3 ]] && echo $((now - $3)) > "$D/continuum"
	PATH="$D/bin:$PATH" bash "$here/../scripts/save-now.sh" ${4:+"$4"} > /dev/null; rc=$?
	saves=$(cat "$D/saves")
}
run no 3600 "" --periodic
check "periodic, no server: exit" 0 "$rc"; check "periodic, no server: no save" "" "$saves"
run yes 3600 "" --periodic
check "periodic, settled server: exit" 0 "$rc"; check "periodic, settled server: saves" quiet "$saves"
run yes 60 "" --periodic
check "periodic, server just started (may be restoring): no save" "" "$saves"
run yes 3600 60 --periodic
check "periodic, continuum saved a minute ago: no save" "" "$saves"
run yes 3600 600 --periodic
check "periodic, continuum saved 10 minutes ago: saves" quiet "$saves"
run yes 60 60
check "shutdown watcher: saves even a new server" quiet "$saves"
run no 3600 ""
check "shutdown watcher, no server: no save" "" "$saves"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
