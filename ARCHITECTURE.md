# XMterm Architecture

## System shape

XMterm is a native macOS application with four independently recoverable capability areas:

```text
App shell
├── Session management
├── Terminal tabs
├── Remote file browser
└── Local editor sync
```

No XMterm component runs persistently on the remote host.

## Layers

### Presentation

SwiftUI/AppKit views and window commands. Presentation owns visual state but does not execute SSH commands directly.

### Application

Use cases and coordinators:

- `ConnectSession`
- `OpenTerminalTab`
- `CloseTerminalTab`
- `ListRemoteDirectory`
- `OpenRemoteFileLocally`
- `SyncEditedFile`

### Domain

Pure models and rules:

- `SessionProfile`
- `TerminalTab`
- `RemotePath`
- `RemoteFileEntry`
- `OpenRemoteDocument`
- `TransferState`
- conflict detection metadata

### Infrastructure

Replaceable implementations:

- PTY-backed system OpenSSH process client and OpenSSH configuration resolver
- SFTP file service and optional authenticated-transport/multiplexing coordinator
- local cache store and revision-safe transfer staging service
- filesystem event watcher
- local editor launcher
- pasteboard and remote-file drag/drop adapters
- terminal selection/search/scrollback adapter
- Keychain-backed non-secret preferences where appropriate

## Dependency direction

```text
Presentation -> Application -> Domain
                         ^
                         |
                  Infrastructure
```

Infrastructure implements protocols declared toward the application/domain side. Domain code must not import SwiftUI, AppKit, or process APIs.

## Important boundaries

### Session-management boundary

Phase 3 keeps saved launch templates separate from running terminal state:

```text
SessionPickerView / SessionManagerView / SessionProfileEditorView
  -> SessionProfileStore (MainActor, immutable collection replacement)
    -> SessionProfileRepository protocol
      -> JSONSessionProfileRepository actor
         ~/Library/Application Support/XMterm/sessions.json

validated SessionProfile
  -> immutable SessionLaunchSpecification
    -> TerminalTab + TerminalSession + PTY process
```

`SessionProfile` contains stable identity, non-secret presentation/ordering
metadata, and one tagged local or SSH launch payload. Local payloads describe the
login shell or an explicit executable and optional working directory. SSH payloads
are either a structured direct host/user/port plus optional identity-file path, or
one manually entered OpenSSH alias. Automatic alias discovery/import and `ssh -G`
presentation are deferred; system `/usr/bin/ssh` still owns effective OpenSSH
configuration and authentication semantics.

The repository serializes a version-1 JSON envelope, caps document/profile size,
uses a user-only same-directory staging file and atomic move/replacement, and
preserves corrupt or unsupported input as a recovery sibling. First-launch
defaults are written only when the store has never been initialized. A valid empty
collection is durable initialized state and is never silently reseeded.

The store validates cheap structural rules while editing, performs filesystem
existence/executable checks only at save or launch boundaries, and publishes a
proposed immutable collection only after persistence succeeds. Loading,
persistence failure, empty content, and recovery-required states remain explicit.
The UI does not read or write the JSON file directly.

Launching validates the saved profile, copies only launch-relevant fields into a
`SessionLaunchSpecification`, creates distinct tab/session identities, then records
recency. The tab and runtime retain that snapshot and source-profile ID. Later
profile edit, rename, favorite, or deletion cannot mutate, rename, or close an
already-launched tab; a tab rename likewise cannot modify the saved template.

### Terminal boundary

A terminal tab owns one PTY-backed process and explicit states. Phases 1 through 3
use one shared runtime path:

```text
TerminalWorkspaceStore (MainActor, immutable tab-state replacement)
  -> TerminalSession (stable tab identity and lifecycle coordination)
    -> XMtermTerminalView (retained AppKit/SwiftTerm adapter)
    -> TerminalProcess protocol (deterministic test seam)
      -> PTYProcessController actor (bounded nonblocking descriptor/process owner)
      -> CXMtermPTY forkpty/execve shim
```

UI code never owns a file descriptor. Each output task captures one immutable tab
ID and one stable session, so late output cannot be delivered to a replacement tab.
The terminal view is retained while hidden; switching tabs therefore preserves its
screen, selection, scroll position, and process.

