## Task 3 — Phase 4B.3 transfer queue, progress, cancellation, and retry

**Acceptance:** `APP-007`, `APP-008`, `FILE-XFER-001`, `FILE-XFER-003`,
`SESS-011`.

**Interfaces produced:**

```swift
public enum RemoteTransferJobState: Equatable, Sendable {
    case queued, preparing, running, conflict
    case cancelling, cancelled, completed
    case failed(RemoteFileError)
}

public struct RemoteTransferJobSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let attemptID: UUID
    public let state: RemoteTransferJobState
    public let runningPhase: RemoteTransferRunningPhase?
    public let bytesCompleted: UInt64
    public let bytesTotal: UInt64?
    public let itemsCompleted: Int
    public let itemsTotal: Int?
    public let itemFailures: [RemoteTransferItemFailure]
}
```

- [ ] Write RED tests for FIFO start order, maximum two active jobs, 1,000-job
  model capacity, 500 terminal-state transfer-record retention, monotonic
  bytes/items, transferring/verifying phases, conflict and state transitions,
  one failure not corrupting another, collision suspension, cancellation settlement,
  retry attempt identity, committed-item exclusion, and two-engine isolation.
- [ ] Add `RemoteTransferModels`, a pure collision resolver, engine actor, and
  main-actor coordinator. Use injected UUID/clock/provider/staging factories for
  deterministic tests without production-only test hooks.
- [ ] Implement queue pumping without detached work, polling, or per-chunk tasks.
  Coalesce progress publication to 10 Hz but publish state/collision/error edges
  immediately.
- [ ] Make cancellation await worker invalidation and staging cleanup before
  `.cancelled`; reject stale attempt completion.
- [ ] Make `conflict` release its worker/channel set and active slot; resolution
  requeues the same job/attempt in original FIFO order and revalidates the
  destination before publication.
- [ ] Make explicit retry create a new attempt, rediscover failed/unstarted items,
  and never republish a prior attempt.
- [ ] Run focused RED/GREEN, concurrency stress/repetition, Thread Sanitizer when
  practical, and `./scripts/verify.sh`.
- [ ] Review actor isolation, retained task ownership, unchecked continuations,
  cancellation latency, and memory bounds.

