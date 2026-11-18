#!/usr/bin/env bash
# tmux-restore installer (samartined fork). Re-run it to update; it changes nothing that's
# already in place.
#
#   git clone https://github.com/samartined/tmux-restore && cd tmux-restore
#   TMUX_RESTORE_REF=<tag> ./install.sh      # install that release (without it: the main branch)
#   ./install.sh --uninstall
#
# 1. Installs what's missing: tmux, git, jq (and gdbus on Linux with systemd). sqlite3, which
#    only opencode's sessions need, is used if present but never installed (that needs root).
# 2. Installs TPM, tmux-resurrect (with a fix for concurrent restores), tmux-continuum and
#    tmux-restore, and adds them to your tmux config (the original is kept as *.before-tmux-restore).
# 3. Saves right before shutdown: a systemd user service on Linux, a LaunchAgent on macOS.
# 4. Loads the plugins into your running tmux server, if there is one.
#
# TMUX_RESTORE_SOURCE overrides where tmux-restore is cloned from (a URL or a path ending in
# /tmux-restore); used for testing. TMUX_RESTORE_REF pins a branch or tag: the plugin is checked
# out at it, and your tmux config names it, so TPM keeps it there. Runs with macOS's bash 3.2: no
# bash 4 features here.
set -euo pipefail

RESTORE_URL=${TMUX_RESTORE_SOURCE:-https://github.com/samartined/tmux-restore}
RESTORE_PLUGIN=samartined/tmux-restore # how the tmux config names it for TPM
RESTORE_REF=${TMUX_RESTORE_REF:-}
# TMUX_RESTORE_TRUST_HOME=1: after a restore, answer Claude Code's home-folder trust prompt in the
# restored panes (@tmux-restore-trust-home, scripts/trust-home.sh). Off unless asked for.
TRUST_HOME=${TMUX_RESTORE_TRUST_HOME:-}
RESURRECT_URL=https://github.com/andrewboldi/tmux-resurrect
RESURRECT_BRANCH=fix-concurrent-restore
BEGIN="# >>> tmux-restore >>>"
END="# <<< tmux-restore <<<"
COMMENTED="#tmux-restore# "
UNIT=tmux-restore.service
SAVE_UNIT=tmux-restore-save # .service + .timer: saves every few minutes, attached or not
LABEL=io.github.andrewboldi.tmux-restore
SAVE_LABEL=$LABEL.save
# Exists if this installer turned on lingering, so that --uninstall turns it off again.
LINGER_MARK=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore/enabled-linger
# Exists if this installer turned on starting tmux at boot (Linux), so that --uninstall turns it off.
BOOT_MARK=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore/enabled-boot
BOOT=""

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}
have() { command -v "$1" > /dev/null 2>&1; }
systemd_dir() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }
user_systemd() { [ "$(uname -s)" = Linux ] && have systemctl && systemctl --user show-environment > /dev/null 2>&1; }

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif have sudo; then
		sudo "$@"
	else
		die "installing packages needs root, and sudo isn't available: $*"
	fi
}

# pkg_name MANAGER TOOL: the package that provides TOOL
pkg_name() {
	case $1:$2 in
	apt:gdbus) echo libglib2.0-bin ;;
	dnf:gdbus | yum:gdbus | pacman:gdbus) echo glib2 ;;
	zypper:gdbus) echo glib2-tools ;;
	apk:gdbus) echo glib ;;
	apt:sqlite3 | zypper:sqlite3) echo sqlite3 ;;
	*:sqlite3) echo sqlite ;;
	brew:flock) echo flock ;;
	*:flock) echo util-linux ;;
	*) echo "$2" ;;
	esac
}

