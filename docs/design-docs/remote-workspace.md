# Remote Workspace Foundation

- **Status:** Approved, implemented, and production verified for Phase 4A
- **Owner:** XMterm
- **Date:** 2026-07-16
- **Decision scope:** Session ownership, read-only remote-file domain, provider
  boundary, navigation/cache/state behavior, and native sidebar presentation
- **Broader contract:** [`remote-files-ux.md`](remote-files-ux.md) remains the
  future Finder-like mutation and transfer design

## Goal

Phase 4A turns a launched SSH tab into a session-owned runtime with two isolated
capabilities: the proven terminal and an optional read-only Remote Workspace. It
adds a real provider contract, deterministic in-memory implementation, bounded
lazy navigation state, and native sidebar behavior without starting mutation,
transfer, terminal-directory synchronization, or editor-sync work.

The target is a real Relay Host listing. The stock `/usr/bin/sftp` client exposes
only human-formatted directory listings, whose parsing remains prohibited. ADR
0007 instead accepts a system-OpenSSH subsystem process plus a narrowly bounded,
read-only binary SFTP v3 codec. That production provider is implemented and real
Relay acceptance passed, so Phase 4A is complete.

## Acceptance requirements

Phase 4A is governed by `APP-001` through `APP-004`, `APP-007`, `APP-008`,
`TAB-002`, `TAB-003`, `FILE-SEL-001`, `FILE-NAV-001`, `FILE-LIST-001`,
`FILE-PERF-001`, `FILE-META-001`, `FILE-XFER-004`, `SESS-002` through
`SESS-007`, `SESS-010`, `A11Y-001` through `A11Y-003`, `MAC-001`, `MAC-002`,
and `MAC-006`.

The focused additions are:

- `SESS-011`: a launched runtime owns sibling terminal and optional workspace
  capabilities with exact per-tab identity and isolated lifecycle;
- `FILE-WORKSPACE-001`: each SSH runtime owns one read-only workspace; local
  runtimes own none;
- `FILE-NAV-002`: successful navigation, history, breadcrumbs, refresh,
  cancellation, and stale-response ordering;
- `FILE-CACHE-001`: bounded per-runtime immediate-child cache with targeted
  invalidation and no recursive traversal;
- `FILE-STATE-001`: honest workspace and per-directory loading, loaded, empty,
  failed, unavailable, and cancelled states;
- `FILE-COPY-001`: exact path, name, parent, and POSIX-shell-quoted text actions
  when lossless text representation exists.

Phase 4A implements only the single-selection portion of `FILE-SEL-001`, only the
read-only portion of `FILE-NAV-001` and `FILE-OPS-001`, and only metadata/listing
subsets that a provider can report honestly. The broader requirements remain
partial rather than being weakened.

## Current architecture assessment

Before Phase 4A, `TerminalWorkspaceStore` is a window-local registry containing
`TerminalTabsState` and a map from tab ID to `TerminalSession`. A
`TerminalSession` owns the retained SwiftTerm view, PTY/OpenSSH process, terminal
tasks, and immutable `SessionLaunchSpecification`. `SessionProfileStore` owns
saved templates; it does not own launched runtime state.

The immutable launch snapshot and distinct profile, tab, terminal-session, and
native-process identities are already correct. The missing seam is an aggregate
that can own terminal and remote-file capabilities without making either one a
child of the other.

## Considered approaches

### 1. Parse `/usr/bin/sftp` batch output

Rejected. macOS OpenSSH 10.2p1 provides human-oriented `ls` output only. It has no
JSON, NUL-delimited, or structured listing mode. Filenames containing newlines or
control bytes can forge records; non-UTF-8 names cannot round-trip through a
line-oriented `String` parser; owner and date columns are presentation-oriented.
This violates exact path identity, untrusted-input handling, deterministic parsing,
and the explicit ban on parsing human `ls` output.

### 2. Add a standalone Swift/libssh2 SSH client

Rejected for this increment. Available libraries can provide SFTP, but adopting
one as the SSH transport would bypass the required system OpenSSH authority for
config aliases, `Include`/`Match`, `ProxyJump`, `ssh-agent`, macOS Keychain, and
known-host prompts. The dependency, transitive graph, licensing, distribution,
host-key validation, and authentication behavior also require a separate ADR and
verification pass.

### 3. Use a reviewed SFTP packet adapter over system OpenSSH

Preferred eventual production direction. A provider would spawn the system SSH
subsystem directly and feed its binary pipes to a mature SFTP adapter:

