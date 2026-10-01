#!/usr/bin/env bash
# Deploy Solaryn's Expedition to the live WoW: Forever beta client.
#
#   ./deploy.sh          verify tests, then copy to the live addon folder
#   ./deploy.sh --force  copy without running the test suite first
#
# Source of truth is this directory; the live client folder is a copy only.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/home/kwalker/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_classic_beta_/Interface/AddOns/SolarynExpedition"
FILES=(*.lua *.xml SolarynExpedition.toc)

cd "$SRC"

# Files that get syntax-checked (the TOC is not Lua).
LUA_FILES=(*.lua)

if [[ "${1:-}" != "--force" ]]; then
    echo "==> syntax check"
    for f in "${LUA_FILES[@]}" test/*.lua; do
        luac5.1 -p "$f" || { echo "SYNTAX FAIL: $f" >&2; exit 1; }
    done

    echo "==> test suite"
    lua5.1 test/harness.lua > /tmp/solaryn_test.log 2>&1 || {
        tail -20 /tmp/solaryn_test.log >&2
        echo "TESTS FAILED — not deploying" >&2
        exit 1
    }
    grep -E "passed," /tmp/solaryn_test.log

    echo "==> load order"
    lua5.1 test/check_load_order.lua | tail -1
fi

echo "==> deploying to $DEST"
mkdir -p "$DEST"
# Remove stale files (e.g. renamed modules) before copying, but keep the
# client's own SavedVariables, which live in WTF/ not here.
find "$DEST" -maxdepth 1 -type f \( -name '*.lua' -o -name '*.xml' \) -delete
cp -v "${FILES[@]}" "$DEST/"

echo "==> verifying deployed copy matches source"
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$DEST/$f"; then
        echo "MISMATCH: $f" >&2
        exit 1
    fi
done
echo "OK — $(ls -1 "$DEST" | wc -l) files, source and live copy identical"
echo "Remember: /reload in game (or /reloadui)."
