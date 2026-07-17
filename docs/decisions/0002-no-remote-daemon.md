# ADR 0002: Do Not Install an XMterm Remote Daemon

- **Status:** Accepted
- **Date:** 2026-07-15

## Context

The product exists partly because remote IDE servers can consume resources, depend on a long-lived remote process, and make intermittent or jump-host connections feel fragile.

## Decision

XMterm will use standard SSH/SFTP capabilities and local processes only. It will not install a server component, language server, indexer, watcher, or workspace runtime on the remote machine.

## Consequences

- Remote resource use stays close to ordinary SSH/SFTP activity.
- File editing uses download → local editor → upload rather than a live remote filesystem abstraction.
- Rich IDE features are intentionally outside the core product.
- Some optimizations must be implemented client-side, including cache mapping, conflict checks, and save watching.
