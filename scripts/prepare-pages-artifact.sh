#!/usr/bin/env bash
# Stage 6 (docs/PIPELINE-SPEC.md): build the exact directory that gets
# uploaded to GitHub Pages.
#
# public/index.html itself is never modified — it must stay byte-identical
# to the BudgetTracker source (see README.md). This script copies it into a
# throwaway output directory and only touches the copy:
#
#   1. Injects a `<!-- build: SHA -->` marker so Stage 7 can prove Pages is
#      actually serving the new build and not a stale cached one.
#   2. Adds a 404.html (a copy of index.html) so unknown routes still serve
#      the SPA on Pages the same way nginx's `try_files` does in the
#      container — GitHub Pages has no server config to set that up any
#      other way.
#
# Usage: scripts/prepare-pages-artifact.sh <sha> <output-dir>
set -euo pipefail

SHA="${1:?usage: prepare-pages-artifact.sh <sha> <output-dir>}"
OUT="${2:?usage: prepare-pages-artifact.sh <sha> <output-dir>}"

if [ ! -f public/index.html ]; then
  echo "error: run this from the repo root (public/index.html not found)" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -r public/. "$OUT/"

if ! grep -q "<head>" "$OUT/index.html"; then
  echo "error: <head> not found in index.html; cannot inject build marker" >&2
  exit 1
fi

sed -i "s#<head>#<head>\n<!-- build: ${SHA} -->#" "$OUT/index.html"

# ─── FAULT INJECTION — rollback acceptance test, reverted in the next commit ───
# Simulates a packaging bug that corrupts the app shell in the Pages artifact
# only. The container never runs this script (the Dockerfile COPYs public/
# directly), so Stages 2-4 stay green and the fault reaches production — which
# is exactly the class of failure Stage 7 exists to catch and Stage 9 to undo.
sed -i "s#FinanceFlow#ROLLBACKTEST#g" "$OUT/index.html"
# ─── END FAULT INJECTION ───

cp "$OUT/index.html" "$OUT/404.html"

echo "prepared $OUT (marker=$SHA)"
grep -n "build: $SHA" "$OUT/index.html"
