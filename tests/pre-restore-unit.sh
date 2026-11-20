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
list-panes*) printf '%%1\n%%2\n' ;;
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
check "still marks the restore" "set-option -g @tmux-restore-restored 1" "$(head -1 "$D/tmux.log")"
check "notes the panes already there" "set-option -g @tmux-restore-existing %1 %2 " "$(sed -n 2p "$D/tmux.log")"

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

# A save made before session names were made safe (the security review's finding 1): before
# resurrect reads it, the names in the save `last` points at lose what a shell treats specially.
printf '%s\n' "pane	x'; cd; touch MARK; '	0	1	:*	0	t	:/tmp	1	zsh	:" > "$R/tmux_resurrect_5.txt"
ln -s tmux_resurrect_5.txt "$R/last"
run
check "unsafe name in last: made safe" "x__ cd_ touch MARK_ _" "$(cut -f2 "$R/last")"
check "...and last is still a link to that save" tmux_resurrect_5.txt "$(readlink "$R/last")"
printf '%s\n' "$pane" > "$R/tmux_resurrect_6.txt"; ln -fs tmux_resurrect_6.txt "$R/last"
touch -t 202001010000 "$R/tmux_resurrect_6.txt"; : > "$D/ref"
run
check "safe names: the save isn't rewritten" yes "$([[ $R/tmux_resurrect_6.txt -ot $D/ref ]] && echo yes)"

# The saves hold each pane's command line and screen, a password or token included: only you can
# read them (the security review's finding 3), old ones too.
perm() { stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"; }
rm -rf "$R"; (umask 022 && save "$R" 1 && save "$R" 2 && : > "$R/pane_contents.tar.gz"); chmod 755 "$R"
ln -s tmux_resurrect_2.txt "$R/last"
HOME="$D/home" XDG_DATA_HOME="" PATH="$D/bin:$PATH" bash "$here/../scripts/post-save.sh"
check "post-save: the folder is yours only" 700 "$(perm "$R")"
check "post-save: the saves are yours only" "600 600" "$(perm "$R/tmux_resurrect_1.txt") $(perm "$R/tmux_resurrect_2.txt")"
check "post-save: the screens are yours only" 600 "$(perm "$R/pane_contents.tar.gz")"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