```text
/usr/bin/ssh -T -s [-i identity] -p port user@host sftp
/usr/bin/ssh -T -s alias sftp
```

This preserves OpenSSH configuration and authentication while avoiding textual
directory parsing. No suitable adapter is currently present, and implementing the
protocol from scratch is forbidden. Phase 4A therefore lands the boundary and
mock-backed behavior but does not fabricate this provider.

## Session-centric ownership

```text
XMtermApp
├── SessionProfileStore                         saved templates only
└── RootView
    └── TerminalWorkspaceStore                  window tab/runtime registry
        └── [TerminalTab.ID: RuntimeSession]
            ├── id: TerminalSessionID            launched runtime identity
            ├── launchSpecification              immutable profile snapshot
            ├── terminal: TerminalSession        retained PTY/view capability
            └── remoteWorkspace: RemoteWorkspace?
                ├── provider                     one per SSH runtime
                ├── navigation/history/selection
                ├── bounded directory cache
                └── owned cancellable tasks
```

`RuntimeSession` lives in `XMtermApp`, the composition layer that can depend on
both `XMtermTerminal` and `XMtermRemote`. The historical `TerminalSessionID` is
retained as the runtime ID for this incremental migration; adding another identity
would provide no Phase 4A correctness benefit. The ADR records that naming choice.

Eligibility is derived from `SessionLaunchTarget.ssh`, not from a saved profile
reference and not from the compatibility-only tab kind. Opening the same saved
profile twice creates two runtime sessions, providers, caches, histories,
selections, and task sets.

Starting a runtime starts its siblings independently. A workspace failure never
changes terminal lifecycle or closes the terminal. Closing the owning tab cancels
and releases that tab's workspace before aggregate cleanup completes; it does not
touch another tab's provider or terminal.

## Module boundary

Phase 4A adds a dependency-free `XMtermRemote` SwiftPM target:

```text
XMtermApp -> XMtermTerminal -> XMtermCore
         -> XMtermRemote   -> XMtermCore
```

`XMtermRemote` contains the path/entry values, provider protocol and deterministic
providers, cache, and observable workspace state machine. It does not import
SwiftUI, SwiftTerm, `XMtermTerminal`, or AppKit. `XMtermApp` owns native views,
pasteboard integration, focused commands, and runtime composition.

## Remote path and entry model

`RemotePathComponent` stores raw bytes. Unix forbids only slash and NUL within a
component; the model must not assume UTF-8, case folding, URL semantics, or local
filesystem normalization. `RemotePath` is an absolute ordered component list with
root represented by an empty list.

The model provides:

- stable raw-byte identity and hashing;
- root, parent, append, and component-aware breadcrumb operations;
- an optional lossless UTF-8 path string;
- safe display text that preserves printable valid Unicode and escapes invalid or
  control bytes without altering identity;
- explicit rejection of NUL, slash-bearing components, non-absolute input, and
  configured length-limit violations;
- POSIX single-quote shell rendering with embedded apostrophes encoded as
  `'\"'\"'`, only when a lossless text path exists.

`RemoteFileEntry` contains stable absolute-path identity, raw name component,
entry kind (`directory`, `regular`, `symbolicLink`, or `other`), optional size,
modification time, permission bits, executable flag, hidden flag, optional raw
symlink target, and metadata completeness. Missing metadata remains `nil` or
partial; it is never guessed.

Deterministic default ordering groups directories, regular files, symbolic links,
and other entries, then compares raw name bytes and full raw paths. Presentation
may use localized display, but identity and tie-breaking never do.

## Provider abstraction

The application layer depends only on a sendable provider protocol:

```swift
public protocol RemoteFileProvider: Sendable {
    func resolveInitialDirectory() async throws -> RemotePath
    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing
    func cancelAll() async
    func close() async
}
```

The listing value contains the canonical directory, immutable entries, metadata
completeness, and optional provider capability notes. Providers map failures into
bounded typed `RemoteFileError` categories: authentication required, permission
denied, path not found, not a directory, disconnected, connection refused,
timeout, cancelled, malformed response, unsupported entry, limit exceeded,
transport unavailable, provider failure, and unknown.

Phase 4A includes:

- `InMemoryRemoteFileProvider` for deterministic unit, state, UI, performance, and
  preview fixtures;
- `UnavailableRemoteFileProvider` for unsupported/fail-closed compositions. It
  returns a clear transport-unavailable error and never claims a listing exists;
- `OpenSSHSFTPRemoteFileProvider` for supported production SSH runtimes under
  Accepted ADR 0007.

