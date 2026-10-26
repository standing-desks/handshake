#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
handshake_trial_app="$PWD/out/debug/Build/Products/Debug/Handshake.app"
if [[ ! -d "$handshake_trial_app" ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make debug
fi
open -n "$handshake_trial_app" --env HANDSHAKE_PREFERENCES_SUITE=com.twineproject.Twine.cross-agent-memory --args -ApplePersistenceIgnoreState YES
