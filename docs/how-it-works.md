# How it works

tmux-restore is a [TPM](https://github.com/tmux-plugins/tpm) plugin on top of
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (saves and restores tmux) and
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) (runs them automatically).

## Saving

Every minute, continuum runs resurrect's save. It records sessions, windows, pane layouts,
working directories and scrollback, plus each pane's full command line. Then resurrect calls
[`scripts/save-hook.sh`](../scripts/save-hook.sh), which rewrites each pane's saved command:

| The pane is running | Saved as | On restore |
|---|---|---|
| A coding agent | the agent's resume command, e.g. `claude --resume <id> --model opus` | the same conversation reopens, with the same flags |
| A safe program (vim, htop, less, ...) | unchanged | it restarts |
| A monitor or log follower resurrect doesn't list (`nvtop`, `journalctl -f`, `kubectl logs -f`, ...) | `TMUX_RESTORE=1 <command>` | it restarts, with any shell |
| Anything else (`make deploy`, a dev server) | `print -rz -- '<command>'` | the command is typed on the zsh prompt, waiting for Enter |

A safe program is one tmux-resurrect restarts by itself, by its own rules: one of its defaults,
or a match for an entry in your `@resurrect-processes`. An entry `"git log"` matches commands
that start with `git log`, and `"btop->btop --utf-force"` matches `btop`. A `"~pattern"` entry
counts only if it has a `->`; otherwise its commands come back typed.

tmux-restore restarts a few more programs that are safe to run again: the monitors `btop`,
`nvtop`, `iotop` and `nethogs`, and `journalctl`, `docker logs`, `docker compose logs` and `kubectl logs`
when they follow logs (`-f`, `--follow`, or a group of short flags with `f` in it, like `-fu`).
`logs` has to come right after the program name, so `kubectl -n prod logs -f` comes back typed.
So does anything run with `sudo`, which would ask for a password.

The initial prompt and the flags that pick a conversation (`--continue`, `--resume`, ...) are
dropped from an agent's command. A rewritten command starts with `TMUX_RESTORE=1 `, and
tmux-restore adds that prefix to resurrect's list of programs to re-run. With a shell other than
zsh, "anything else" is left unchanged, so resurrect doesn't re-run it.

### Finding each agent's conversation

Each agent has a small adapter in [`agents/`](../agents). It recognizes the agent's process and
finds the id of the conversation that process has open, from the agent's own session files. See
[agents.md](agents.md) for what each one reads.

If the id can't be found, the adapter falls back to the agent's "continue the latest
conversation in this directory" command. If two panes would use that fallback in the same
directory, they'd both reopen the same conversation, so both get the pre-typed command instead.

### Python virtual environments

The venv a shell has active can't be seen from outside the shell, so a small hook in your
`~/.zshrc` or `~/.bashrc` ([`scripts/shell-hook.sh`](../scripts/shell-hook.sh)) tells tmux, at
each prompt, which venv the pane has active. The save hook then puts `. <venv>/bin/activate`
before the command it writes for that pane, or saves it alone for an idle pane, so the restore
activates the venv first. A venv deleted in the meantime is skipped without an error. A program
that tmux-resurrect restarts itself (vim, htop, ...) keeps its command as it is, and comes back
without the venv.

To turn it on, add this line to `~/.zshrc` or `~/.bashrc` (with plugins in
`~/.config/tmux/plugins`, use that path):

```sh
[ -r ~/.tmux/plugins/tmux-restore/scripts/shell-hook.sh ] && . ~/.tmux/plugins/tmux-restore/scripts/shell-hook.sh
```

## Saving at shutdown

On Linux with systemd, [`tmux-restore.service`](../systemd/tmux-restore.service) runs
[`scripts/shutdown-save.sh`](../scripts/shutdown-save.sh) under
`systemd-inhibit --mode=delay`. When the machine announces a shutdown or reboot (logind's
`PrepareForShutdown`), it saves, and logind waits for it.

On macOS, the installer builds [a small watcher](../scripts/shutdown-watcher.swift) and runs it
as a LaunchAgent. macOS announces a logout, restart or shutdown to running programs before apps
quit (`NSWorkspace.willPowerOffNotification`), and the watcher saves then. Its log is
`~/Library/Logs/tmux-restore.log`.

## Saving while nobody is attached

continuum's save runs from tmux's status line, which tmux draws only for an attached client, so a
detached tmux (a server reached over SSH, sessions started with `tmux new -d`) wouldn't be saved
until shutdown. A timer saves it every 5 minutes too: on Linux
[`tmux-restore-save.timer`](../systemd/tmux-restore-save.timer), on macOS a LaunchAgent
(`io.github.andrewboldi.tmux-restore.save`). Both run
[`scripts/save-now.sh --periodic`](../scripts/save-now.sh), which skips a server that started
less than 5 minutes ago (it may still be restoring) and a save continuum made in the last 4
minutes.

## A save that finds no panes

