#!/usr/bin/env bash
# Unit test for scripts/pre-restore.sh, scripts/post-save.sh and scripts/mend-last.sh with a fake tmux. A save made after the tmux server went
# away (at shutdown) is empty, and resurrect makes it `last`; resurrect only reads `last` after
# this hook, so the hook points `last` back at the newest save that has panes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/home"
cat > "$D/bin/tmux" <<EOF
#!/bin/sh
case "\$*" in
*@resurrect-dir*) cat "$D/dir-option" 2> /dev/null ;;
set-option*) echo "\$*" >> "$D/tmux.log" ;;
esac
exit 0
EOF
chmod +x "$D/bin/tmux"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
pane=$'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:'
# save DIR N [empty]: save number N in DIR (resurrect names them by time, so higher is newer)
save() {
	mkdir -p "$1"
	if [[ ${3:-} == empty ]]; then : > "$1/tmux_resurrect_$2.txt"; else printf '%s\n' "$pane" > "$1/tmux_resurrect_$2.txt"; fi
}
run() { : > "$D/tmux.log"; HOME="$D/home" XDG_DATA_HOME="" PATH="$D/bin:$PATH" bash "$here/../scripts/pre-restore.sh"; rc=$?; }
R=$D/home/.local/share/tmux/resurrect

save "$R" 1; save "$R" 2; save "$R" 3 empty
ln -s tmux_resurrect_3.txt "$R/last"
run
check "empty last: exit" 0 "$rc"
check "empty last: points at the newest save with panes" tmux_resurrect_2.txt "$(readlink "$R/last")"
check "still marks the restore" "set-option -g @tmux-restore-restored 1" "$(cat "$D/tmux.log")"

ln -fs tmux_resurrect_1.txt "$R/last"
run
check "good last: left alone" tmux_resurrect_1.txt "$(readlink "$R/last")"

rm -rf "$R"; save "$R" 1 empty; ln -s tmux_resurrect_1.txt "$R/last"
run
check "no save with panes: left alone" tmux_resurrect_1.txt "$(readlink "$R/last")"

C=$D/custom
# A literal ~, as written in a tmux config:
# shellcheck disable=SC2088
printf '%s' '~/../custom' > "$D/dir-option"
save "$C" 1; save "$C" 2 empty; ln -s tmux_resurrect_2.txt "$C/last"
run
check "@resurrect-dir (with ~) is followed" tmux_resurrect_1.txt "$(readlink "$C/last")"
rm "$D/dir-option"

mkdir -p "$D/home/.tmux/resurrect"; T=$D/home/.tmux/resurrect
save "$T" 1; save "$T" 2 empty; ln -s tmux_resurrect_2.txt "$T/last"
run
check "\$HOME/.tmux/resurrect, when it exists, is resurrect's default" tmux_resurrect_1.txt "$(readlink "$T/last")"
# two saves in the same second: one made the file `last`, the other deleted it as unchanged
rm -rf "$T"; R=$D/home/.local/share/tmux/resurrect; rm -rf "$R"
save "$R" 1; ln -s tmux_resurrect_9.txt "$R/last"
run
check "last points at nothing: mended" tmux_resurrect_1.txt "$(readlink "$R/last")"
ln -fs tmux_resurrect_9.txt "$R/last"; : > "$D/tmux.log"
HOME="$D/home" XDG_DATA_HOME="" PATH="$D/bin:$PATH" bash "$here/../scripts/post-save.sh"
check "post-save hook: mends it too" tmux_resurrect_1.txt "$(readlink "$R/last")"
rm -rf "$R"; mkdir -p "$R"; run
check "no saves at all: nothing made up" "" "$(ls -A "$R")"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
