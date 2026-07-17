# Terminal Keyboard and Process-Control Contract

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** Keyboard translation from macOS events to PTY bytes and local XMterm commands
- **Canonical requirements:** `TERM-KEY-001` through `TERM-KEY-004`, `TERM-PROC-001`

**Implementation note (Phase 2):** local and fixed-relay tabs share this exact
keyboard pipeline. `Command-T` remains a new local terminal, the plus/File menu
adds `Connect to Relay Host`, and no new Command shortcut steals Control bytes.
Automated tests exercise the shared SSH input path; the real relay key matrix is a
manual checklist and is not inferred from those tests.

## Purpose

A terminal has two distinct keyboard namespaces:

1. **local macOS application shortcuts**, normally using `Command`;
2. **remote terminal input**, normally using `Control`, ordinary characters, and
   xterm escape sequences.

XMterm must preserve this boundary. A familiar desktop shortcut must not corrupt
remote input, and a remote Control key must not accidentally trigger a local UI
action.

## Important correction

`Control-V` is not the terminate key. In a Unix terminal it is normally delivered
as byte `0x16`; readline and many shells use it to quote or literally insert the
next character. The usual current-command interrupt is `Control-C`.

On macOS:

- paste is `Command-V`;
- interrupt is `Control-C`;
- close terminal tab is `Command-W`;
- `Control-W` remains available to the remote shell, where it commonly deletes the
  previous word.

## Input pipeline

```text
macOS key event
    ↓
XMterm local-shortcut resolver
    ├── Command shortcut → local application action
    └── terminal input → terminal keyboard encoder
                           ↓
                      PTY byte stream
                           ↓
                      /usr/bin/ssh
                           ↓
                    remote TTY / program
```

XMterm must not infer high-level shell intent from a Control byte. It sends the
correct input; the remote TTY mode or program decides the result.

## Required Control-key behavior