The implemented lifecycle is:

```text
idle -> starting -> running -> closing -> exited(exit code or signal)
                           \-> failed(launch/read/write/resize/lifecycle)
```

The Phase 3 production path derives local or SSH process configuration from an
immutable `SessionLaunchSpecification`. Direct SSH profiles execute `/usr/bin/ssh`
with an ordered argument array; alias profiles execute `/usr/bin/ssh` with exactly
the alias argument. The built-in relay therefore remains exactly `-p`, `54426`,
and `allen921103@140.109.226.155`, with no shell command-string parsing. Local and
SSH targets use the same `TerminalSession`, process controller, terminal view,
input/resize queues, output-security filter, scrollback, and close/reap
implementation. `TerminalTabKind` remains a coarse presentation/lifecycle
classification and a Phase 1/2 compatibility seam, not the persisted launch source
of truth. The process protocol remains a narrow deterministic-test seam;
production ownership stays in `PTYProcessController`.

For SSH, `running` means only that the local `/usr/bin/ssh` process is running. It
does not claim that DNS resolution, TCP connection, host-key verification,
authentication, an interactive shell, or a manually typed second hop succeeded.
OpenSSH prompts and diagnostics remain raw terminal I/O and are never inferred by
parsing prompt text.

Closing a tab terminates only that tab's process. Before a local close,
`TerminalSession` asks `PTYProcessController` for the PTY foreground process group.
The controller compares `tcgetpgrp(masterFD)` with the shell process group recorded
at `forkpty` launch: equality closes immediately, while a different group produces
a foreground-job confirmation. Already-closed/reaped PTYs close immediately. An
unexpected query failure on an otherwise-live PTY uses an honestly worded
conservative confirmation. The workspace awaits this decision by stable tab and
session identity, so stale results cannot target another tab. It applies the same
classification when forming one window/quit aggregate prompt. A live SSH tab never
uses that local foreground classification: it always produces the documented SSH
confirmation because remote foreground work is unknowable from the local PTY.
Exited and failed SSH tabs close immediately. Window/quit aggregation counts live
SSH sessions separately from local foreground and unknown states.

Other tabs continue independently. Exited tabs retain scrollback and exit
information. A future reconnect action must start a fresh process from the retained
snapshot; reconnect, SFTP, and more precise remote-idle detection remain
unimplemented after Phase 3.
Terminal capabilities, Unicode width, titles, links, bell, and remote clipboard
control are owned by the terminal-engine boundary rather than ad hoc SwiftUI views.

PTY reads and writes are readiness-driven and bounded. `TIOCSWINSZ` updates are
latest-value coalesced. Completion requires the direct child to be reaped and the
PTY's final output to drain; Darwin `EIO` is treated as terminal EOF. Close sends
process-group `SIGHUP`, then bounded `SIGTERM`/`SIGKILL` escalation if necessary.
The direct child is not reaped until escalation signals finish, which pins the
shell PID/process-group identity against numeric reuse. `TIOCSIG` delivers TERM and
final KILL to the PTY's current foreground group without a `tcgetpgrp`/`killpg`
race; every distinct non-shell foreground group observed during escalation is
retained for post-signal verification but is never signaled later by a cached
number. Cleanup errors are surfaced only after descriptor closure and direct-child
reaping. Draining close treats `EAGAIN` as transient and gives the PTY a bounded
final-drain window before forced descriptor closure. If the direct child remains
live beyond the post-`SIGKILL` reap deadline, close reports that typed state while
the existing process-exit dispatch source retains managed ownership until an
event-driven reap; no residual polling loop is created.

Untrusted PTY output crosses `TerminalOutputSecurityFilter` before SwiftTerm. Phase
1 forwards bounded display CSI and ordinary UTF-8 but drops OSC, DCS, APC, PM, SOS,
window/title-stack operations, terminal graphics, and engine commands known to log
terminal-controlled values. This deliberately defers dynamic titles, hyperlinks,
bells, terminal graphics, and OSC clipboard writes rather than exposing host-side
effects.

### Terminal tab-strip presentation boundary

The Phase 2 tab-strip polish adds a presentation-only boundary above the unchanged
terminal/session ownership path:

