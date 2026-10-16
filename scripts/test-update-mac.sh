#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="" MANIFEST="" SIGNATURE="" PACKAGE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|--manifest|--signature|--package)
            [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 64; }
            case "$1" in
                --app) APP="$2" ;;
                --manifest) MANIFEST="$2" ;;
                --signature) SIGNATURE="$2" ;;
                --package) PACKAGE="$2" ;;
            esac
            shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
    esac
done
[[ -d "$APP" && -f "$MANIFEST" && -f "$SIGNATURE" && -f "$PACKAGE" ]] || {
    printf 'Usage: bash scripts/test-update-mac.sh --app <ChiikawaPet.app> --manifest <updates.json> --signature <updates.sig> --package <current-arch.dmg>\n' >&2
    exit 64
}
export PET_UPDATE_SMOKE_APP="$APP"
export PET_UPDATE_SMOKE_MANIFEST="$MANIFEST"
export PET_UPDATE_SMOKE_SIGNATURE="$SIGNATURE"
export PET_UPDATE_SMOKE_PACKAGE="$PACKAGE"
./scripts/test.sh --filter UpdateApplySmokeTests
