# ADR 0006: Own Terminal and Remote Workspace as Sibling Runtime Capabilities

- **Status:** Accepted for Phase 4A
- **Date:** 2026-07-16

## Context

Before Phase 4A, `TerminalWorkspaceStore` maps each tab directly to one
`TerminalSession`. That terminal object correctly owns the retained terminal view,
PTY/OpenSSH process, terminal tasks, and immutable launch snapshot. A read-only
remote browser adds independent state, tasks, cache, provider lifecycle, and
failure modes. Making it a child of the terminal would couple listing changes and
transport failures to terminal rendering and lifecycle. Making it profile-owned
would merge two tabs launched from the same saved profile.

The older `SESS-006` wording and SSH lifecycle design described a logical file
browser that could outlive closing one terminal. The locked Phase 4A scope instead
requires workspace state to belong to the exact launched tab/session and to be
cancelled when that runtime closes.

## Options considered

1. Store remote workspace state inside `TerminalSession`.
2. Store one workspace per saved profile.
3. Add a window-owned runtime aggregate with sibling capabilities.

## Decision

Add `RuntimeSession` in `XMtermApp`. `TerminalWorkspaceStore` maps each terminal-tab
ID to one runtime aggregate. The runtime owns:

- the existing immutable `SessionLaunchSpecification`;
- the existing `TerminalSession` terminal capability;
- an optional `RemoteWorkspace`, created only for an SSH launch target.

The historical `TerminalSessionID` remains the aggregate runtime ID for this
increment. Saved-profile ID, tab ID, runtime/terminal-session ID, and native process
identity remain distinct.

Each launch creates a fresh runtime. Two launches from one profile never share
workspace navigation, selection, history, cache, tasks, or provider objects.
Profile edits and deletion cannot mutate either runtime.

Terminal and workspace start independently and expose independent state. A remote
workspace failure must not change the tab's terminal lifecycle, stop the terminal,
or prevent a prepared terminal from being published. The UI observes workspace
state in the sidebar without replacing the retained terminal view.

Closing a tab closes only its owning runtime: it cancels/releases that workspace
and requests terminal close. Aggregate cleanup completes after both capabilities
have settled. It never closes a different tab's provider or terminal. This Phase
4A ownership rule supersedes only the older shared-file-browser lifetime sentence
in `SESS-006`; independent failure and authentication coordination still apply.

Do not use the terminal's OSC-reported current directory to initialize or move the
workspace. Terminal-directory synchronization remains a later phase.

## Consequences

- Runtime state is keyed by launched identity, never by mutable profile values.
- Local sessions have no remote provider, cache, or background remote tasks.
- Remote listing publication cannot recreate the retained terminal view.
- `TerminalWorkspaceStore` remains the window tab/runtime registry, not the owner
  of provider, cache, or navigation internals.
- Existing tests may temporarily use a computed terminal-session projection while
  migration tests assert aggregate ownership directly.
- Closing and application shutdown must await aggregate cleanup rather than treating
  terminal-process completion as the only owned work.
- A later transfer/editor capability can become another sibling without changing
  the terminal module.
