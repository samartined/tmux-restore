#!/usr/bin/env bash
# tmux.service's save as it stops (@continuum-boot), in place of tmux-continuum's: install.sh
# points the unit at this (tmux.service.d/tmux-restore-stop.conf). At shutdown
# scripts/shutdown-save.sh has saved already, before anything stopped. A second save then finds
# the server gone, or going, and only does harm: saves are named by the second, so one in the same
# second rewrites that save's file, finds it the same as `last` (it is `last`) and deletes it, and
# `last` points at nothing. So this saves only when tmux.service is stopped by hand: with the
# server there and the system running. $1 is tmux's path, for a tmux outside the unit's PATH.
[ -n "${1:-}" ] && PATH="$(dirname "$1"):$PATH"
tmux has-session 2> /dev/null || exit 0
[ "$(systemctl is-system-running 2> /dev/null)" = stopping ] && exit 0
[ "$(systemctl --user is-system-running 2> /dev/null)" = stopping ] && exit 0
save=$(tmux show-option -gqv @resurrect-save-script-path) # set by tmux-resurrect
exec "${save:-$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}" quiet
