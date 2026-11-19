# shellcheck shell=bash
# tmux-restore's shell hook, for zsh and bash. Source it from ~/.zshrc or ~/.bashrc (the line to
# add is in docs/how-it-works.md). At each prompt it tells tmux which Python virtual environment
# this pane has active, so that a restore activates it again. tmux only hears from it when that
# changes, and at the shell's first prompt, which also says the shell is ready: after a restore,
# scripts/type-commands.sh types the pane's command then.
if [ -n "${TMUX_PANE:-}" ]; then
	_tmux_restore_venv() {
		local last_status=$? # handed back, for prompts that show the last exit status
		# the first prompt says this shell is ready, and always reports, in case the pane's last
		# shell left a venv behind
		if [ -z "${_tmux_restore_venv_seen:-}" ]; then
			tmux set-option -p -t "$TMUX_PANE" @tmux-restore-prompt "$$" > /dev/null 2>&1
		elif [ "${VIRTUAL_ENV:-}" = "${_tmux_restore_venv_last:-}" ]; then
			return $last_status
		fi
		_tmux_restore_venv_seen=1
		_tmux_restore_venv_last=${VIRTUAL_ENV:-}
		if [ -n "$_tmux_restore_venv_last" ]; then
			tmux set-option -p -t "$TMUX_PANE" @tmux-restore-venv "$_tmux_restore_venv_last"
		else
			tmux set-option -pu -t "$TMUX_PANE" @tmux-restore-venv
		fi > /dev/null 2>&1
		return $last_status
	}
	if [ -n "${ZSH_VERSION:-}" ]; then
		autoload -Uz add-zsh-hook && add-zsh-hook precmd _tmux_restore_venv
	elif [ -n "${BASH_VERSION:-}" ]; then
		# after a newline rather than a ';': PROMPT_COMMAND may already end with one
		case ${PROMPT_COMMAND:-} in
		*_tmux_restore_venv*) ;;
		*) PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND
}_tmux_restore_venv" ;;
		esac
	fi
fi
