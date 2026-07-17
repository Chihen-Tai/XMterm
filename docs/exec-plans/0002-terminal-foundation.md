# Execution Plan 0002: Terminal Foundation Spike

- **Status:** Superseded; local-terminal subset completed by Execution Plan 0003
- **Depends on:** Execution Plan 0001

## Goal

Select and validate the terminal emulator/PTY approach with enough evidence that
future agents do not build tab/session UI on an incompatible terminal surface.

## Required reading

- `INTERACTIONS.md` terminal and session requirements;
- `docs/design-docs/terminal-keyboard.md`;
- `docs/design-docs/terminal-compatibility.md`;
- `docs/design-docs/ssh-connection-lifecycle.md`;
- `docs/checklists/terminal-acceptance.md`;
- `PERFORMANCE.md`;
- ADR 0003 and ADR 0004.

## Acceptance criteria

- [x] Spawn a local interactive shell inside a real PTY.
- [ ] Spawn `/usr/bin/ssh` using an argument array and one fixture alias.
- [x] Render output incrementally with bounded scrollback.
- [ ] **Partial:** ASCII, committed/pasted Traditional Chinese, Control keys, special
  keys, and repeat routing are covered; live IME preedit timing remains unverified.
- [x] Resize rows/columns correctly.
- [ ] **Partial:** drag/double/triple selection and `Command-C` work; Shift-click is
  supported by the engine but was not manually verified.
- [x] `Command-V` and bracketed paste work; `Control-V` reaches the PTY.
- [ ] **Partial:** `vim` and `less` were exercised; `htop`, reported mouse input,
  and Option-drag remain unverified.
- [ ] **Partial:** soft-wrap copying has an adapter test; Unicode and alternate
  screen have evidence; titles, links, bells, and graphics are intentionally denied.
- [ ] **Partial:** local exit preserves scrollback; reconnect is SSH-phase work.
- [ ] One terminal remains responsive during a simulated transfer workload.
- [ ] **Partial:** memory, idle CPU, and the 100,000-line output fixture were observed;
  release startup, latency, and ten-minute measurements remain outstanding.
- [x] ADR 0003 records the selected engine or explains why no candidate passed.
- [ ] ADR 0004 records whether the same prototype works in the intended signed/
  sandboxed distribution configuration.

## Non-goals

- SFTP implementation;
- editor auto-sync;
- production session browser;
- tmux;
- split panes;
- polished themes.

## Evidence

Store test notes and measurements under `docs/audits/`. Include exact dependency
versions and licensing findings.

The local-terminal evidence is in
[`../audits/0002-phase-1-local-terminal-evidence.md`](../audits/0002-phase-1-local-terminal-evidence.md).
The unchecked SSH, reconnect, transfer, full compatibility, and distribution items
remain candidates for the next execution plan; they are not part of Phase 1.