A save made after the server went away (at shutdown, when its panes stop before the save runs)
finds no panes, and resurrect still makes that empty save `last`: the next start would restore
nothing ([tmux-resurrect#576](https://github.com/tmux-plugins/tmux-resurrect/pull/576)). resurrect
reads `last` only after its pre-restore-all hook, so
[`scripts/pre-restore.sh`](../scripts/pre-restore.sh) points an empty `last` back at the newest
save that has panes ([`scripts/mend-last.sh`](../scripts/mend-last.sh)). Two saves in the same
second (the 5-minute save and continuum's, say) write the same file: one makes it `last`, the
other finds it unchanged and deletes it, so `last` points at nothing and a restore wouldn't even
start. The post-save-all hook ([`scripts/post-save.sh`](../scripts/post-save.sh)) runs the same
mending after every save. A save of a live server that reads no panes (tmux in the C locale turns
resurrect's tabs into `_`) is caught earlier: the save hook makes it a copy of `last`, so resurrect
deletes it, and puts the old scrollback back for the archive resurrect rebuilds next.

## A save while the system shuts down

At shutdown systemd stops units in parallel: the scopes your panes run in, and `tmux.service`
(`@continuum-boot`), which saves as it stops. That save can find the panes' programs gone or
exiting: no conversation to resume, panes with no command. The save hook drops any save made while
the system or your systemd user manager is stopping (`systemctl is-system-running` says
`stopping`), the same way as a save with no panes: `last` stays the save taken before shutdown
began. That one, from [`scripts/shutdown-save.sh`](../scripts/shutdown-save.sh), sets
`TMUX_RESTORE_SHUTDOWN_SAVE=1` and is kept.

## A pane with an empty title

resurrect reads its own fields with `read`, which merges two tabs in a row, so a pane whose title
is empty (a program can clear it as it exits) is saved shifted: its folder where the title goes,
and its pid after the command name. Restored, that pane would open in the wrong folder. The save
hook puts a title back (the host name, tmux's default) and drops the command resurrect worked out
from the wrong pid; an agent's conversation is still found from the pane itself.

The minute-by-minute and 5-minute saves cover crashes and power loss.

## Restoring

When the tmux server starts, continuum runs resurrect's restore. Sessions, windows, layouts and
scrollback come back, then the saved commands run, including each agent's resume command.

### The concurrent-restore fix

tmux-resurrect restores a pane with "pane missing, window exists: split the window". If two
restores run at once, both split, and the extra panes get squashed to one line. Two restores
happen at login when something runs `tmux start-server` before the real server starts
(tmuxinator does): continuum on that first server queues a restore, the server exits, and the
restore lands on the real server, which has queued its own.

The installer therefore uses tmux-resurrect from
[a branch that allows one restore at a time](https://github.com/andrewboldi/tmux-resurrect/tree/fix-concurrent-restore),
proposed upstream as
[tmux-resurrect#600](https://github.com/tmux-plugins/tmux-resurrect/pull/600) (likely the cause of
[#437](https://github.com/tmux-plugins/tmux-resurrect/issues/437)).
[`tests/restore-race.sh`](../tests/restore-race.sh) restores a 29-window save twice at once:
upstream gets 2 to 6 windows wrong per run, the branch none.

### Claude Code's home-folder trust prompt

Claude Code never saves trust for the home folder, so a session working in `$HOME` waits at the
trust prompt after every restore. With `@tmux-restore-trust-home` on, resurrect's
post-restore-all hook ([`scripts/post-restore.sh`](../scripts/post-restore.sh)) starts
[`scripts/trust-home.sh`](../scripts/trust-home.sh) in the background. For 2 minutes it looks at
the panes working in `$HOME`; one that shows exactly the trust prompt for `$HOME`, with "No, exit"
selected, gets Down, and once "Yes, I trust this folder" is selected, Enter. Each answer goes in
`~/.local/state/tmux-restore/trust.log`. See [caveats](caveats.md) for why that's safe.

## Options

tmux-restore sets these only if you haven't set them yourself:

| Option | Value |
|---|---|
| `@continuum-restore` | `on`: restore when the tmux server starts (the installer also writes it into your config, because continuum reads it before plugins listed after it load) |
| `@continuum-save-interval` | `1`: save every minute |
| `@continuum-boot` | `on` on Linux with systemd: tmux starts at boot (the installer writes it into your config) |
| `@tmux-restore-trust-home` | off; `on` answers Claude Code's home-folder trust prompt after a restore (the installer writes it with `TMUX_RESTORE_TRUST_HOME=1`) |
| `@resurrect-capture-pane-contents` | `on`: keep what each pane showed |
| `@resurrect-pane-contents-area` | `visible`: only the screen, not the whole scrollback |
| `@resurrect-delete-backup-after` | `1`: saves are deleted once 2 days old (resurrect counts whole days past 1), always keeping the newest 5 |
| `@resurrect-save-command-strategy` | `linux_procfs` on Linux: exact command lines |

It always sets two tmux-resurrect hooks, and a hook you already had there runs after its own:
`@resurrect-hook-post-save-layout` (the save hook) and `@resurrect-hook-pre-restore-all`, which
marks that a restore started. tmux-continuum skips its restore at startup if it counts other tmux
processes, and it can count the new server's own short-lived forks; if no restore has started
three seconds after the server did, tmux-restore runs it, under continuum's other conditions
([`scripts/restore-safety-net.sh`](../scripts/restore-safety-net.sh)).

## Files

| File | What it does |
|---|---|
| [`install.sh`](../install.sh) | installs everything and edits your tmux config (`--uninstall` undoes it) |
| [`tmux-restore.tmux`](../tmux-restore.tmux) | the plugin: sets the options above |
| [`scripts/save-hook.sh`](../scripts/save-hook.sh) | rewrites saved commands |
| [`scripts/shell-hook.sh`](../scripts/shell-hook.sh) | tells tmux which Python venv each pane has active |
| [`scripts/lib.sh`](../scripts/lib.sh) | process inspection (`/proc`, or `ps`/`lsof`) and flag filtering |
| [`agents/*.sh`](../agents) | one adapter per agent |
| [`scripts/shutdown-save.sh`](../scripts/shutdown-save.sh) | the save at shutdown (Linux) |
| [`scripts/shutdown-watcher.swift`](../scripts/shutdown-watcher.swift) | the save at shutdown (macOS) |
