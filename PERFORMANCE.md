# XMterm Performance Budget

The word “lightweight” must be measurable. These are provisional v0.1 budgets for a
release build on a supported Apple-silicon Mac. Record hardware, macOS version,
build configuration, terminal engine, and test fixture with every measurement.

## Local resource targets

| Scenario | Provisional target |
|---|---:|
| Cold launch to interactive empty window | ≤ 2.0 s |
| Idle app, no connection | ≤ 120 MB resident memory |
| One connected idle terminal | ≤ 160 MB resident memory |
| Five connected idle terminals | ≤ 240 MB resident memory |
| Idle CPU with stable connections | < 1% average after settling |
| Terminal input-to-render latency | ≤ 50 ms p95 under normal load |
| UI responsiveness during transfer | no main-thread stall > 100 ms caused by transfer I/O |

These are budgets, not marketing guarantees. If a dependency makes a target
unrealistic, document measurements and revisit the dependency decision rather than
quietly deleting the target.

## Terminal behavior budgets

- Scrollback is bounded and configurable; the default must not grow without limit.
- Rendering is incremental and does not rebuild the full scrollback on each chunk.
- A sustained output test must not cause unbounded memory growth.
- Resize events are coalesced while dragging.
- Search may index locally, but it must remain bounded by the configured scrollback.
- Hidden/inactive tabs must not redraw unnecessarily.

Suggested baseline fixture:

```bash
python3 - <<'PY'
for i in range(1_000_000):
    print(f"{i:07d} The quick brown fox 測試 emoji 🚀")
PY
```

Measure throughput, UI input latency, memory peak, time to interrupt with
`Control-C`, and time to search recent history.

## Remote resource invariants

- XMterm installs no remote daemon, server, indexer, extension host, or watcher.
- Remote processes are limited to ordinary SSH/SFTP commands and commands explicitly
  launched by the user.
- Directory browsing lists only the current directory.
- No recursive size calculation or project indexing occurs implicitly.
- Opening one remote file transfers that file only.

## File browser and transfer budgets

- A directory listing renders progressively when practical rather than waiting for
  every row before showing anything.
- Sorting already-loaded metadata is local and causes no network request.
- Transfer concurrency is bounded and configurable.
- A stalled transfer cannot block terminal input or another tab.
- File watcher events are debounced and coalesced by logical revision.

## Measurement gates

Before a release candidate:

1. capture startup time and memory with zero, one, and five tabs;
2. run sustained terminal output for at least ten minutes;
3. transfer a large file while typing and selecting terminal text;
4. list a remote directory with at least 10,000 entries;
5. open and auto-sync several files rapidly;
6. compare against the previous release/build and explain meaningful regressions.

Performance evidence belongs in the release execution plan or a benchmark report
under `docs/audits/`.

## Phase 1 local-terminal evidence

The development build was measured on an Apple M4 running macOS 26.5.2 with
SwiftTerm 1.14.0 and 10,000 lines of configured scrollback. One idle terminal used
approximately 122.2 MiB resident memory and sampled at 0% CPU after settling. After
the required `yes "XMterm output test" | head -n 100000` fixture and a second
terminal, the app used approximately 161.5 MiB; three subsequent CPU samples were
0.2%, 0%, and 0%. The prompt returned within a five-second observation window, the
window remained interactive, and historical scrolling did not jump to the bottom
when delayed output arrived.

These are debug-development observations, not release benchmarks. Input latency,
cold launch, five-tab memory, a ten-minute sustained run, and Instruments main-
thread stalls remain unmeasured. The release gates above remain unchanged. Exact
commands and limitations are recorded in
[`docs/audits/0002-phase-1-local-terminal-evidence.md`](docs/audits/0002-phase-1-local-terminal-evidence.md).

## Phase 2 fixed-relay implementation

SSH tabs add no renderer, scrollback copy, polling loop, network monitor, or
per-character SwiftUI state. They reuse the retained SwiftTerm view and the same
readiness-driven `PTYProcessController`, bounded 64-KiB output staging, bounded
input queue, resize coalescing, and event-driven child completion as local tabs.
Only tab kind, lifecycle, alert, and presentation changes are observable on the
main actor; network latency remains inside `/usr/bin/ssh` and the PTY stream.

