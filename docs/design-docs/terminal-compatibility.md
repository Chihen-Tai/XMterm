# Terminal Compatibility and Rendering Contract

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** Terminal emulation, rendering, resize, links, titles, bell, and Unicode
- **Canonical requirements:** `TERM-RENDER-*`, `TERM-RESIZE-001`, `TERM-LINK-001`,
  `TERM-BELL-001`, `TERM-STATE-001`, and `TERM-SEL-004`

**Implementation note (Phase 2):** the fixed relay executes system OpenSSH inside
the already verified real PTY and reuses the same SwiftTerm adapter, resize path,
bounded scrollback, selection, clipboard policy, and output filter. This does not
upgrade the deferred full compatibility, dynamic-title, bell, link, reconnect, or
VoiceOver claims below.

## Goal

XMterm must behave like a real interactive xterm-compatible terminal, not merely a
text view connected to SSH. It must advertise only capabilities it actually
implements and remain correct with shells, editors, pagers, REPLs, and full-screen
terminal applications.

## Terminal identity

- XMterm launches SSH inside a real PTY.
- The default `TERM` value may be `xterm-256color` only after the selected terminal
  engine passes the corresponding compatibility tests.
- XMterm must never advertise a terminal capability that it does not implement.
- Per-profile terminal identity may be configurable for compatibility, but changing
  it is an advanced setting.
- Locale and encoding are not guessed from remote filenames. Terminal input/output
  is UTF-8 by default while OpenSSH remains responsible for environment forwarding.

## Required screen behavior

The terminal engine must support the xterm/VT behavior needed by common Linux tools:

- cursor addressing, insertion, deletion, erase, and scroll regions;
- normal and alternate screen buffers;
- application cursor and keypad modes;
- SGR attributes including bold, faint, italic, underline, inverse, and strike;
- 16-color, 256-color, and true-color rendering when advertised;
- cursor visibility, style, and blink state;
- save/restore cursor and screen state;
- bracketed paste and mouse-reporting modes;
- synchronized output if the chosen engine supports it;
- correct terminal reset and soft-reset behavior.

Unknown or unsupported sequences must be ignored safely rather than displayed as
ordinary text or causing a crash.

## Unicode and cell width

Rendering and selection must correctly account for:

- UTF-8 decoding across chunk boundaries;
- combining marks and composed characters;
- East Asian wide and full-width characters;
- emoji, variation selectors, and zero-width joiner sequences;
- non-BMP characters;
- ambiguous-width characters according to a documented width policy;
- invalid byte sequences, represented safely without corrupting later input.

Cursor movement, selection, copying, and resize reflow must use terminal cell width,
not Swift string character count.

## Resize and reflow

- Resizing the terminal updates PTY rows and columns and causes the child process to
  receive the normal window-size change notification.
- Resize updates are coalesced to avoid flooding the PTY while the user drags the
  window divider.
- Soft-wrapped scrollback lines reflow where the terminal engine supports correct
  reflow.
- Copying a soft-wrapped line must not insert a newline solely because it wrapped on
  screen.
- Hard line breaks remain hard line breaks.
- If a resize makes an existing selection impossible to preserve exactly, XMterm
  clears it visibly rather than copying the wrong range.

## Selection details

In addition to ordinary linear selection:

- double-click word boundaries must be configurable enough to handle paths,
  filenames, URLs, and programming identifiers;
- triple-click selects a logical line, with a preference for visual-line behavior
  if users need it;
- holding `Option` while mouse reporting is active forces local selection;
- rectangular/block selection is supported with a documented modifier or explicitly
  marked deferred until the terminal engine can implement it correctly;
- selected terminal text can be dragged to another macOS text destination as plain
  text without changing remote input.

## Titles and working directory hints

XMterm recognizes safe title and path hints when supported:

- OSC 0/2 may update the dynamic terminal title;
- a user-renamed tab keeps its custom name while retaining the dynamic title as
  secondary information;
- OSC 7 may update the reported current working directory for display and actions;
- untrusted title text is sanitized and length-limited;
- XMterm must not depend on OSC 7 being present.

## Hyperlinks and URLs

- OSC 8 hyperlinks are rendered as links when valid and safe.
- Plain-text URLs may be detected locally.
- `Command-click` opens a valid URL using the macOS default handler.
- Hovering shows the destination before opening.
- Non-HTTP schemes require an allowlist or confirmation.
- A remote terminal cannot trigger URL opening without an explicit user action.

## Clipboard control sequences

OSC 52 can request clipboard reads or writes. Because remote clipboard access can
leak secrets or replace clipboard contents:

- clipboard reads requested by the remote are denied by default;
- clipboard writes are denied or require explicit user permission according to a
  clear preference;
- payload size is bounded;
- denied requests do not crash or print raw escape data;
- the setting is per-app or per-profile and never silently enabled by a host.

## Bell and attention

The terminal bell is configurable:

- off;
- visual bell;
- system sound;
- tab attention indicator when the tab is not active;
- optional notification only when XMterm is not frontmost.

Repeated bells are rate-limited. Bell state is not communicated by color alone.

## Disconnect and process exit

When SSH exits:

- the terminal keeps its scrollback and selection;
- the tab shows disconnected, exited, or failed state plus exit code/signal when
  available;
- input is disabled until reconnect;
- Reconnect starts a fresh SSH process using the same profile;
- reconnect does not claim to restore the previous remote shell or foreground job;
- the old scrollback remains available until the user clears or closes the tab.

## Local clear and remote clear are distinct

- `Control-L` is sent to the remote program.
- `Command-K` clears local scrollback/visible history according to the documented
  menu action and sends no remote bytes.
- Reset Terminal resets emulator state and is a separate explicit action.
- Hard reset must never be bound to a shortcut that can be triggered accidentally.

## Minimum compatibility verification

Test at minimum:

- bash and zsh line editing;
- `vim`, `nano`, `less`, `man`, `top`, `htop`, and `watch`;
- Python and another interactive REPL;
- nested SSH;
- alternate-screen enter/exit and resize;
- 16, 256, and true-color test output;
- Chinese, combining accents, wide characters, and emoji;
- soft-wrapped versus hard-wrapped copy;
- OSC title, OSC 8 link, bell, and denied OSC 52 behavior;
- disconnect with preserved scrollback and reconnect.
