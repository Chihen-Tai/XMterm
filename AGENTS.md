# AGENTS.md

This file is the stable entry point for coding agents. Keep it short. Follow links
instead of expanding this file into a complete manual.

## Required reading

Before changing code, read:

1. `PRODUCT.md`
2. `ARCHITECTURE.md`
3. `INTERACTIONS.md`
4. `PERFORMANCE.md` and `TESTING.md` when behavior, dependencies, or infrastructure change
5. `PLANS.md`
6. the relevant design document under `docs/design-docs/`
7. `docs/audits/0001-second-pass-gap-audit.md` when touching terminal, SSH,
   transfers, editor sync, or native app behavior
8. `docs/checklists/interaction-parity.md` for UI work
9. `docs/checklists/terminal-acceptance.md` for terminal work
10. any applicable ADR under `docs/decisions/`

For work lasting more than one focused change, create or update an execution plan
under `docs/exec-plans/`.

## Product invariants

- XMterm is terminal-first. The terminal remains the dominant area of the main
  window.
- Remote files are a lightweight companion to the active SSH session, not a full
  IDE workspace.
- “Lightweight” means no remote daemon, recursive indexer, or Electron runtime. It
  does **not** mean removing routine selection, clipboard, keyboard, drag-and-drop,
  accessibility, progress, or cancellation behavior.
- Never install or require a server-side XMterm daemon, VS Code Server, language
  server, or recursive indexer.
- Remote directory loading must be lazy and cancellable.
- Opening a file means download to local cache, open with a local editor, watch
  saves, then upload to the same remote path.
- Authentication must reuse OpenSSH configuration, keys, `ssh-agent`, and macOS
  Keychain where available. Never store private keys or OTP secrets in the
  repository or app preferences.
- Terminal, file transfer, and editor-sync failures must remain isolated from one
  another.

## Interaction rules

- Every collection must define single selection, multi-selection, range selection,
  keyboard selection, focus restoration, and batch action behavior when applicable.
- Every movable/copyable item surface must define copy, cut, paste, context menu,
  and drag-and-drop behavior or document why an action is unavailable.
- Terminal implementation must include local drag selection, copy/paste, scrollback,
  find, a modifier for local selection while remote mouse reporting is active,
  correct wrapped-line/Unicode behavior, resize, disconnect state, and the advertised
  xterm compatibility surface.
- A UI feature is incomplete until applicable pointer, keyboard, context-menu,
  progress, cancellation, error, empty, loading, disconnected, and accessibility
  states are implemented.
- Cite requirement IDs from `INTERACTIONS.md` in execution plans and tests.

## Architecture rules

- UI code may depend on application/domain abstractions, never directly on shell
  commands.
- All `Process`, PTY, SSH, SFTP, filesystem-watching, pasteboard, drag-and-drop, and
  editor-launch operations belong behind infrastructure protocols where practical.
- Do not add a dependency without an ADR explaining why the standard library or an
  existing dependency is insufficient.
- Do not use Electron, embedded web apps, or a remote runtime.
- Do not recursively enumerate remote directories unless the user explicitly
  requests it.
- Do not naively reimplement OpenSSH config semantics. Use system OpenSSH and
  `ssh -G` where resolved configuration must be inspected.
- Never upload editor content directly over the destination in a way that can expose
  a partial file when safe staging/finalization is available.
- Do not use force unwraps or silently ignore errors in production code.
- UI state mutations run on `MainActor`; long-running I/O must be asynchronous and
  cancellable.

## Change workflow

1. Restate acceptance criteria and interaction requirement IDs in the active plan.
2. Make the smallest coherent change.
3. Add or update tests for domain behavior and critical interactions.
4. Walk through `docs/checklists/interaction-parity.md`.
5. Run `./scripts/verify.sh`.
6. Update documentation when behavior, architecture, or commands changed.
7. Record meaningful design decisions in an ADR.

## Definition of done

A change is done only when:

- acceptance criteria and cited interaction requirements are satisfied;
- tests and repository checks pass;
- ordinary mouse and keyboard behavior is present, not merely the backend action;
- multi-selection and batch behavior are handled where applicable;
- error and cancellation paths are handled;
- user-visible states are represented explicitly;
- affected docs and plans are current;
- no secrets, machine-specific paths, or generated build artifacts are committed.