```text
TerminalWorkspaceHeader (one header-width proposal)
  -> TerminalTabStripLayoutPolicy (pure sizing metrics)
    -> TerminalTabStrip (exact non-greedy strip width)
      -> stable-ID LazyHStack inside one horizontal viewport
      -> non-scrolling `+` session-picker sibling
  -> at least 8 pt of separation before remaining toolbar space
```

The pure policy keeps preferred-width tabs at 180 points, shrinks every tab equally
to the 120-point minimum, and then holds that minimum while the viewport scrolls.
The 240-point maximum remains an explicit policy bound, although the current
non-overflow presentation does not expand beyond the 180-point preferred width.
When tabs fit, the viewport equals the actual tab-content width instead of consuming
the rest of the header. The `+` control is never part of the lazy sequence or
scroll content, so it stays pinned directly after the viewport and before the
independent toolbar region. In Phase 3 it opens a searchable profile picker and
starts no process by itself.

Reveal request identity contains the ordered stable tab IDs, selected ID, and
viewport width. Creation, activation, replacement selection after close, and resize
therefore request a trailing reveal of the current selected ID. A pure scheduling
policy gives initial and tab/selection requests one 16 ms render settle; initial
reveal is unanimated, while a tab/selection change may use the short scoped
animation. Viewport-only requests use a 75 ms cancellation-coalesced debounce and
remain unanimated. After the delay, generation and cancellation guards admit
exactly one final `scrollTo`; Reduce Motion removes the optional tab/selection
animation without changing the target or final layout.

This boundary does not own `TerminalTabsState`, a `TerminalSession`, PTY/process
state, SSH behavior, profile persistence, or the retained terminal view. Stable tab
IDs remain the only identity used by the lazy sequence, and terminal-surface
identity in `RootView` remains the selected session ID.

### Session-centric runtime and remote workspace boundary

Phase 4A replaces the window store's direct tab-to-terminal registry with a
session-centric aggregate and adds a dependency-free `XMtermRemote` target:

```text
RootView
└── TerminalWorkspaceStore                window tab/runtime registry
    └── [TerminalTab.ID: RuntimeSession]
        ├── id: TerminalSessionID          launched runtime identity
        ├── launchSpecification            immutable profile snapshot
        ├── terminal: TerminalSession      retained PTY/view capability (unchanged)
        └── remoteWorkspace: RemoteWorkspace?
            ├── RemoteFileProvider         one per SSH runtime
            ├── navigation/history/selection state machine
            ├── bounded LRU directory cache
            └── owned cancellable tasks

XMtermApp -> XMtermTerminal -> XMtermCore
         -> XMtermRemote   -> XMtermCore
```

Workspace eligibility comes from the immutable `.ssh` launch target. Two tabs
launched from one saved profile own independent providers, caches, histories,
selections, and tasks. Terminal and workspace start independently; a workspace
failure never changes terminal lifecycle. Closing a runtime cancels its workspace,
requests terminal close, and publishes aggregate cleanup only after both settle
(ADR 0006).

`XMtermRemote` owns raw-byte `RemotePath`/`RemoteFileEntry` identity, safe escaped
display, bounded `RemoteDirectoryListing` values, typed `RemoteFileError`
categories, the sendable `RemoteFileProvider` protocol, the deterministic
`InMemoryRemoteFileProvider`, the honest `UnavailableRemoteFileProvider`, the
bounded per-runtime LRU `RemoteDirectoryCache`, and the `@MainActor` observable
`RemoteWorkspace` state machine. Navigation publishes a directory as current only
after its listing succeeds; newer request generations always win; refresh changes
no history; expansion is lazy and immediate-child-only.

Provider identity and presentation trust are composed together in
`RemoteProviderComposition`. Its raw provider/mode pairing is private, public
clients can construct only the fail-closed unavailable composition, and package
code has distinct typed seams for the in-memory developer fixture and ordinary
test providers. The only production constructor accepts the concrete
`OpenSSHSFTPRemoteFileProvider`; there is no arbitrary “production provider”
factory. The workspace stores the provider privately and publishes only the
trusted mode. A package-test provider therefore cannot acquire production or
simulated presentation semantics.

