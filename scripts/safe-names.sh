#!/usr/bin/env bash
# safe-names.sh SAVE: in a tmux-resurrect save, replaces the characters a shell treats specially
# ( ' " ` $ \ ; & | < > ( ) ) in session and window names with "_". resurrect shows a pane's saved
# contents by running `cat '<folder>/pane-<session>:<window>.<pane>'; exec <shell>` through sh,
# with the session name inside the quotes as it is: a quote in a name would run what follows it
# at restore. Run on every save by the save hook (scripts/save-hook.sh), and before a restore on
# the save `last` points at (scripts/pre-restore.sh), for saves made before. Writes only when
# something changes, and through a link, so `last` stays one.
umask 077
file=$1
[ -f "$file" ] || exit 0
tmp=$file.safe-names.$$
UNSAFE="'\"\`\$\\;&|<>()" awk -F'\t' -v OFS='\t' '
	function safe(s,   out, i, c) {
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			out = out (index(unsafe, c) ? "_" : c)
		}
		return out
	}
	BEGIN { unsafe = ENVIRON["UNSAFE"] }
	$1 == "pane" || $1 == "window" || $1 == "state" || $1 == "grouped_session" { if (NF >= 2) $2 = safe($2) }
	$1 == "state" || $1 == "grouped_session" { if (NF >= 3) $3 = safe($3) }
	$1 == "window" { if (NF >= 4) $4 = safe($4) }
	{ print }
' "$file" > "$tmp" || { rm -f "$tmp"; exit 0; }
cmp -s "$file" "$tmp" || cat "$tmp" > "$file"
rm -f "$tmp"
exit 0