Automated tests use a suspended actor fake rather than timers or a real host and
verify that input and resize traverse the shared process boundary. No Phase 2
relay CPU, memory, cold-launch, five-tab, or input-latency measurement is claimed;
the release budgets and manual idle-SSH measurement remain open in
[`docs/checklists/ssh-terminal-acceptance.md`](docs/checklists/ssh-terminal-acceptance.md).

## Phase 3 Session Manager evidence

The Session Manager adds no polling, network discovery, recursive enumeration, or
per-keystroke filesystem work. Draft editing performs only cheap structural
validation synchronously. Executable, readable-file, and directory existence
checks run asynchronously at save or launch boundaries, and repository I/O is
serialized away from `MainActor`. Profile publication remains persist-before-
publish, so a failed disk write does not trigger a SwiftUI collection update.

Picker projection is local and bounded by the saved-profile count. Search is a
linear scan; grouped Recent/Favorites/SSH/Local projection also orders profiles,
so the complete projection is **O(n log n)** rather than O(n). Stable profile IDs
prevent profile edits from recreating retained terminal sessions or terminal
views. In the isolated Phase 3 coverage run, the pure 100-profile picker test
completed in **0.004 seconds**. In the isolated packaged 100-profile fixture,
opening the picker plus obtaining a refreshed accessibility tree took **1,186 ms**,
and entering a search plus obtaining the next tree took **490 ms**. Those latter
figures include computer-use and Accessibility inspection overhead; they are not
represented as app-only input latency.

These figures establish a deterministic small-data guardrail, not a rendered-UI
latency guarantee. Cold launch, main-thread stalls under Instruments, resident
memory with 100 profiles, and a larger-profile stress threshold remain unmeasured.
The packaged-app qualitative result and exact fixture are recorded in
[`docs/checklists/session-manager-acceptance.md`](docs/checklists/session-manager-acceptance.md)
and
[`docs/audits/0005-phase-3-session-manager-evidence.md`](docs/audits/0005-phase-3-session-manager-evidence.md).
The Phase 4 SFTP, directory-listing, transfer, and editor-sync budgets above remain
future gates; Phase 3 introduced none of those systems.

## Phase 4A Remote Workspace Foundation evidence

The Phase 4A workspace adds no polling loop, timer, recursive enumeration,
prefetch, per-entry task, or per-row remote `stat`. Remote work runs off
`MainActor` through one provider actor per SSH runtime with at most two
concurrent requests and one per directory; only immutable listing values publish
on the main actor. Idle workspaces schedule no work. The sidebar flattens only
already-cached listings inside the bounded expansion set, so listing publication
performs no provider I/O.

The deterministic 1,000-entry benchmark (`RemoteWorkspacePerformanceTests`)
measures fixture construction separately from the model/order/cache-publication
segment and observed **20.84 ms p90** against the 100 ms budget (one warm-up plus
11 publications; debug test overhead included). The 2026-07-18 hardening pass
added a separate gate that constructs the 1,000-entry visible projection and
performs 1,000 iterations of exact hit/miss entry and selectability lookups; its
p90 also passed the 100 ms budget with fixture construction outside timing, one
warm-up, and 11 measured runs. The final focused two-test performance suite passed
in 0.235 s; that suite duration is not presented as the measured application p90.

Cache bounds (32 directories, 20,000 entries, 10,000 entries/32 MiB per response)
and provider-concurrency bounds are asserted by
`RemoteWorkspaceBoundednessTests` and the provider contract suite. Cold launch,
Instruments main-thread stall capture, resident memory with a populated
workspace, and the 10,000-entry release gate remain unmeasured and open; the
packaged real-Relay inspection recorded in
`docs/audits/0006-phase-4a-remote-workspace-evidence.md` is qualitative, not a
release benchmark. The production provider is event-driven: it uses readiness-
based nonblocking pipe I/O, serialized bounded requests, and no polling. Network
latency remains inside the independent OpenSSH/SFTP process and is not included in
the local projection p90.