| User input | PTY data | Typical remote result | XMterm behavior |
|---|---|---|---|
| `Control-C` | `03` | `SIGINT` to foreground process | Send byte only; do not locally kill the SSH process. |
| `Control-Z` | `1A` | `SIGTSTP` / job suspension | Send byte only. |
| `Control-\` | `1C` | `SIGQUIT`, possibly core dump | Send byte only. |
| `Control-D` | `04` | EOF in canonical mode; may exit shell | Send byte only. |
| `Control-V` | `16` | Quoted insert in many shells | Send byte only; never treat as paste. |
| `Control-S` | `13` | XOFF / output pause when IXON is enabled | Send byte; UI may show a nonintrusive hint if output appears flow-controlled. |
| `Control-Q` | `11` | XON / output resume | Send byte. |
| `Control-L` | `0C` | Clear/redraw | Send byte; this is different from clearing XMterm scrollback. |
| `Control-R` | `12` | Reverse history search in readline | Send byte. |
| `Control-A` | `01` | Beginning of line in readline Emacs mode | Send byte. |
| `Control-E` | `05` | End of line in readline Emacs mode | Send byte. |
| `Control-U` | `15` | Kill to beginning of line | Send byte. |
| `Control-K` | `0B` | Kill to end of line | Send byte. |
| `Control-W` | `17` | Delete previous word | Send byte; do not close tab. |
| `Control-H` | `08` | Backspace | Send byte when that key combination is pressed. |
| `Control-I` | `09` | Tab | Send byte. |
| `Control-J` | `0A` | Line feed | Send byte. |
| `Control-M` | `0D` | Carriage return / Enter | Send byte. |
| `Control-[` | `1B` | Escape | Send byte. |

“Typical remote result” is informational only. In raw mode, full-screen programs
may consume the bytes directly and behave differently.

The encoder must also implement the general ASCII Control mapping rather than only
the examples above: `Control-A` through `Control-Z`, `Control-@`/`Control-Space`
(NUL), `Control-[` (Escape), `Control-\`, `Control-]`, `Control-^`,
`Control-_`, and `Control-?` (DEL) where macOS delivers a distinguishable key
event. Layout-dependent shortcuts must be tested with non-US keyboard layouts.

## Required local Command shortcuts

| Shortcut | Local action | Remote bytes sent |
|---|---|---|
| `Command-C` | Copy selected terminal text | None |
| `Command-V` | Paste clipboard into active terminal | Clipboard payload only |
| `Command-F` | Search active tab's scrollback | None |
| `Command-T` | Open a new terminal tab | None |
| `Command-W` | Close active terminal tab after required confirmation | None |
| `Command-1…9` | Select terminal tab | None |
| `Command-Shift-[` / `]` | Previous/next tab | None |
| `Command-+` / `Command--` | Increase/decrease terminal font size | None |
| `Command-0` | Reset terminal font size | None |
| `Command-K` | Clear local scrollback/history according to the Terminal menu action | None |
| `Command-Shift-T` | Reopen the most recently closed terminal profile as a fresh connection | None |

When terminal text is selected, typing ordinary text clears the selection and sends
that text to the PTY. Copying does not clear the selection. Clicking the terminal
returns keyboard focus to it.

## Backspace, Delete, Home, and End

Different servers and applications expect different sequences. XMterm therefore
needs a compatibility profile rather than hard-coding one assumption.

Minimum preferences:

- Backspace sends `DEL (0x7F)` by default, with optional `BS (0x08)`;
- Forward Delete sends an xterm delete sequence;
- Home/End follow xterm/application cursor mode;
- Option-Left/Right can send Meta-b/Meta-f or native characters according to the
  Option/Meta preference.

The selected mapping must apply consistently to local shell and SSH tabs.

Additional required keys:

- `Shift-Tab` sends the reverse-tab sequence expected by xterm applications;
- function keys and keypad keys follow normal/application keypad modes;
- modified arrows preserve Shift/Option/Control modifiers according to the selected
  compatibility profile;
- `Fn-Delete` is treated as Forward Delete on Apple keyboards;
- numeric keypad Enter remains distinguishable when the terminal protocol supports
  it;
- hardware key repeat sends one ordered stream without dropped or duplicated bytes.

## Full-screen and alternate-screen applications

Programs such as `vim`, `nano`, `less`, `htop`, `top`, and interactive REPLs must
receive their key sequences unchanged. XMterm must honor:

- application cursor-key mode;
- application keypad mode;
- alternate-screen entry and exit;
- mouse reporting;
- bracketed paste;
- terminal resize events (`SIGWINCH` through PTY resize);
- focus in/out reporting only when explicitly supported by the terminal engine.

Local selection remains available with `Option-drag` when mouse reporting is active.

## Process-control and close semantics

These actions are intentionally different:

```text
Control-C     interrupt foreground program
Control-Z     suspend foreground job
Control-D     send EOF/input termination
Control-\     request quit
Command-W     close XMterm tab and SSH connection
```

Closing the tab must close the PTY/SSH process through the process-management API.
It must not simulate shell input such as `exit`, `Control-D`, or `Control-C`.

For a local PTY, `Command-W` queries the kernel foreground process group. An idle
shell closes immediately; a different foreground group receives confirmation.
This does not change any Control-byte mapping and never injects shell input.

Because XMterm cannot reliably know the remote foreground process without shell
integration, v0.1 must not claim perfect remote “idle versus busy” detection. A
connected SSH session close confirmation should say:

> Close this terminal? Its SSH session will end, and a foreground command running
> in this tab may also be terminated.

An exited, failed, or disconnected tab closes immediately. An unexpected local
foreground-query failure uses one conservative prompt; an already-closed local PTY
does not.

## Paste safety

- `Command-V` is always a local paste action.
- `Control-V` is always terminal input.
- Bracketed paste wrappers are added only when the remote application enabled the
  mode.
- Multi-line paste protection is optional but enabled by default for shell-like
  screens.
- Cancelling a paste sends zero bytes.
- XMterm must not trim commands, append Return, or execute clipboard content on its
  own.

## IME and Unicode

XMterm must accept text from macOS input methods, including Chinese input, dead
keys, composed accents, emoji, and non-BMP Unicode. Committed text is encoded as
UTF-8 for the PTY. Composition previews remain local until the input method commits
them.

## Manual verification matrix

1. Run `cat -v`, press each Control combination, and verify the expected byte display
   where the remote TTY permits it.
2. Run `sleep 60`; verify `Control-C` interrupts it.
3. Run `sleep 60`; verify `Control-Z`, `jobs`, `fg`, and `bg` work.
4. At an empty shell prompt, verify `Control-D` can close the shell.
5. Verify `Control-V`, then `Control-C`, inserts a literal `^C` in readline instead
   of interrupting.
6. Press `Control-S` and verify `Control-Q` resumes output on systems with IXON.
7. Verify `Command-V` pastes while `Control-V` does not.
8. Verify `Command-W` closes the tab while `Control-W` edits the remote line.
9. Test `vim`, `nano`, `less`, `htop`, Python REPL, and an SSH session nested inside
   another SSH session.
10. Test Chinese IME composition and Unicode copy/paste.
11. Test Backspace/Delete/Home/End against bash, zsh, vim, and remote Linux shells.
12. Resize the window while a full-screen program is active and verify correct
    redraw.
