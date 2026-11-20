# samartined/tmux-restore

A fork of [andrewboldi/tmux-restore](https://github.com/andrewboldi/tmux-restore), installed the
same way on every machine from a release tag. Read the upstream [README](README.md) for what the
tool does; this page lists what the fork changes, and how to install it, written so that a coding
agent can follow it step by step.

## What differs from upstream

| Change | Why | Upstream status |
|---|---|---|
| A timer saves every 5 minutes while nobody is attached (systemd on Linux, a LaunchAgent on macOS) | tmux-continuum saves only while a client is attached, so detached servers were saved only at shutdown | Not proposed yet. Same idea as tmux-plugins/tmux-continuum#157 (Linux only, by hand, unmerged) |
| An empty or dangling `last` (a save after the server went away; two saves in the same second) is pointed back at the newest good save: after every save, as the plugin loads, and before a restore | Otherwise the next start restores nothing: tmux-plugins/tmux-resurrect#576, tmux-plugins/tmux-continuum#166 | Not proposed yet |
| Answers Claude Code's home-folder trust prompt after a restore (opt-in: `TMUX_RESTORE_TRUST_HOME=1`) | Claude Code never saves trust for `$HOME`, so those sessions waited at the prompt after every restore, out of the app | Fork only |
| Claude Code sessions keep their name (`--name`) | Other sessions address them by name; a resumed session got a new one | Not proposed yet |
| Saves keep only each pane's visible screen, not its scrollback, and are deleted after 2 days instead of 30 | Less of what panes showed (a password, a token) sits on disk, and nothing to clean by hand | Fork only |
| A Claude Code still at a prompt on start keeps the conversation it was started for (`--resume <id>`), or comes back typed, never as `--continue` | It isn't registered until the prompt is answered: it was saved as `--continue`, which opened another pane's conversation | Not proposed yet |
| A save made while the system shuts down is dropped, and a pane with an empty title is saved unshifted | At shutdown `tmux.service` saved after the panes' programs had stopped, and an empty title shifted resurrect's fields: a reboot restored panes with no conversation, in the wrong folder | Not proposed yet. The empty title is a tmux-resurrect bug |
| tmux-restore types the saved commands itself after a restore, each once its pane's shell is at its prompt, instead of resurrect typing them as soon as the pane exists | At boot, a shell whose startup asks for a passphrase (keychain, `ssh-add`) took the agent's resume command as the passphrase: the conversation didn't come back and was gone from the next save | Not proposed yet |
| Session and window names lose `'` `"` `` ` `` `$` `\` `;` `&` `\|` `<` `>` `(` `)` in saves, old saves included | tmux-resurrect puts the session name into a command it runs through the shell to show a pane's saved contents, which this fork turns on: a name with them could run code at restore | Not proposed yet. The cause is in tmux-resurrect |
| Conversation ids from Gemini CLI, opencode and Claude Code are taken only in their own form, and quoted | An id from the agent's files went as it was into the command typed at restore | Not proposed yet |
| On macOS, process start times are read in English and UTC, and Claude Code's registry counts only when its start time is the process's | ps wrote the date in the user's language, which the parser didn't read: on a Mac in Spanish, say, Codex, Gemini CLI and opencode found no conversation. And without the check, after a reboot an old registry entry could name a new process with the same pid | Not proposed yet |
| The save folder is made 700 before the first save, and the saves 600 after every save | Every pane's command line and screen were readable by others until the hook first ran, and the files always | Not proposed yet |
| `tmux.service` (`@continuum-boot`) saves as it stops only when you stop it yourself: a drop-in points its save at `scripts/stop-save.sh` | At shutdown that save came once the server was gone: empty, and in the same second as the save before shutdown it deleted that one. `last` pointed at nothing and nothing was restored | Fork only (the boot unit is continuum's, turned on by this fork) |
| tmux starts at boot on Linux (`@continuum-boot`), and `--uninstall` turns that off again | After a power cut everything comes back with nobody logging in | Fork only |
| The installer installs this fork, can pin a ref (`TMUX_RESTORE_REF`), and doesn't install sqlite3 | One version on every machine; sqlite3 (opencode only) needed root | Fork only |

## Releases

| Tag | Upstream base | Notes |
|---|---|---|
| `fork.13` | `94c8488` | macOS: start times read in any language, Claude Code's registry checked by them; the tests pass on a real Mac (macOS 27, Apple silicon) |
| `fork.12` | `94c8488` | fixes from a security review: session and window names safe for the shell, conversation ids checked and quoted, saves readable by you only |
| `fork.11` | `94c8488` | at shutdown `tmux.service` doesn't save a second time, which could delete the first save and leave nothing to restore; a broken `last` is mended before any restore |
| `fork.10` | `94c8488` | saved commands are typed once each pane's shell is at its prompt: a startup asking for a passphrase no longer swallows them |
| `fork.9` | `94c8488` | a Claude Code at a prompt on start keeps its conversation, never becomes `--continue` |
| `fork.8` | `94c8488` | the home-folder trust prompt is answered in an 80-column pane too (its text wraps), and only for a `claude --resume <id>` |
| `fork.7` | `94c8488` | saves keep the visible screen only and are deleted after 2 days |
| `fork.6` | `94c8488` | fixes a reboot with fork.3–5 restoring no conversation: the save `tmux.service` made as it stopped replaced the good one. Update every Linux machine |
| `fork.5` | `94c8488` | `last` mended after every save too (two saves in the same second left it pointing at nothing) |
| `fork.4` | `94c8488` | home-folder trust answered after a restore (opt-in), session names kept |
| `fork.3` | `94c8488` | fork.2's start at boot also when installing into a running tmux |
| `fork.2` | `94c8488` | tmux starts at boot on Linux (only when tmux wasn't running at install: use fork.3) |
| `fork.1` | `94c8488` | first release |

## Install (instructions for an agent)

Work on this machine only. Don't kill, restart or attach to the user's tmux server or its
sessions: the installer loads into a running server without restoring over it.

1. **Check the machine.**
   - `uname -s`: Linux or Darwin. Anything else (Windows): stop and report.
   - Linux: `systemctl --user show-environment` must succeed (a systemd user session). If not, the
     install still works but saves only while a client is attached: report it.
   - macOS: `command -v brew` must succeed. If not, stop and ask the user to install Homebrew.
   - Note which of `tmux git jq` are missing. The installer installs them, with `sudo` on Linux.
     If `sudo -n true` fails, it would ask for a password: don't run the installer yet; give the
     user the exact command (e.g. `sudo apt-get install -y tmux git jq`) and wait.
2. **Get the release.**
   ```sh
   git clone https://github.com/samartined/tmux-restore ~/dev/tmux-restore 2>/dev/null ||
     git -C ~/dev/tmux-restore fetch --tags
   git -C ~/dev/tmux-restore checkout -q <tag>
   ```
   Use the newest tag in the Releases table above.
3. **Install.**
   ```sh
   cd ~/dev/tmux-restore && TMUX_RESTORE_REF=<tag> TMUX_RESTORE_TRUST_HOME=1 ./install.sh
   ```
   `TMUX_RESTORE_TRUST_HOME=1` is the user's choice for all their machines: see "Claude Code
   sessions after a restore" below.
   If it prints a `warning:` with a `sudo` command (lingering, say), pass that command to the user.
4. **Verify.**
   - `grep -A6 '>>> tmux-restore >>>' ~/.tmux.conf` (or `~/.config/tmux/tmux.conf`) names
     `samartined/tmux-restore#<tag>`.
   - Linux: `systemctl --user is-enabled tmux-restore.service tmux-restore-save.timer tmux.service`
     says `enabled` three times (`tmux.service` appears once tmux has loaded the plugins, which
     the installer does when tmux is running), and `loginctl show-user "$USER" -p Linger` says `Linger=yes`.
   - macOS: `launchctl print gui/$(id -u)/io.github.andrewboldi.tmux-restore.save` succeeds.
   - If tmux is running: `~/.tmux/plugins/tmux-restore/scripts/save-now.sh` prints `tmux saved`.
     Then `grep -c '^pane' ~/.local/share/tmux/resurrect/last` is at least 1, and each pane
     running Claude Code shows up in that file as `TMUX_RESTORE=1 claude --resume <id> ...`.
5. **Report** what was installed, the checks' results, and anything the user must do.

## Claude Code sessions after a restore

Any `claude` running inside tmux, on the default socket (no `-L`/`-S`), comes back in its exact
conversation, with its model, effort and other flags, its session name (`--name`) and Remote
Control on if it was. What to know when a session doesn't come back by itself:

- **Waiting at a trust prompt** ("Accessing workspace" or "Adding a new directory", with
  "No, exit" selected): the session hasn't started, so it isn't in the Claude app or in
  ListAgents.
  - For the home folder (`$HOME`), Claude Code never saves trust. With
    `TMUX_RESTORE_TRUST_HOME=1` tmux-restore answers it in the 2 minutes after a restore; see
    `~/.local/state/tmux-restore/trust.log`. Without it, the user decides: don't answer for them.
  - For a folder added with `--add-dir`, trust its repository for good:
    `projects["<repository root>"].hasTrustDialogAccepted = true` in `~/.claude.json` (back the
    file up first, write it atomically), or have the user answer once. Ask the user first.
- **A `--add-dir` folder that no longer exists** (in `/tmp`, after a reboot) doesn't stop it.
- **Two panes on one conversation** both come back on it, as they were.
- **Session names:** kept from fork.4 on. Earlier, a restored session got a new name: look it up
  again in ListAgents before messaging it.

## Update or remove

- Update: repeat steps 2–4 with the new tag.
- Remove: `~/dev/tmux-restore/install.sh --uninstall` (puts the tmux config back; leaves TPM,
  tmux-resurrect and tmux-continuum installed).
