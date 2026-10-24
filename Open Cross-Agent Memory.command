#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
twine_trial_app="$PWD/out/debug/Build/Products/Debug/Twine.app"
if [[ ! -d "$twine_trial_app" ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make debug
fi
open -n "$twine_trial_app" --env TWINE_PREFERENCES_SUITE=com.twineproject.Twine.cross-agent-memory --args -ApplePersistenceIgnoreState YES
