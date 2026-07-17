# Remote Transfer and Data-Integrity Contract

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** Upload, download, copy, move, editor-sync writes, metadata, symlinks,
  queues, retries, and cleanup
- **Canonical requirements:** `FILE-XFER-001` through `FILE-XFER-004`,
  `FILE-META-001`, `EDIT-007`

## Goal

A transfer is complete only when the intended bytes exist at the intended path and
the UI can explain the result. XMterm must not leave a file looking successfully
saved while the remote file is partial, stale, replaced incorrectly, or still
queued.

## Transfer state model

Each item has an independent state:

```text
queued → preparing → transferring → verifying → completed
                         ↘ cancelled
                         ↘ failed
                         ↘ conflict
```

Batch UI shows aggregate progress and per-item state. One failed item does not hide
successful items or cancel unrelated work unless the user explicitly cancels the
batch.

## Upload integrity

For normal uploads and editor auto-sync:

1. inspect the destination and collision policy;
2. upload to a uniquely named temporary file in the same remote directory when the
   server/backend supports it;
3. apply required mode metadata to the temporary file;
4. close and confirm the upload operation succeeded;
5. atomically rename the temporary file over the destination when supported;
6. refresh destination metadata;
7. mark the revision Synced only after the server confirms the final path.

Uploading to the same directory maximizes the chance that rename is atomic. If the
server cannot provide safe replace semantics, XMterm must use a documented fallback
and expose the reduced guarantee rather than silently claiming atomicity.

Temporary remote files are cleaned after success, cancellation, and recoverable
failure. Orphan cleanup must never delete a file not created and tagged by XMterm.

## Download integrity

Downloads write to a temporary local file with user-only permissions, then move it
into the final cache/download location only after the transfer succeeds. A failed or
cancelled download must not replace an existing complete local file.

Finder downloads use the user's collision choice and may stage through a temporary
location before the final move.

## Metadata preservation

Where supported and meaningful, XMterm preserves:

- executable and ordinary permission bits;
- modification time when the user selects preserve timestamps;
- file type;
- original remote mode during editor auto-sync.

XMterm must not promise to preserve owner/group when the account lacks permission.
Changing ownership is not a normal save operation.

The UI must not turn an executable `.sh` file into a non-executable file merely
because it was edited locally and uploaded.

## Symlink behavior

Remote listing distinguishes symlinks from regular files and directories.

- `lstat` identity and resolved target metadata are kept separate.
- Opening a symlinked text file edits the target by default without replacing the
  symlink itself.
- Copy Link and Copy Target are distinct operations where the backend can support
  both.
- Recursive operations must detect symlink loops and never follow them silently.
- Broken symlinks remain visible and produce an understandable error when opened.
- Deleting a symlink deletes the link, not its target.

If the backend cannot safely resolve and preserve a symlink during editor sync,
XMterm requires confirmation before editing.

## Remote path correctness

All operations use structured remote paths or protocol APIs. Never compose a shell
command from unescaped filenames.

Paths may contain:

- spaces;
- quotes;
- leading dashes;
- tabs or newlines where the server permits them;
- Unicode;
- names that differ only by case.

The UI must display ambiguous control characters safely while preserving the exact
remote byte/path identity internally.

## Copy and move semantics

- Same-filesystem/server moves should use remote rename when supported.
- A move across servers or filesystems is copy-then-verified-delete, never presented
  as atomic.
- The source is deleted only after the destination is confirmed complete.
- Cancelling during cross-session move leaves the source intact.
- Moving a directory into itself or a descendant is rejected before transfer.

## Collision behavior

Replace, Keep Both, Skip, Cancel, and Apply to All remain available. Additional
rules:

- Replace never begins until explicitly selected;
- Keep Both generates a name that is valid on the destination server;
- directory-versus-file collisions are explained separately;
- case-only rename behavior accounts for case-sensitive and case-insensitive
  destinations;
- retry reuses the recorded collision decision only when still safe.

## Large files and directories

- Configurable thresholds warn before opening a large file in a text editor.
- Binary detection prevents accidental text-editor auto-sync by default.
- Large directory listings stream/progressively render if the backend permits while
  preserving stable selection identity.
- Recursive directory operations calculate progress incrementally and remain
  cancellable.
- Resume support may be deferred, but the UI must not imply that a failed transfer
  resumes when it restarts from zero.

## Offline and retry behavior

A save made while disconnected becomes `Pending Upload` and retains the newest local
revision. Reconnect does not upload silently if remote conflict metadata is stale;
XMterm refreshes remote state first.

Retry rules:

- retries are idempotent where possible;
- a newer local revision supersedes an older queued revision for the same mapping;
- a completed newer revision can never be overwritten by an older retry;
- automatic retry uses bounded backoff and stops on authentication or host-key
  failures;
- user cancellation remains cancelled until the user explicitly retries.

## Verification

A transfer test suite must cover:

- zero-byte files;
- executable scripts;
- large files;
- Unicode and whitespace-heavy names;
- symlinks and broken symlinks;
- overwrite conflicts;
- disconnect during upload and download;
- cancellation at each stage;
- batch partial failure;
- two rapid editor saves while upload is active;
- remote modification between download and upload;
- server without atomic replace support.