install_packages() {
	local pm="" tool
	local -a pkgs=()
	if [ "$(uname -s)" = Darwin ]; then
		have brew || die "please install Homebrew (https://brew.sh) or these tools yourself: $*"
		pm=brew
	elif have apt-get; then pm=apt
	elif have dnf; then pm=dnf
	elif have yum; then pm=yum
	elif have pacman; then pm=pacman
	elif have zypper; then pm=zypper
	elif have apk; then pm=apk
	else die "please install these with your package manager, then run this again: $*"; fi
	for tool in "$@"; do pkgs+=("$(pkg_name "$pm" "$tool")"); done
	say "Installing ${pkgs[*]}"
	case $pm in
	brew) brew install -q "${pkgs[@]}" ;;
	apt) as_root apt-get update -qq && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" > /dev/null ;;
	dnf | yum) as_root "$pm" install -y -q "${pkgs[@]}" > /dev/null ;;
	pacman)
		# No -y: refreshing the package lists without upgrading everything is a partial upgrade,
		# which Arch doesn't support, and which fails when new packages need newer libraries.
		as_root pacman -S --noconfirm --needed "${pkgs[@]}" > /dev/null ||
			die "pacman couldn't install ${pkgs[*]}. Update your system first (sudo pacman -Syu), then run this again."
		;;
	zypper) as_root zypper -n -q install "${pkgs[@]}" > /dev/null ;;
	apk) as_root apk add -q "${pkgs[@]}" ;;
	esac
}