`RemoteProviderComposition` binds a provider to its trusted presentation mode.
The raw initializer is private: public clients can create only the unavailable
composition, package code can create a typed simulated composition only from
`InMemoryRemoteFileProvider`, and ordinary package tests use the distinct
`.packageTest` mode. There is no arbitrary production factory. ADR 0007 adds the
production seam only for the concrete reviewed `OpenSSHSFTPRemoteFileProvider`.
Release builds ignore the simulated fixture
environment value and fail closed to unavailable.

Views never launch processes or parse provider output.

## Eventual production process lifecycle

ADR 0007 freezes the intended safe process boundary even though its packet adapter
is blocked:

1. Create one provider per SSH runtime and start it lazily on first workspace use.
2. Spawn `/usr/bin/ssh` directly with discrete arguments and inherited environment;
   never invoke a shell or pass a remote path as a process argument.
3. Keep SFTP stdin/stdout as binary pipes. Authentication prompts require a
   separate controlling terminal or an explicitly documented noninteractive limit;
   prompt text must never enter the binary stream.
4. Publish `available` only after a valid SFTP version handshake.
5. Resolve initial directory through structured `REALPATH \".\"`.
6. List with structured `OPENDIR`, bounded sequential `READDIR`, and `CLOSE`, using
   filename and attribute fields rather than the untrusted human `longname`.
7. On cancellation, stop issuing reads, discard the one outstanding response,
   close its handle, and return cancellation. A request timeout closes the
   connection to unblock it.
8. On runtime close, reject new work, cancel requests, close handles and stdin,
   terminate/reap the provider process with bounded escalation, and leave sibling
   capabilities untouched.

XMterm does not create its own `ControlMaster`; a user's OpenSSH configuration may
reuse a trusted control connection. Until an interactive prompt bridge exists,
the eventual provider may support only key, agent, config, and already-configured
multiplexing authentication, with honest user guidance.

## Workspace state model

`RemoteWorkspace` is a `@MainActor` observable owner. Remote I/O runs through its
provider outside `MainActor`; only immutable results are published on the main
actor. It owns every task it starts and never creates detached work.

Workspace availability is explicit:

- `localSession`: no remote workspace exists;
- `idle`: eligible but not requested;
- `connecting`;
- `loadingInitialDirectory`;
- `available`;
- `failed(RemoteWorkspaceError)`;
- `closing`;
- `closed`.

Every current or expanded directory has one of `notLoaded`, `loading`, `loaded`,
`empty`, `failed`, or `cancelled`. A failed child remains scoped to that child. A
failed navigation target never becomes the current directory. A failed load never
appears as an empty directory.

## Navigation and refresh semantics

The workspace owns current directory, back stack, forward stack, pending target,
selected entry, expanded directories, scroll-restoration token, directory states,
and monotonic request generations.

- Initial load resolves the provider's actual initial directory and lists it before
  publication.
- Opening a child starts one cancellable load. Success pushes the former location
  onto Back, clears Forward, and publishes the new directory atomically.
- Back and Forward preserve reciprocal history and restore selection/scroll tokens
  where possible.
- Parent navigates through the structured parent path and participates in history.
- Breadcrumb ancestors use structured components and the same navigation path.
- Refresh reloads only the current directory, does not add history, retains a
  selected entry only when the same raw path still exists, and keeps the prior
  successful listing visible with an explicit refreshing state until replacement.
- The rendered rows and selectable paths come from one
  `RemoteWorkspaceVisibleEntryProjection`, bounded by the workspace's expansion
  limit. Collapse repairs a selected hidden descendant to the collapsed directory;
  cache eviction repairs to the nearest still-visible ancestor; refresh and
  history restore only the exact raw path and never redirect by display name.
  Selection validation and repair use cached immutable values only and perform no
  provider I/O.
- A newer generation always wins. Completion from a cancelled or superseded
  request is ignored.
- Directory double-click and `Command-Down` open. `Command-Up` goes to the parent.
  Return remains reserved for the canonical future Rename action and is not
  repurposed in read-only Phase 4A.

## Cache and lazy loading

`RemoteDirectoryCache` is a per-runtime, value-oriented LRU. The initial limits are:

- 32 directory listings;
- 20,000 total cached entries;
- 10,000 entries in one provider response;
- 32 MiB cumulative response data;
- 32 KiB absolute raw path;
- 4 KiB component;
- 32 KiB symlink target;
- 64 KiB diagnostic text.

Replacing a cache item is atomic and adjusts both bounds before eviction. The
current directory is pinned during its publication transaction; all other entries
remain evictable. Refresh invalidates/replaces only its target. Closing a runtime
clears its cache.