`XMtermApp` owns the native presentation: `RemoteWorkspaceSidebar` below compact
Saved Sessions in the `NavigationSplitView` sidebar (240–420 points), pure
presentation/action policies, exact-owner focused commands and the Remote menu,
context-menu copy actions, and the single plain-text-item pasteboard adapter.
Workspace publication never recreates or refocuses the retained terminal view,
which stays keyed by terminal-session identity. Supported SSH runtimes compose a
production `OpenSSHSFTPRemoteFileProvider` from the immutable launch snapshot.
That actor owns an independent `/usr/bin/ssh -T -o BatchMode=yes -s ... sftp`
process, a bounded read-only SFTP v3 codec, and serialized requests. The terminal
continues through its sibling PTY `/usr/bin/ssh` process. An explicit
`XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` value opts only a developer build into
the labeled deterministic graph; release builds ignore it and retain production.

The listing and selection paths share
`RemoteWorkspaceVisibleEntryProjection`: one bounded projection produces the rows,
exact raw-byte selectable paths, and path-to-entry lookup. Its maximum depth is
derived from the workspace expansion limit. Collapse repairs a hidden descendant
selection to the collapsed directory; cache eviction repairs to the nearest still
visible ancestor; refresh/history restoration accepts only the exact surviving
raw path. These repairs perform no provider I/O.

### Remote file boundary

All remote operations go through the Phase 4A `RemoteFileProvider` boundary (the
earlier `RemoteFileService` naming refers to the same seam's future mutation and
transfer surface). UI code receives structured values, never parses human-formatted command output.

The accepted Phase 4A implementation uses system OpenSSH as the secure transport
and implements only binary SFTP v3 `INIT`, `REALPATH`, `OPENDIR`, `READDIR`, and
`CLOSE` framing behind the provider boundary. It never invokes the human `sftp`
client or parses `ls`, prompts, terminal output, or `longname`. Effective SSH
options remain delegated to system OpenSSH; UI alias discovery is never the source
of truth for connection semantics.

Transfers use explicit revision/state models and safe staging/finalization. Remote
path identity, symlink metadata, and permission mode are structured values, not
shell-escaped display strings.

### Editor-sync boundary

`OpenRemoteDocument` stores:

- session identifier;
- exact remote path;
- local cache URL;
- remote modification metadata at download time;
- last uploaded local content fingerprint;
- current transfer state.

Watch the containing cache directory rather than assuming editors mutate a file in place. Debounce events and ignore temporary/editor metadata files.

Before upload, compare available remote metadata. If the remote file changed after download, enter `Conflict` rather than silently overwriting it.

## Interaction state boundaries

Selection, focus, clipboard, drag/drop, and async operation state are domain-visible
concepts where they affect correctness. Do not bury multi-selection or batch
semantics entirely inside a view. Remote file actions receive an ordered set of
stable remote-path identities. Terminal text selection remains owned by the
terminal emulator but exposes copy/search commands through application abstractions.

The focused region routes common commands such as Copy and Paste. Terminal text and
remote file references use distinct pasteboard representations so one cannot be
misinterpreted as the other.

## Performance invariants

- No recursive remote enumeration by default.
- No work on the main thread that can block on network or process I/O.
- Terminal rendering updates are bounded and incremental.
- File events are debounced.
- Large-file thresholds must be explicit and configurable.
- Advertised terminal features must have compatibility tests and bounded scrollback.
- Transfer concurrency and retry are bounded; older retries cannot supersede newer
  revisions.
- Connections and tasks are cancellable when their owning view/session closes.

## Security invariants

- Prefer SSH aliases from `~/.ssh/config`.
- Delegate host-key checking and key handling to trusted SSH infrastructure.
- Persist only schema-defined non-secret profile fields; never accept or encode
  passwords, OTPs, passphrases, or private-key contents.
- Keep the profile directory user-only (`0700`) and the JSON/staging/recovery files
  user-only (`0600`); persist before publishing saved-profile state.
- Never log passwords, OTPs, private-key material, or full command environment data.
- Local cache permissions must be user-only.
- Remote deletes and overwrites must display the target path.
- OSC 52 clipboard access is denied or permission-gated and size-bounded.
- Process launches use argument arrays; remote paths are never interpolated into a
  local shell command.
- Editor-sync cache and temporary files use user-only permissions and are never
  executed automatically.