install_deps() {
	local -a need=()
	local tool
	for tool in tmux git jq; do have "$tool" || need+=("$tool"); done
	have sqlite3 || warn "sqlite3 isn't installed: opencode panes come back on their latest conversation (or typed), not their exact one. Install sqlite3 to fix that."
	if user_systemd; then
		for tool in gdbus flock; do have "$tool" || need+=("$tool"); done
	fi
	if [ "$(uname -s)" = Darwin ]; then
		# The save hook needs bash 4 (macOS ships 3.2); flock lets only one restore run at a time.
		[ -x /opt/homebrew/bin/bash ] || [ -x /usr/local/bin/bash ] || need+=(bash)
		have flock || need+=(flock)
	fi
	if [ ${#need[@]} -gt 0 ]; then install_packages "${need[@]}"; fi
	for tool in tmux git; do have "$tool" || die "$tool is still missing"; done
}

# The tmux config TPM reads: the XDG one if it exists, else ~/.tmux.conf.
tmux_conf() {
	local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
	if [ -f "$xdg" ]; then echo "$xdg"; else echo "$HOME/.tmux.conf"; fi
}

# Where TPM keeps plugins: TMUX_PLUGIN_MANAGER_PATH if the config sets it, else TPM's default.
plugins_dir() {
	local set
	set=$(sed -n 's/^[[:space:]]*set-environment[[:space:]].*TMUX_PLUGIN_MANAGER_PATH[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' "$CONF" 2> /dev/null | tail -1)
	if [ -n "$set" ]; then
		set=${set/#\~/$HOME}
		echo "${set%/}"
	elif [ "$CONF" = "$HOME/.tmux.conf" ]; then
		echo "$HOME/.tmux/plugins"
	else
		echo "$(dirname "$CONF")/plugins"
	fi
}

# clone URL DIR [BRANCH]
clone() {
	if [ -n "${3:-}" ]; then
		git -c advice.detachedHead=false clone -q --depth 1 -b "$3" "$1" "$2"
	else
		git clone -q --depth 1 "$1" "$2"
	fi
}

# Put tmux-resurrect on the branch with the concurrent-restore fix, unless it has local changes.
use_resurrect_fork() {
	local dir=$PLUGINS/tmux-resurrect
	if ! [ -d "$dir" ]; then
		clone "$RESURRECT_URL" "$dir" "$RESURRECT_BRANCH"
		return
	fi
	if ! git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
		warn "$dir isn't a git checkout; leaving it as is (no fix for concurrent restores)"
	elif [ -n "$(git -C "$dir" status --porcelain 2> /dev/null)" ]; then
		warn "$dir has local changes; leaving it as is (no fix for concurrent restores)"
	elif [ "$(git -C "$dir" remote get-url origin 2> /dev/null)" = "$RESURRECT_URL" ]; then
		git -C "$dir" pull -q --ff-only || warn "couldn't update $dir"
	else
		say "Switching tmux-resurrect to $RESURRECT_URL ($RESURRECT_BRANCH)"
		git -C "$dir" remote set-url origin "$RESURRECT_URL"
		git -C "$dir" config remote.origin.fetch "+refs/heads/$RESURRECT_BRANCH:refs/remotes/origin/$RESURRECT_BRANCH"
		git -C "$dir" fetch -q --depth 1 origin
		git -C "$dir" checkout -q -B "$RESURRECT_BRANCH" "origin/$RESURRECT_BRANCH"
	fi
}

install_plugins() {
	say "Installing plugins in $PLUGINS"
	mkdir -p "$PLUGINS"
	[ -x "$(tpm_path)" ] || clone https://github.com/tmux-plugins/tpm "$PLUGINS/tpm"
	use_resurrect_fork
	[ -d "$PLUGINS/tmux-continuum" ] || clone https://github.com/tmux-plugins/tmux-continuum "$PLUGINS/tmux-continuum"
	if ! [ -d "$PLUGINS/tmux-restore" ]; then
		clone "$RESTORE_URL" "$PLUGINS/tmux-restore" "$RESTORE_REF"
	elif [ -n "$RESTORE_REF" ]; then
		{ git -C "$PLUGINS/tmux-restore" fetch -q --depth 1 origin "$RESTORE_REF" &&
			git -C "$PLUGINS/tmux-restore" -c advice.detachedHead=false checkout -q FETCH_HEAD; } ||
			warn "couldn't switch $PLUGINS/tmux-restore to $RESTORE_REF"
	else
		git -C "$PLUGINS/tmux-restore" pull -q --ff-only || warn "couldn't update $PLUGINS/tmux-restore"
	fi
}

# same_file A B: A and B have the same contents (cmp isn't on minimal systems)
same_file() { [ "$(cat "$1"; echo .)" = "$(cat "$2"; echo .)" ]; }

# The config's line that runs TPM, if any.
tpm_run_line() { grep -E '^[[:space:]]*run(-shell)?[[:space:]].*tpm' "$CONF" 2> /dev/null | head -1 || true; }

# The TPM script the config runs, or where we install it.
tpm_path() {
	local tpm
	tpm=$(tpm_run_line | sed -E "s/^[[:space:]]*run(-shell)?[[:space:]]+(-b[[:space:]]+)?//; s/^['\"]//; s/['\"][[:space:]]*\$//")
	tpm=${tpm/#\~/$HOME}
	echo "${tpm:-$PLUGINS/tpm/tpm}"
}

# listed NAME FILE: FILE has an (uncommented) @plugin line for NAME, e.g. tmux-plugins/tpm
listed() { grep -Eq "^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@plugin[[:space:]]+[\"']$1[#\"']" "$2"; }

# The config without our block, with plain tmux-resurrect lines put back (stdin -> stdout).
strip_block() {
	awk -v b="$BEGIN" -v e="$END" -v c="$COMMENTED" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		skip { next }
		index($0, c) == 1 { print substr($0, length(c) + 1); next }
		{ print }'
}

edit_conf() {
	local tmp block run home_plugins spec
	tmp=$(mktemp)
	mkdir -p "$(dirname "$CONF")"
	touch "$CONF"
	strip_block < "$CONF" > "$tmp"
	# Our block replaces your tmux-resurrect line (same directory, the fork has the fix) and your
	# tmux-continuum line (it has to load last: it skips restoring if it sees other tmux
	# commands running, such as a plugin loading after it).
	awk -v c="$COMMENTED" '
		/^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@plugin[[:space:]]+["'\'']tmux-plugins\/tmux-(resurrect|continuum)[#"'\'']/ { print c $0; next }
		{ print }' "$tmp" > "$tmp.2"
	mv "$tmp.2" "$tmp"

	home_plugins=${PLUGINS/#$HOME/\~}
	block="$BEGIN"$'\n'
	listed tmux-plugins/tpm "$tmp" || block+="set -g @plugin 'tmux-plugins/tpm'"$'\n'
	block+="set -g @plugin 'andrewboldi/tmux-resurrect#$RESURRECT_BRANCH'"$'\n'
	spec=$RESTORE_PLUGIN
	[ -n "${TMUX_RESTORE_SOURCE:-}" ] && spec=$RESTORE_URL
	[ -n "$RESTORE_REF" ] && spec="$spec#$RESTORE_REF"
	block+="set -g @plugin '$spec'"$'\n'
	block+="set -g @plugin 'tmux-plugins/tmux-continuum'"$'\n'
	# continuum checks this as soon as it loads, possibly before tmux-restore sets it
	grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@continuum-restore[[:space:]]' "$tmp" ||
		block+="set -g @continuum-restore 'on'"$'\n'
	# Start tmux at boot, so that everything comes back with nobody logging in: continuum writes
	# and enables a systemd user unit, tmux.service (with lingering it starts at boot). Linux only:
	# on macOS continuum opens Terminal.app for it. Left alone if you set @continuum-boot yourself
	# or have a tmux.service of your own.
	if [ "$(uname -s)" = Linux ] && user_systemd &&
		! grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@continuum-boot[[:space:]]' "$tmp" &&
		{ ! [ -e "$(systemd_dir)/tmux.service" ] || grep -q '^Description=tmux default session (detached)$' "$(systemd_dir)/tmux.service"; }; then
		block+="set -g @continuum-boot 'on'"$'\n'
		BOOT=1
	fi
	if [ "$TRUST_HOME" = 1 ] &&
		! grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@tmux-restore-trust-home[[:space:]]' "$tmp"; then
		block+="set -g @tmux-restore-trust-home 'on'"$'\n'
	fi
	block+="$END"

	run=$(grep -nE '^[[:space:]]*run(-shell)?[[:space:]].*tpm' "$tmp" | head -1 | cut -d: -f1 || true)
	if [ -n "$run" ]; then
		{ awk -v n="$run" 'NR < n' "$tmp"; printf '%s\n' "$block"; tail -n +"$run" "$tmp"; } > "$tmp.2"
	else
		{ cat "$tmp"; [ -s "$tmp" ] && echo; printf '%s\n' "$block" "run '$home_plugins/tpm/tpm'"; } > "$tmp.2"
	fi
	mv "$tmp.2" "$tmp"

	if same_file "$tmp" "$CONF"; then
		rm -f "$tmp"
		return
	fi
	[ -s "$CONF" ] && ! [ -e "$CONF.before-tmux-restore" ] && cp "$CONF" "$CONF.before-tmux-restore"
	cat "$tmp" > "$CONF"
	rm -f "$tmp"
	say "Updated $CONF"
}

# launchd_env: sets LAUNCHD_PATH and LAUNCHD_LANG for the LaunchAgents. launchd's environment has
# no UTF-8 locale, and in the C locale tmux turns the tabs in tmux-resurrect's output into "_",
# which leaves the save empty; and its default PATH lacks Homebrew.
launchd_env() {
	local dir
	LAUNCHD_LANG=${LC_ALL:-${LANG:-}}
	case $LAUNCHD_LANG in *[Uu][Tt][Ff]-8 | *[Uu][Tt][Ff]8) ;; *) LAUNCHD_LANG=en_US.UTF-8 ;; esac
	LAUNCHD_PATH=/usr/bin:/bin:/usr/sbin:/sbin
	for dir in /usr/local/bin /opt/homebrew/bin "$(dirname "$(command -v jq || echo /usr/bin/jq)")" "$(dirname "$(command -v tmux)")"; do
		case ":$LAUNCHD_PATH:" in *":$dir:"*) ;; *) LAUNCHD_PATH="$dir:$LAUNCHD_PATH" ;; esac
	done
}

# macOS: saves every 5 minutes, attached or not (tmux-continuum saves only while a client is
# attached). Needs no compiler, unlike the shutdown watcher.
install_save_agent() {
	local plist="$HOME/Library/LaunchAgents/$SAVE_LABEL.plist"
	mkdir -p "$(dirname "$plist")"
	launchd_env
	cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$SAVE_LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>$PLUGINS/tmux-restore/scripts/save-now.sh</string><string>--periodic</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>$LAUNCHD_PATH</string><key>LANG</key><string>$LAUNCHD_LANG</string></dict>
	<key>StartInterval</key><integer>300</integer>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
	launchctl bootout "gui/$(id -u)/$SAVE_LABEL" 2> /dev/null || true
	if launchctl bootstrap "gui/$(id -u)" "$plist" 2> /dev/null; then
		say "Enabled the periodic save: tmux is saved every 5 minutes, attached or not"
	else
		warn "couldn't load $plist now; it starts at your next login"
	fi
}

# macOS: a small watcher, run by launchd, saves when macOS announces a logout, restart or shutdown.
install_launch_agent() {
	local plist="$HOME/Library/LaunchAgents/$LABEL.plist" bin="$PLUGINS/tmux-restore/bin/tmux-restore-shutdown"
	if ! have swiftc; then
		say "No Swift compiler (Xcode Command Line Tools): tmux is saved every 5 minutes, but not at shutdown"
		return 0
	fi
	mkdir -p "$(dirname "$bin")" "$(dirname "$plist")"
	if ! swiftc -O -o "$bin" "$PLUGINS/tmux-restore/scripts/shutdown-watcher.swift" 2> /dev/null; then
		warn "couldn't build the shutdown watcher; tmux is saved every 5 minutes, but not at shutdown"
		return 0
	fi
	launchd_env
	cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$bin</string><string>$PLUGINS/tmux-restore/scripts/save-now.sh</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>$LAUNCHD_PATH</string><key>LANG</key><string>$LAUNCHD_LANG</string></dict>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
	launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
	if launchctl bootstrap "gui/$(id -u)" "$plist" 2> /dev/null; then
		say "Enabled the shutdown save: tmux is saved as you log out, restart or shut down"
	else
		warn "couldn't load $plist now; it starts at your next login"
	fi
}

# The unit runs in the systemd user manager, which stops with the user's last login session
# unless the user lingers. A detached tmux outlives a logout, and then nothing saves it: the
# minute-by-minute save runs from the status line, which tmux draws only for an attached client.
# Lingering keeps the shutdown save and the 5-minute save running for a tmux nobody is attached
# to or logged in for.
enable_linger() {
	local user=${USER:-$(id -un)}
	have loginctl || return 0
	[ "$(loginctl show-user "$user" -p Linger --value 2> /dev/null)" = yes ] && return 0
	if loginctl enable-linger > /dev/null 2>&1; then
		{ mkdir -p "$(dirname "$LINGER_MARK")" && : > "$LINGER_MARK"; } 2> /dev/null || true
		say "Enabled lingering for $user: the saves keep running after you log out"
	else
		warn "couldn't enable lingering: after you log out, a detached tmux is only saved while a client is attached. Run: sudo loginctl enable-linger $user"
	fi
}

# Notes that tmux starts at boot because of us (continuum writes and enables tmux.service when it
# loads), and gives that unit a UTF-8 locale if the user manager has none: tmux-resurrect parses
# tab-separated tmux output, which a server in the C locale mangles, and every save would fail.
enable_boot() {
	{ mkdir -p "$(dirname "$BOOT_MARK")" && : > "$BOOT_MARK"; } 2> /dev/null || true
	if ! systemctl --user show-environment 2> /dev/null | grep -Eq '^(LC_ALL|LC_CTYPE|LANG)=.*[Uu][Tt][Ff]-?8'; then
		mkdir -p "$(systemd_dir)/tmux.service.d"
		printf '[Service]\nEnvironment=LANG=C.UTF-8\n' > "$(systemd_dir)/tmux.service.d/tmux-restore-locale.conf"
	fi
	say "tmux starts at boot (continuum's tmux.service), so everything comes back with nobody logging in"
}

# For --uninstall: stop starting tmux at boot, if enable_boot turned it on. tmux keeps running.
disable_boot() {
	[ -e "$BOOT_MARK" ] || return 0
	user_systemd && systemctl --user disable -q tmux.service 2> /dev/null || true
	rm -f "$(systemd_dir)/tmux.service" "$(systemd_dir)/tmux.service.d/tmux-restore-locale.conf"
	rmdir "$(systemd_dir)/tmux.service.d" 2> /dev/null || true
	user_systemd && systemctl --user daemon-reload || true
	rm -f "$BOOT_MARK"
	rmdir "$(dirname "$BOOT_MARK")" 2> /dev/null || true
	say "tmux no longer starts at boot (the running server is left alone)"
}

# For --uninstall: turn lingering off again, if enable_linger turned it on.
disable_linger() {
	[ -e "$LINGER_MARK" ] || return 0
	if loginctl disable-linger > /dev/null 2>&1; then
		rm -f "$LINGER_MARK"
		rmdir "$(dirname "$LINGER_MARK")" 2> /dev/null || true
		say "Turned lingering back off (the installer had turned it on)"
	else
		warn "couldn't turn lingering back off. Run: sudo loginctl disable-linger ${USER:-$(id -un)}"
	fi
}

install_service() {
	if [ "$(uname -s)" = Darwin ]; then
		install_save_agent
		install_launch_agent
		return
	fi
	if ! user_systemd; then
		[ "$(uname -s)" = Linux ] && say "No systemd user session: tmux is saved every minute while a client is attached, but not otherwise nor at shutdown"
		return 0
	fi
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" legacy path tool
	mkdir -p "$dir"
	sed "s|^ExecStart=.*|ExecStart=\"$PLUGINS/tmux-restore/scripts/shutdown-save.sh\"|" \
		"$PLUGINS/tmux-restore/systemd/$UNIT" > "$dir/$UNIT"
	path=/usr/local/bin:/usr/bin:/bin
	for tool in jq tmux; do
		have "$tool" && case ":$path:" in *":$(dirname "$(command -v "$tool")"):"*) ;; *) path="$(dirname "$(command -v "$tool")"):$path" ;; esac
	done
	sed -e "s|^ExecStart=.*|ExecStart=\"$PLUGINS/tmux-restore/scripts/save-now.sh\" --periodic|" \
		-e "s|^Environment=PATH=.*|Environment=PATH=$path|" \
		"$PLUGINS/tmux-restore/systemd/$SAVE_UNIT.service" > "$dir/$SAVE_UNIT.service"
	cat "$PLUGINS/tmux-restore/systemd/$SAVE_UNIT.timer" > "$dir/$SAVE_UNIT.timer"
	systemctl --user daemon-reload
	systemctl --user enable -q "$UNIT"
	systemctl --user restart "$UNIT"
	say "Enabled $UNIT: tmux is saved right before shutdown and reboot"
	systemctl --user enable -q --now "$SAVE_UNIT.timer"
	say "Enabled $SAVE_UNIT.timer: tmux is saved every 5 minutes, attached or not"
	enable_linger
	# An older copy of this setup ran a unit with another name; two at once would save twice.
	if systemctl --user -q is-enabled tmux-shutdown-save.service 2> /dev/null; then
		legacy=$(systemctl --user cat tmux-shutdown-save.service 2> /dev/null | grep '^ExecStart=' || true)
		case $legacy in
		*tmux-restore/scripts/tmux-shutdown-save.sh*) systemctl --user disable -q --now tmux-shutdown-save.service ;;
		*) warn "tmux-shutdown-save.service also saves at shutdown; disable one of them: systemctl --user disable --now tmux-shutdown-save.service" ;;
		esac
	fi
}