Only the initial/current directory or a specifically opened/expanded child is
listed. There is no prefetch, recursive walk, descendant size calculation, polling,
or symlink traversal. The workspace permits at most two provider requests at once;
each directory has at most one active request.

## Native sidebar

The window remains a `NavigationSplitView`. Its sidebar contains a compact Saved
Sessions section and the selected runtime's Remote Workspace below it. The width is
resizable between 240 and 420 points and must leave the terminal visibly dominant.

Local sessions show `Remote Workspace is available for SSH sessions` with no fake
tree. SSH sessions show availability/status, Back, Forward, Parent, Refresh,
component-aware breadcrumbs, and a single-selection native list. Directories use
disclosure affordances for lazy expansion; double-click/`Command-Down` navigates.
Files are selectable but have no open/edit action in this phase.

Switching tabs selects a different workspace object immediately. An inactive
workspace may finish a bounded request; generation and ownership checks ensure its
result cannot publish into the active tab. Terminal views keep their existing
stable session identity and are not recreated by listing changes.

Rows and controls expose names, kinds, state, errors, selection, and breadcrumb
destinations to accessibility APIs. Focused commands and context menus share one
availability policy. Loading, empty, unavailable, cancelled, and failed states are
visible and include Retry where appropriate.

## Copy actions

The selected entry and current directory expose:

- Copy Path;
- Copy Name;
- Copy Parent Directory;
- Copy Shell-Quoted Path.

The pasteboard receives plain text only and no synthetic Return. Copy Name is
unavailable for root. Exact-text actions are disabled for raw paths that are not
losslessly representable as Unicode; safe escaped display text is not mislabeled as
the exact path. Phase 4B may add a private remote-entry pasteboard representation;
Phase 4A does not implement remote object Copy/Cut/Paste.

## Performance and concurrency targets

- Model, order, and publish 1,000 deterministic entries in less than 100 ms on the
  verification host, measured separately from provider I/O and SwiftUI rendering.
- Construct a 1,000-entry visible projection and perform 1,000 iterations of exact
  hit/miss entry and selectability lookups in less than 100 ms p90, with fixture
  construction outside the timed segment and one warm-up plus 11 measured runs.
- No remote I/O, parsing, or per-entry task creation on `MainActor`.
- No main-thread stall longer than 100 ms during scripted workspace interaction.
- Cached tab switches publish immediately and do not restart provider work.
- Idle workspaces use near-zero CPU and no polling timer.
- Cancellation becomes observable promptly and stale completion never mutates a
  newer location.

The existing 10,000-entry release gate remains a broader product requirement; the
1,000-entry Phase 4A target does not replace it.

## Security and privacy

Remote filenames and attributes are untrusted. The implementation never evaluates
them, builds a shell command, follows a symlink during listing, disables host-key
checking, logs clipboard contents, or prints provider command streams. User-facing
errors are bounded and redacted. Passwords, OTPs, passphrases, key bytes,
environment dumps, terminal contents, and sensitive paths are never stored or
logged.

## Explicit deferrals

Phase 4A does not implement remote mutation; upload/download; transfer queues;
multi/range selection; Copy/Cut/Paste of remote objects; drag-and-drop; rename;
delete; create; duplicate; collision handling; recursive search; preview; Quick
Look; file opening; local editor launch; save watching; auto-upload; conflict
resolution; terminal-directory following; `Open Terminal Here`; connection
sharing; app-owned OpenSSH multiplexing; reconnection; or a settings redesign.

## Acceptance boundary

The foundation can be accepted when its domain, providers, state machine, bounded
cache, runtime ownership, sidebar, commands, cancellation, accessibility, and
performance behavior pass automated and packaged-app checks.

Phase 4A itself cannot be marked complete until a reviewed production provider:

1. lists the real Relay Host through structured SFTP data;
2. preserves system OpenSSH config, agent, Keychain, and known-host behavior;
3. passes disposable transport fixtures plus real manual acceptance;
4. meets the bounds and cancellation lifecycle in ADR 0007; and
5. has documented licensing, packaging, signing, and distribution evidence.

## Unresolved questions

1. Which reviewed SFTP packet adapter can operate over system OpenSSH binary pipes
   without becoming a second SSH implementation?
2. Does Phase 4A require a narrow controlling-terminal prompt bridge, or may its
   first production provider support only noninteractive key/agent/configured
   multiplexing authentication with explicit guidance?
3. How will the chosen adapter and prompt bridge be packaged, licensed, signed,
   sandboxed, and notarized under ADR 0004?
