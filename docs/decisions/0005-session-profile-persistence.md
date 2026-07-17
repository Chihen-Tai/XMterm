# ADR 0005: Store Saved Session Profiles as Versioned Local JSON

- **Status:** Accepted and implemented in Phase 3
- **Date:** 2026-07-16

## Context

Phase 3 needs durable local and SSH launch templates, stable IDs, favorites,
recency, first-launch defaults, and recoverable failures. The data set is small and
local to one macOS user. It contains non-secret connection metadata but must never
contain credentials or private-key contents.

## Options considered

1. A versioned Codable JSON document in Application Support.
2. One opaque `UserDefaults` value.
3. SQLite/Core Data.

## Decision

Use a deterministic Codable JSON document at the user Application Support location
resolved by `FileManager`:

```text
Application Support/XMterm/sessions.json
```

The initial document schema is version 1 and contains an ordered array of tagged
`SessionProfile` values. The file is written through a same-directory temporary
file and atomic replacement, with user-only permissions.

File absence means never initialized only when no preserved recovery file exists.
A valid empty document is initialized state. Corrupt, partially recoverable, and
unsupported documents are moved aside for diagnosis and are not automatically
overwritten. Recovery requires an explicit user action.

The JSON may store an identity-file path reference but never password, OTP,
passphrase, private-key bytes, terminal/clipboard content, or an environment dump.

All mutations use persist-before-publish semantics: the repository must finish the
atomic write before the `MainActor` store exposes the replacement immutable
collection. Save failure therefore leaves both the prior primary file and
observable profile data unchanged. Cheap structural draft validation may run while
typing, but filesystem existence, file readability, and executable checks are
reserved for save or launch boundaries and are not persistence schema concerns.

## Migration policy

Version 1 has no predecessor. Future migrations decode a known old version into a
complete current document, validate every recovered entry independently, and
write only after the whole migration succeeds. Unknown newer versions are preserved
without downgrade.

## Consequences

- No database dependency or opaque preferences blob is added.
- Files can be inspected and recovered without specialized tooling.
- Stable ordering, atomic replacement, and partial entry recovery require focused
  repository code and tests.
- The store remains device-local; cloud sync is explicitly deferred.
- ADR 0004 still governs future signed/sandboxed access. A development build does
  not prove distribution approval.

## Phase 3 verification

Repository and store tests cover one-time seeding, valid empty-store semantics,
rename/delete persistence, deterministic encoding, `0700`/`0600` permissions,
atomic replacement, failed-write non-publication, partial recovery, unsupported
versions, and explicit recovery finalization. Packaged-app inspection and the exact
version-1 evidence are recorded in
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md)
and
[`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).

This decision stores saved terminal launch templates only. It adds no SFTP state,
remote-file metadata, editor-sync mapping, credential store, cloud sync, or Phase 4
schema.
