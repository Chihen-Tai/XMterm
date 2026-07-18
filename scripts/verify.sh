#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

required_files=(
  README.md
  AGENTS.md
  PRODUCT.md
  INTERACTIONS.md
  ARCHITECTURE.md
  PLANS.md
  SECURITY.md
  PERFORMANCE.md
  TESTING.md
  Package.swift
  docs/design-docs/index.md
  docs/design-docs/v0.1-mvp.md
  docs/design-docs/session-tabs-ux.md
  docs/design-docs/session-manager.md
  docs/design-docs/terminal-ux.md
  docs/design-docs/terminal-keyboard.md
  docs/design-docs/terminal-compatibility.md
  docs/design-docs/ssh-connection-lifecycle.md
  docs/design-docs/tab-strip-redesign.md
  docs/design-docs/transfer-integrity.md
  docs/design-docs/macos-app-behavior.md
  docs/design-docs/remote-files-ux.md
  docs/design-docs/editor-sync-ux.md
  docs/design-docs/remote-workspace.md
  docs/design-docs/production-sftp-transport.md
  docs/checklists/interaction-parity.md
  docs/checklists/terminal-acceptance.md
  docs/checklists/ssh-terminal-acceptance.md
  docs/checklists/session-manager-acceptance.md
  docs/checklists/remote-workspace-acceptance.md
  docs/audits/0001-second-pass-gap-audit.md
  docs/audits/0002-phase-1-local-terminal-evidence.md
  docs/audits/0003-phase-2-ssh-terminal-evidence.md
  docs/audits/0004-phase-2-tab-strip-polish-evidence.md
  docs/audits/0005-phase-3-session-manager-evidence.md
  docs/audits/0006-phase-4a-remote-workspace-evidence.md
  docs/decisions/0003-terminal-engine-selection.md
  docs/decisions/0004-macos-sandbox-and-distribution.md
  docs/decisions/0005-session-profile-persistence.md
  docs/decisions/0006-session-centric-runtime-architecture.md
  docs/decisions/0007-remote-file-provider-transport.md
  docs/exec-plans/0001-bootstrap.md
  docs/exec-plans/0002-terminal-foundation.md
  docs/exec-plans/0003-native-local-terminal-vertical-slice.md
  docs/exec-plans/0004-local-terminal-close-confirmation.md
  docs/exec-plans/0005-phase-2-ssh-terminal-integration.md
  docs/exec-plans/0006-phase-2-tab-strip-polish.md
  docs/exec-plans/0007-phase-3-native-session-manager.md
  docs/exec-plans/0008-phase-4a-remote-workspace-foundation.md
  docs/exec-plans/0009-phase-4a-production-sftp-transport.md
)

for file in "${required_files[@]}"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing or empty required file: $file" >&2
    exit 1
  fi
done

echo "Required repository files: OK"

if command -v swift >/dev/null 2>&1; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    testing_frameworks="$developer_dir/Library/Developer/Frameworks"
    testing_runtime_libraries="$developer_dir/Library/Developer/usr/lib"

    if [[ -d "$testing_frameworks/Testing.framework" ]]; then
      swift test \
        -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xlinker -F -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_runtime_libraries"
    else
      swift test
    fi
  else
    # SwiftUI is available only on Apple platforms. On non-macOS CI,
    # still compile the platform-neutral domain target.
    swift build --target XMtermCore
  fi
else
  echo "Swift is not installed; skipped Swift verification." >&2
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --check
fi

echo "XMterm verification: OK"
