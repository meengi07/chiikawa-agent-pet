#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./scripts/build-app.sh
osascript -e 'if application id "local.chiikawa.agent-pet" is running then tell application id "local.chiikawa.agent-pet" to quit'
rsync -a --delete build/ChiikawaPet.app/ /Applications/ChiikawaPet.app/
open /Applications/ChiikawaPet.app
