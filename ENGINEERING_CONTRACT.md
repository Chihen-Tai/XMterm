# XMterm Engineering Contract

Version: 1.0

This document is the highest-priority engineering specification for XMterm.

Every AI coding agent (Codex, ChatGPT, Claude Code, Cursor, etc.) must read this document completely before making any code changes.

If this document conflicts with implementation preferences, THIS DOCUMENT ALWAYS WINS.

---

# Mission

XMterm is a lightweight, terminal-first SSH/SFTP client for macOS.

XMterm is inspired by MobaXterm, but redesigned for modern macOS.

The primary goals are:

- Native
- Fast
- Lightweight
- Stable
- Predictable
- Professional

The application should feel like a native Apple application rather than a web application.

---

# Product Philosophy

XMterm is NOT:

- VS Code
- VS Code Remote SSH
- JetBrains Gateway
- Another Electron terminal
- Another IDE

XMterm IS:

- Terminal-first
- SSH workspace
- SFTP browser
- Session manager
- Lightweight remote workflow

---

# Highest Priorities

Priority 1

User responsiveness.

Priority 2

Native macOS UX.

Priority 3

Correct SSH behavior.

Priority 4

Maintainable architecture.

Priority 5

Visual polish.

If priorities conflict,
higher priorities always win.

---

# Required Reading

Before ANY code changes, read:

ENGINEERING_CONTRACT.md

PRODUCT.md

ARCHITECTURE.md

INTERACTIONS.md

SECURITY.md

PERFORMANCE.md

TESTING.md

Everything under docs/

Never skip these documents.

---

# Required Workflow

Before coding:

1. Read all documentation.

2. Explain understanding.

3. Produce an implementation plan.

4. Wait until the plan is complete.

Only then begin implementation.

---

# Required Implementation Plan

Every implementation plan MUST include:

Goal

Affected requirements

Requirement IDs

Files to modify

Files to create

Architecture impact

Performance impact

Security impact

UX impact

Testing plan

Edge cases

Potential risks

Remaining TODOs

Do not begin implementation until the plan is complete.

---

# Scope Rule

Never implement multiple unrelated features.

Each implementation should complete ONE feature.

Examples:

Good

SSH Session Manager

Terminal Tabs

Remote File Browser

Auto Upload

Bad

SSH
+
SFTP
+
UI rewrite
+
Settings redesign

---

# Architecture

Use Feature-based Architecture.

Each feature owns:

Models

Views

ViewModels

Services

Tests

Avoid God Objects.

Avoid giant files.

---

# UI Philosophy

Terminal is the primary interface.

Remote File Browser is secondary.

Settings are tertiary.

Editor is external.

VS Code is NOT embedded.

---

# External Editor

Remote files are never edited directly.

Workflow:

Download one file.

↓

Store inside cache.

↓

Open local cache.

↓

Watch file.

↓

Save.

↓

Upload.

Never synchronize entire folders.

Never run VS Code Remote SSH.

Never install remote daemons.

---

# SSH Philosophy

Always use OpenSSH.

Respect:

~/.ssh/config

ssh-agent

Keychain

ProxyJump

IdentityFile

ControlMaster

ControlPersist

Never implement custom SSH.

---

# Performance Philosophy

Never perform unnecessary work.

Lazy load everything.

Never recursively scan remote folders.

Never block the main thread.

Prefer async.

Prefer streaming.

Prefer incremental updates.

---

# Performance Budget

Cold launch

≤2s

Idle memory

≤120MB

One terminal

≤160MB

Five idle terminals

≤240MB

Idle CPU

<1%

No background indexing.

---

# Native macOS UX

Users expect Finder-quality interaction.

Users expect Terminal.app shortcuts.

Users expect Safari tab behavior.

Users expect VS Code editing quality.

Follow macOS conventions whenever possible.

---

# Desktop Interaction Rule

If a desktop interaction is standard,
implement it unless explicitly forbidden.

Examples:

drag selection

shift selection

command-click

multi selection

drag and drop

copy

cut

paste

undo

redo

rename

right click

keyboard shortcuts

focus

scroll

hover

tooltips

context menus

double click

triple click

---

# Feature Completion Rule

A feature is NOT complete unless:

Mouse works.

Keyboard works.

Loading state exists.

Error state exists.

Empty state exists.

Accessibility works.

Performance is acceptable.

Tests exist.

Documentation updated.

---

# Terminal Rules

Control shortcuts belong to remote shell.

Command shortcuts belong to XMterm.

Examples:

⌘C

Copy selection.

Ctrl+C

SIGINT.

⌘V

Paste.

Ctrl+V

Quoted insert.

⌘W

Close tab.

Ctrl+W

Delete previous word.

Never mix these.

---

# File Browser Rules

Support:

Single select

Command select

Shift select

Drag selection

Drag & drop

Rename

Delete

Copy

Cut

Paste

Upload

Download

Context menu

Keyboard navigation

Finder-like behavior.

---

# Terminal Tabs

Tabs behave like modern browsers.

Support:

New tab

Close tab

Duplicate

Rename

Reconnect

Close others

Overflow

Unread indicator

Remember scrollback

---

# Error Handling

Never fail silently.

Every failure should explain:

What happened.

Why.

Recovery options.

---

# Accessibility

Support:

VoiceOver

Keyboard navigation

Dark mode

Light mode

Dynamic type where appropriate

High contrast

Reduce motion

---

# Security

Never store plaintext passwords.

Never expose private keys.

Never log secrets.

Redact sensitive paths.

Use Keychain where appropriate.

---

# Code Style

Use Swift concurrency.

Use async/await.

Prefer immutable models.

Dependency injection.

No force unwraps.

Small files.

Small functions.

Readable code.

---

# Testing

Every feature requires:

Unit tests

Integration tests

Manual checklist

Performance validation

Regression tests

---

# Placeholder Rule

Do not fake implementations.

Do not mark TODO code as complete.

Do not ship placeholder behavior.

---

# Ambiguity Rule

If documentation is ambiguous:

Stop.

Search repository.

If still ambiguous:

Ask.

Never invent behavior.

---

# Documentation Rule

Every public API must be documented.

Every architectural decision should have ADR.

Major UX decisions should be documented.

---

# Commit Rule

Every commit should represent one logical feature.

Large unrelated commits are forbidden.

---

# Final Review Checklist

Before considering work complete:

Documentation updated

Tests pass

Performance checked

Accessibility checked

No duplicated logic

No dead code

No placeholder

No broken UX

No regressions

If any item fails,
the feature is NOT complete.

---

# Final Principle

When making engineering decisions,
optimize for what users feel,
not what developers prefer.

XMterm should always feel:

Fast.

Simple.

Native.

Reliable.

Professional.

If unsure,

prefer simplicity.