# Load the plugins into a running tmux server (continuum only restores into a server that just
# started, so this never restores over your open sessions).
load_into_tmux() {
	tmux has-session 2> /dev/null || return 0
	# The running server hasn't read the config's new lines; continuum checks this one as it loads.
	[ -n "$BOOT" ] && tmux set-option -g @continuum-boot on
	[ "$TRUST_HOME" = 1 ] && tmux set-option -g @tmux-restore-trust-home on
	tmux run-shell "$(tpm_path)" && say "Loaded into your running tmux server"
}

uninstall() {
	local tmp dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" hook
	if [ -f "$CONF" ]; then
		tmp=$(mktemp)
		strip_block < "$CONF" > "$tmp"
		if same_file "$tmp" "$CONF"; then rm -f "$tmp"; else cat "$tmp" > "$CONF" && rm -f "$tmp" && say "Removed tmux-restore from $CONF"; fi
	fi
	if [ -e "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
		launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
		rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
		say "Removed the shutdown save ($LABEL)"
	fi
	if [ -e "$HOME/Library/LaunchAgents/$SAVE_LABEL.plist" ]; then
		launchctl bootout "gui/$(id -u)/$SAVE_LABEL" 2> /dev/null || true
		rm -f "$HOME/Library/LaunchAgents/$SAVE_LABEL.plist"
		say "Removed the periodic save ($SAVE_LABEL)"
	fi
	if [ -e "$dir/$SAVE_UNIT.timer" ]; then
		user_systemd && systemctl --user disable -q --now "$SAVE_UNIT.timer" 2> /dev/null || true
		rm -f "$dir/$SAVE_UNIT.timer" "$dir/$SAVE_UNIT.service"
		user_systemd && systemctl --user daemon-reload || true
		say "Removed $SAVE_UNIT.timer"
	fi
	if [ -e "$dir/$UNIT" ]; then
		user_systemd && systemctl --user disable -q --now "$UNIT" 2> /dev/null || true
		rm -f "$dir/$UNIT"
		user_systemd && systemctl --user daemon-reload || true
		say "Removed $UNIT"
	fi
	disable_boot
	disable_linger
	if tmux has-session 2> /dev/null; then # give the running server its own hooks back
		hook=$(tmux show-option -gqv @resurrect-hook-post-save-layout)
		case $hook in */tmux-restore/scripts/save-hook.sh)
			tmux set-option -g @resurrect-hook-post-save-layout "$(tmux show-option -gqv @tmux-restore-next-hook)"
			tmux set-option -gu @tmux-restore-next-hook ;;
		esac
		hook=$(tmux show-option -gqv @resurrect-hook-post-save-all)
		case $hook in */tmux-restore/scripts/post-save.sh)
			tmux set-option -g @resurrect-hook-post-save-all "$(tmux show-option -gqv @tmux-restore-next-post-save-hook)"
			tmux set-option -gu @tmux-restore-next-post-save-hook ;;
		esac
		hook=$(tmux show-option -gqv @resurrect-hook-post-restore-all)
		case $hook in */tmux-restore/scripts/post-restore.sh)
			tmux set-option -g @resurrect-hook-post-restore-all "$(tmux show-option -gqv @tmux-restore-next-post-restore-hook)"
			tmux set-option -gu @tmux-restore-next-post-restore-hook ;;
		esac
		hook=$(tmux show-option -gqv @resurrect-hook-pre-restore-all)
		case $hook in */tmux-restore/scripts/pre-restore.sh)
			tmux set-option -g @resurrect-hook-pre-restore-all "$(tmux show-option -gqv @tmux-restore-next-pre-restore-hook)"
			tmux set-option -gu @tmux-restore-next-pre-restore-hook ;;
		esac
	fi
	[ -d "$PLUGINS/tmux-restore" ] && rm -rf "$PLUGINS/tmux-restore" && say "Removed $PLUGINS/tmux-restore"
	say "tmux-restore is uninstalled. tmux-resurrect and tmux-continuum are still installed."
}

main() {
	case ${1:-} in
	"" | --install) ;;
	--uninstall) ;;
	*) die "unknown option: $1 (use --uninstall to remove tmux-restore)" ;;
	esac
	CONF=$(tmux_conf)
	if [ "${1:-}" = --uninstall ]; then
		PLUGINS=$(plugins_dir)
		uninstall
		return
	fi
	install_deps
	PLUGINS=$(plugins_dir)
	install_plugins
	edit_conf
	[ -n "$BOOT" ] && enable_boot
	install_service
	load_into_tmux
	say "Done. tmux is saved every minute and comes back when tmux starts, agents and all."
	say "Try it: save with prefix + Ctrl-s, run 'tmux kill-server', then start tmux again."
}

# tests/install-linger.sh sources this file for its functions.
if [ -z "${TMUX_RESTORE_INSTALL_LIB:-}" ]; then main "$@"; fi
