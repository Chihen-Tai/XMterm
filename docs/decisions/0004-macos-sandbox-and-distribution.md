# ADR 0004: macOS Sandbox, Signing, and Distribution Strategy

- **Status:** Proposed
- **Date:** 2026-07-15

## Context

XMterm needs a PTY, `/usr/bin/ssh`, access to the user's OpenSSH configuration and
agent, local editor launching, filesystem watching, cache storage, and Finder
upload/download drag-and-drop. Distribution choices affect which of these are
available and what permissions or entitlements are required.

## Questions to answer

- Mac App Store sandbox versus direct signed/notarized distribution;
- access to `~/.ssh/config`, included config files, keys referenced by OpenSSH, and
  SSH agent sockets;
- launching `/usr/bin/ssh` and local editors;
- PTY/process restrictions;
- security-scoped bookmarks for user-selected local download/cache locations;
- Finder promised-file drag behavior;
- automatic updates outside the App Store;
- hardened runtime and required entitlements.

## Decision principles

- Do not weaken host-key or credential security to fit a distribution channel.
- Request the narrowest permissions that still preserve the core workflow.
- Explain user-visible permission prompts before they appear.
- Keep cache and diagnostics user-private.
- Validate the actual signed release build, not only an unsigned Xcode run.

## Decision

Pending a minimal signed prototype that exercises SSH, PTY, config access, editor
launch, file watching, and Finder drag/drop.

Phase 1 establishes narrower evidence: the local PTY application can be staged as
a native `.app`, ad-hoc signed, and verified with `codesign --deep --strict`. This
does not answer the distribution decision because it does not exercise Developer
ID signing, hardened runtime, notarization, sandboxing, SSH configuration access,
editor launch, filesystem watching, or Finder drag/drop.

Phase 2 adds a production direct-`/usr/bin/ssh` launch path and deterministic tests
that preserve inherited OpenSSH environment/config behavior. A staged development
bundle and any real-relay smoke result are recorded in Audit 0003, but neither an
ad-hoc development launch nor successful authentication decides Mac App Store
sandbox viability, Developer ID entitlements, hardened runtime, notarization, or
access to every included config/key/agent arrangement. This ADR remains Proposed.

Phase 3 adds a versioned user-scoped profile document at the Foundation-resolved
Application Support location, same-directory atomic replacement, and explicit
corrupt-store recovery. Packaged development-app acceptance verifies this behavior
for an ad-hoc staged bundle and confirms that stored launch metadata contains no
credential values or private-key contents. It does not prove behavior inside the
Mac App Sandbox, access to arbitrary identity-file references under sandboxing,
Developer ID signing, hardened runtime, notarization, or update delivery. No SFTP,
remote browser, editor launch, watcher, or Finder drag/drop capability was added,
so this ADR remains **Proposed**.
