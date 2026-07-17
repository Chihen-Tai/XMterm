# Local Editor Auto-Sync Design

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** Open remote files in local VS Code and upload each local save
- **Canonical requirements:** `EDIT-001` through `EDIT-007`
- **Transfer contract:** [`transfer-integrity.md`](transfer-integrity.md)

## Goal

XMterm uses the local Visual Studio Code application only as an editor. It must not
use VS Code Remote SSH, install VS Code Server, mount a remote workspace, or run a
remote indexer.

## Open flow

1. User double-clicks a supported remote file or chooses Open in VS Code.
2. XMterm checks size, file type, and transfer permission.
3. XMterm downloads the file to a user-only session-scoped cache.
4. XMterm records a durable mapping from local cache URL to session and exact
   remote path.
5. XMterm opens the local file using VS Code, reusing a window when configured.
6. XMterm watches the containing directory, not only the original inode.
7. XMterm records original remote mode, symlink identity/target state, and a local
   content fingerprint.
8. The file browser shows the mapped file's sync state.

## Save and upload flow

A local save may generate multiple filesystem events. XMterm groups them into one
logical change using debounce and content fingerprinting.

State sequence:

```text
Downloaded -> Watching -> Pending Upload -> Uploading -> Synced
                                      |          |
                                      |          -> Failed
                                      -> Conflict
```

If another save occurs during upload, XMterm records that a newer revision exists
and uploads the latest revision after the active transfer finishes. It never allows
an older transfer completion to mark a newer local revision as synced.

The upload follows `transfer-integrity.md`: stage a complete temporary remote file,
preserve the original mode, finalize safely, then mark the revision Synced only
after the final remote path is confirmed. A `.sh` file must not lose its executable
bit merely because it was edited locally.

When disconnected, the newest revision remains Pending Upload. On reconnect, XMterm
refreshes remote conflict metadata before sending it. It never assumes the remote
file remained unchanged while offline.

## Mapping identity

A mapping contains:

- mapping ID;
- session ID;
- exact remote path;
- local cache URL;
- editor identifier;
- remote size and modification marker at last download/upload;
- local content fingerprint at last successful upload;
- current local revision number;
- original remote mode and symlink/resolved-target metadata when available;
- current sync state and last error.

Mappings are one-to-one per session and exact remote path by default. Cache paths
must remain unique for files with the same basename in different directories or
sessions. Opening the same remote file reuses the mapping and focuses the local
editor.

If the remote path is renamed or deleted while a mapping is open, XMterm enters an
explicit Moved/Deleted/Conflict state rather than recreating the old path silently.
Symlinked files follow the symlink policy in `transfer-integrity.md` and must not
replace the link with a regular file accidentally.

## Conflict flow

Before upload, compare available remote metadata to the last known remote state.
When changed:

- do not upload automatically;
- retain local edits;
- present exact local and remote paths and timestamps;
- allow replace local, replace remote, keep both, or open both for comparison;
- remain in Conflict until the user resolves or dismisses it.

## Close and quit behavior

Closing a terminal tab does not invalidate a mapped editor file. Closing the
associated session may disconnect transfers but mappings remain recoverable.
Quitting XMterm with Pending Upload, Uploading, Failed, or Conflict mappings shows a
summary and gives the user a chance to cancel quitting.

## File types and limits

v0.1 is optimized for text-like files such as `.py`, `.sh`, `.txt`, `.md`, `.json`,
`.yaml`, `.yml`, `.toml`, `.xyz`, `.inp`, `.out`, and `.log`. Large or binary files
prompt before download and may default to Download rather than Open in Editor.
Thresholds are explicit settings, not hidden constants. Encoding and line endings
are not silently rewritten by XMterm; it transfers bytes. Binary detection and an
oversized-file warning happen before opening in a text editor.

The editor is configurable. v0.1 supports Visual Studio Code as the default plus a
custom application/argument template. Missing-editor and launch-failure states offer
Choose Editor, Download Only, and Retry.

## Minimum manual verification

- normal VS Code save;
- atomic save/rename behavior;
- rapid repeated saves;
- two mapped files saved independently;
- save during upload;
- remote file changed before local save;
- network disconnect then Retry;
- closing terminal while an editor mapping remains active;
- quitting with unsynced changes;
- cache recovery after restarting XMterm;
- executable mode preserved after editing a script;
- symlink target edited without replacing the link;
- remote rename/delete while local mapping is open;
- save while offline followed by conflict-safe reconnect;
- same basename opened from two sessions/directories;
- missing configured editor and custom editor command.
