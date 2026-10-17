#!/bin/bash
# Builds go/fpparquet and installs it into the app bundle Resources/bin.
# Called from the Xcode Run Script phase; also runnable standalone.
set -euo pipefail

# SRCROOT / BUILT_PRODUCTS_DIR / CONTENTS_FOLDER_PATH come from Xcode; default for standalone:
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

GO_DIR="$SRCROOT/go/fpparquet"

if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
  OUT_DIR="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/bin"
else
  OUT_DIR="$GO_DIR/bin"
fi
OUT="$OUT_DIR/fpparquet"

# Locate the Go toolchain; Xcode Run Script phases use a minimal PATH.
if ! command -v go >/dev/null 2>&1; then
  for candidate in /opt/homebrew/bin/go /usr/local/bin/go /usr/local/go/bin/go "$HOME/go/bin/go"; do
    if [[ -x "$candidate" ]]; then
      export PATH="$(dirname "$candidate"):$PATH"
      break
    fi
  done
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: go toolchain not found in PATH" >&2
  exit 1
fi

# Skip the rebuild if the binary exists and is newer than every .go file,
# go.mod/go.sum, and the vendor tree.
if [[ -f "$OUT" ]]; then
  newer="$({ find "$GO_DIR" -maxdepth 1 \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -newer "$OUT" -print
            find "$GO_DIR/vendor" -newer "$OUT" -print
          } 2>/dev/null)"
  if [[ -z "$newer" ]]; then
    echo "fpparquet up to date"
    exit 0
  fi
fi

mkdir -p "$OUT_DIR"
cd "$GO_DIR"
GOFLAGS=-mod=vendor CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$OUT" .
echo "built $OUT"
