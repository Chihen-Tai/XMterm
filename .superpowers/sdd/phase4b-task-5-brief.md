## Task 5 — Phase 4B.5 recursive transfer, batch operations, and collisions

**Acceptance:** `FILE-PERF-001`, `FILE-OPS-002`, `FILE-OPS-003`,
`FILE-XFER-001`–`004`, `FILE-META-001`.

- [ ] Write RED tests for iterative breadth-first discovery, parent/child operation
  order, 20,000-item/depth-128/pending-1,024 bounds, no task explosion, regular and
  empty directories, hidden/raw names, permission failure, directory/file
  collision, symlink rejection, cycle refusal, cancellation latency, and partial
  batch results.
- [ ] Implement `RemoteRecursivePlanner` with an explicit deque and immutable item
  plan. No recursion through the Swift call stack and no implicit traversal from
  selection/listing.
- [ ] Implement recursive upload/download/copy one file at a time per active job;
  keep the runtime-wide two-job concurrency limit.
- [ ] Implement recursive delete only after the stronger nonempty-directory
  confirmation; remove children before parents and never follow links.
- [ ] Implement Replace/Skip/Keep Both/Cancel and per-job Apply-to-All. Recheck each
  actual destination and case behavior immediately before publication.
- [ ] Retain exact per-item failures and completed items after partial failure or
  cancellation. Retry only failed/unstarted items.
- [ ] Run focused GREEN, 20,000-item boundary fixtures, related provider/engine
  regressions, and `./scripts/verify.sh`.
- [ ] Review traversal memory, symlink policy, delete safety, name generation,
  partial success, and batch error aggregation.

