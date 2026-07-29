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

# ─── FAULT INJECTION — rollback acceptance test retry, reverted next commit ───
# Same fault as before: corrupts the app shell in the Pages artifact only,
# so Stages 1-4 stay green and Stage 7 must catch it. This run exists to
# prove the artifact-name-collision fix actually lets Stage 9 redeploy
# last-good successfully, not just that Stage 7 detects the break.
sed -i "s#FinanceFlow#ROLLBACKTEST#g" "$OUT/index.html"
# ─── END FAULT INJECTION ───

cp "$OUT/index.html" "$OUT/404.html"

echo "prepared $OUT (marker=$SHA)"
grep -n "build: $SHA" "$OUT/index.html"
