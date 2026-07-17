# Task 4 documentation guardrails

Use these requirement/evidence boundaries in addition to the task brief:

- `TAB-002` remains Partial. Implemented/preserved: click activation, horizontal
  overflow, stable identity, and selected-tab reveal after create/activation/close/
  resize. Deferred: `Command-1`…`Command-9`, `Command-Shift-[` /
  `Command-Shift-]`, drag reorder, and reveal-after-reorder.
- `TAB-001` remains Partial because remembered-session selection/double-click are
  absent. `TAB-003` remains Partial because middle-click is absent. `TAB-005`,
  `APP-003`, `A11Y-001`–`003`, and `MAC-001` must retain their broader partial
  qualifiers.
- Add the pure layout boundary to ARCHITECTURE: header-width owner → sizing policy
  → stable-ID lazy viewport, with `+` as a non-scrolling sibling and PTY/session
  ownership unchanged.
- Update INTERACTIONS implementation status only; do not rewrite normative clauses.
- Keep Phase 3 Session Manager next in PLANS; this polish does not start it.
- TESTING must distinguish pure policy/reveal tests from rendered SwiftUI/manual
  evidence. Current verified automated total is 139 tests in 23 suites; recheck
  before finalizing exact counts.
- Add the approved design to docs/design-docs/index.md. Update session-tabs and
  macOS behavior with exact 180→120→scroll, content-sized non-overflow, pinned `+`,
  selected reveal, and Reduce Motion behavior, while retaining deferred features.
- In interaction-parity, do not reuse the existing terminal-surface trackpad row as
  tab-overflow evidence. Add granular policy-tested vs rendered/manual rows.
- Create Audit 0004 with host/toolchain, implementation boundary, exact automated
  results, requirement table, performed staged observations, explicit manual gaps,
  performance/security observations, and deferred work. Do not claim CPU, memory,
  latency, long-title rendering, VoiceOver, Reduce Motion, trackpad, or visual
  behavior until actually observed.
- At the start of this documentation task, post-integration manual launch/visual
  verification is pending. Draft those rows honestly as pending; the controller will
  append observations after the staged run.
- No changes are required to ENGINEERING_CONTRACT.md, AGENTS.md, SECURITY.md, or
  PERFORMANCE.md unless a new measurement or security behavior is introduced.
