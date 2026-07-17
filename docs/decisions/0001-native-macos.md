# ADR 0001: Build XMterm as a Native macOS Application

- **Status:** Accepted
- **Date:** 2026-07-15

## Context

XMterm must feel lightweight and responsive while rendering terminals, browsing files, and watching local editor saves. The product is initially macOS-only.

## Decision

Use Swift with SwiftUI/AppKit for the application shell. Do not use Electron or a webview-based desktop framework.

## Consequences

- Native windowing, menus, shortcuts, accessibility, file events, and Keychain integration are available.
- Memory and startup overhead can remain substantially smaller than a bundled browser runtime.
- Initial development targets macOS only.
- AppKit bridges are allowed where SwiftUI does not provide sufficient terminal or text-performance control.
