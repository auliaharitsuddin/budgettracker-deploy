#!/usr/bin/env bash
# Smoke test against a running BudgetTracker deployment.
#
# Usage:
#   tests/smoke.sh [BASE_URL] [--target=container|pages] [--container=NAME] [--marker=SHA]
#
# Defaults: BASE_URL=http://localhost:8080, --target=container
#
# --target=container : full check set, including /healthz, security headers set
#                       by nginx.conf, and (with --container) docker-level
#                       hardening checks (non-root, HEALTHCHECK, restart count).
# --target=pages      : GitHub Pages has no /healthz endpoint and does not let
#                       us set response headers, so those checks are skipped.
#                       Everything that only depends on the served HTML still
#                       runs the same way against a container or against Pages.
# --marker=SHA        : assert the page's build marker comment matches SHA.
#                       Used by Stage 7 to prove Pages served the new build,
#                       not a stale cached one.
set -euo pipefail

BASE="http://localhost:8080"
TARGET="container"
CONTAINER=""
MARKER=""

for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#--target=}" ;;
    --container=*) CONTAINER="${arg#--container=}" ;;
    --marker=*) MARKER="${arg#--marker=}" ;;
    http*) BASE="$arg" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$TARGET" != "container" ] && [ "$TARGET" != "pages" ]; then
  echo "error: --target must be 'container' or 'pages', got '$TARGET'" >&2
  exit 2
fi

fail=0

check() { # check <description> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    fail=1
  fi
}

soft_check() { # like check, but never fails the run — informational only
  if [ "$2" -eq 0 ]; then
    echo "  ok   $1"
  else
    echo "  warn $1 (non-blocking)"
  fi
}

echo "smoke test against $BASE (target=$TARGET)"

# --- Wait for the server to respond -----------------------------------
# Container target has /healthz to poll; Pages does not, so poll / instead.
PROBE_PATH="/"
if [ "$TARGET" = "container" ]; then
  PROBE_PATH="/healthz"
fi
up=1
for _ in $(seq 1 30); do
  if curl -fsS "$BASE$PROBE_PATH" >/dev/null 2>&1; then up=0; break; fi
  sleep 1
done
check "server responds within 30s" "$up"

# --- Content checks (run for both targets) ----------------------------
home=$(curl -fsS "$BASE/" 2>/dev/null || true)

echo "$home" | grep -q "FinanceFlow"
check "/ serves the app shell" $?

echo "$home" | grep -q "tesseract"
check "/ still references the OCR library" $?

if [ -n "$MARKER" ]; then
  echo "$home" | grep -q "<!-- build: $MARKER -->"
  check "build marker matches $MARKER" $?
fi

# SPA fallback: an unknown path must still return the app, not a 404.
# On GitHub Pages this relies on public/404.html being a copy of index.html
# (see docs/PIPELINE-SPEC.md Stage 6) — same assertion, same meaning, on both
# targets.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/some/deep/route")
[ "$code" = "200" ]
check "unknown route falls back to the app (SPA fallback)" $?

# --- Container-only checks ---------------------------------------------
if [ "$TARGET" = "container" ]; then
  body=$(curl -fsS "$BASE/healthz" 2>/dev/null || true)
  [ "$body" = "ok" ]
  check "/healthz returns ok" $?

  headers=$(curl -fsSI "$BASE/" 2>/dev/null || true)
  echo "$headers" | grep -qi "x-content-type-options: nosniff"
  check "security headers present" $?

  echo "$headers" | grep -qi "x-frame-options: sameorigin"
  check "X-Frame-Options present" $?

  gzip_headers=$(curl -fsSI -H "Accept-Encoding: gzip" "$BASE/" 2>/dev/null || true)
  echo "$gzip_headers" | grep -qi "content-encoding: gzip"
  soft_check "gzip compression active" $?
else
  echo "  skip /healthz (not served on GitHub Pages)"
  echo "  skip response-header checks (Pages does not expose custom headers)"
fi

# --- Docker-level hardening checks (only when a container name is given) ---
if [ -n "$CONTAINER" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "  FAIL docker not available but --container was passed"
    fail=1
  else
    uid=$(docker exec "$CONTAINER" id -u 2>/dev/null || echo "ERR")
    [ "$uid" != "0" ] && [ "$uid" != "ERR" ]
    check "container runs as non-root (uid=$uid)" $?

    # HEALTHCHECK needs a few cycles to report; poll instead of a single read.
    health="starting"
    for _ in $(seq 1 20); do
      health=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "none")
      [ "$health" = "healthy" ] && break
      sleep 2
    done
    [ "$health" = "healthy" ]
    check "HEALTHCHECK reports healthy (got: $health)" $?

    restarts=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo "999")
    [ "$restarts" = "0" ]
    check "no restarts / crash-loop (RestartCount=$restarts)" $?
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "smoke test FAILED"
  exit 1
fi
echo "smoke test passed"
