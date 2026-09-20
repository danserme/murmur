#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/DerivedData/Build/Products/Release/murmur.app}"
OUT="$ROOT/dist/murmur-1.0.dmg"
DMGBUILD="$HOME/Library/Python/3.13/bin/dmgbuild"

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP — build Release first." >&2
  exit 1
fi

export MURMUR_ROOT="$ROOT"
python3 "$ROOT/packaging/dmg_background.py"
mkdir -p "$ROOT/dist"
rm -f "$OUT"

"$DMGBUILD" -s "$ROOT/packaging/dmgbuild_settings.py" "murmur" "$OUT"
echo "$OUT"
