# Remote File Browser Interaction Design

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** MobaXterm-style remote file sidebar with native macOS file operations
- **Canonical requirements:** `FILE-*` requirements in `INTERACTIONS.md`
- **Transfer contract:** [`transfer-integrity.md`](transfer-integrity.md)

## Goal

The remote file browser should feel familiar to Finder and VS Code users while
remaining intentionally lazy and lightweight. Normal file actions must support
single items and batches; implementing only a clickable directory tree is not
sufficient.

## Selection behavior

The browser uses stable remote-path identity.

- click selects one item;
- `Command-click` adds/removes individual items;
- `Shift-click` selects a range in the currently sorted visible listing;
- keyboard arrows move the selection/focus;
- typing characters performs incremental name selection/search in the current list;
- `Shift` plus arrows extends a range;
- `Command-A` selects visible loaded entries only;
- refreshing preserves selection for paths that still exist;
- changing directory clears selection unless returning through history.

Context menus operate on the full selection when the right-clicked item is already
selected. Right-clicking a non-selected item makes it the only selected item first.

## Copy, cut, paste, and move

Remote file references use a private XMterm pasteboard representation containing:

- source session identifier;
- exact source remote paths;
- requested operation: copy or move;
- creation timestamp for stale-operation handling.

Paste into a remote directory performs:

- same-session copy: server-side copy when safely supported, otherwise
  download/upload through XMterm;
- same-session move: remote rename when source and destination filesystem permit;
- cross-session copy: streamed or staged transfer through the local client;
- cross-session cut/move: copy first, verify destination, then delete source only
  after success.

A partially successful batch must retain enough detail to retry only failed items.

## Drag-and-drop

### Remote to remote

Dragging one selected item drags the entire current selection. Default operation is
move within the same session. Holding `Option` changes the operation to copy.
Drop highlighting identifies the exact destination directory.

### Finder to remote

Local files and folders dropped into the listing are uploaded. The UI shows total
item count, aggregate progress when available, current item, cancellation, and
collision choices.

### Remote to Finder

Remote items can be dragged to Finder. XMterm provides promised files/directories,
downloads them on demand, and reports errors instead of leaving empty placeholders.

## File action matrix

| Action | One file | One folder | Multi-selection |
|---|---:|---:|---:|
| Open in editor | Yes | No | Yes, with confirmation above a threshold |
| Download | Yes | Yes | Yes |
| Copy/Cut/Paste | Yes | Yes | Yes |
| Rename | Yes | Yes | No |
| Duplicate | Yes | Yes | Yes |
| Delete | Yes | Yes | Yes |
| Copy remote path | Yes | Yes | Yes, newline-separated |
| Open Terminal Here | Parent/current directory | Selected directory | No |

## Navigation and listing

The browser shows the active session and current absolute remote path. Users can:

- navigate Back, Forward, and Up;
- type or paste an absolute path;
- refresh the current directory;
- toggle hidden files;
- sort without network re-fetch when metadata is already present;
- resize the sidebar and columns;
- copy a path without opening the item;
- use Space for a Quick Look-style preview when supported, downloading only the
  selected file and never launching an editor automatically;
- show directories first when that preference is enabled.

Only immediate children are listed. Folder sizes are not recursively calculated by
default. Large listings may render progressively but retain stable path identity,
selection, and sorting behavior.

The listing distinguishes files, directories, symlinks, and special files where
metadata is available. Permissions, owner/group, link target, and executable state
may be shown in an inspector or columns without implying that all servers expose
all metadata. Broken symlinks remain visible. Deleting a symlink deletes only the
link.

## Error and conflict behavior

- permission denied leaves the current listing intact and identifies the path;
- disconnected state offers reconnect without clearing navigation history;
- a destination collision never overwrites silently;
- batch operations show success/failure per item;
- cancellation leaves already completed items completed and clearly lists the rest;
- deleted items disappear only after server confirmation.

## Minimum manual verification

- click, Command-click, Shift-click, keyboard range selection, Command-A;
- copy/cut/paste one and many files;
- drag move, Option-drag copy, invalid descendant drop;
- Finder upload/download drag in both directions;
- rename with Return;
- batch delete with partial permission failure;
- collision choices including Apply to All;
- refresh while selected items still exist;
- no recursive listing when expanding a large directory tree;
- incremental type-to-select and Space preview;
- executable permissions remain visible after editor save;
- symlink, broken symlink, and permission-denied behavior;
- paths containing spaces, quotes, leading dashes, and Unicode;
- disconnect during batch transfer and retry only failed items.
