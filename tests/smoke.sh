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
# --container=NAME    : docker container name, enables the hardening checks.
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

pass() { echo "  ok   $1"; }
flunk() { echo "  FAIL $1"; fail=1; }

# Substring test done with shell pattern matching rather than
# `echo "$haystack" | grep -q`.
#
# That pipeline looks harmless but is a trap under `set -o pipefail`: grep -q
# exits the moment it finds a match, closing the pipe while echo is still
# writing. echo dies with SIGPIPE, the pipeline reports 141, and `set -e`
# kills the whole script mid-run — but only once the page is big enough and
# the match is early enough, so it passes locally on small inputs and fails
# in CI. No subprocess here means no pipe to break.
contains() { # contains <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

assert_contains() { # assert_contains <description> <haystack> <needle>
  if contains "$2" "$3"; then pass "$1"; else flunk "$1"; fi
}

assert_eq() { # assert_eq <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    flunk "$1 (got '$2', want '$3')"
  fi
}

echo "smoke test against $BASE (target=$TARGET)"

# --- Wait for the server to respond -----------------------------------
# The container target has /healthz to poll; Pages does not, so poll / there.
PROBE_PATH="/"
if [ "$TARGET" = "container" ]; then
  PROBE_PATH="/healthz"
fi
up=1
for _ in $(seq 1 30); do
  if curl -fsS "$BASE$PROBE_PATH" >/dev/null 2>&1; then up=0; break; fi
  sleep 1
done
if [ "$up" -eq 0 ]; then pass "server responds within 30s"; else flunk "server responds within 30s"; fi

# --- Content checks (both targets) ------------------------------------
home=$(curl -fsS "$BASE/" 2>/dev/null || true)

assert_contains "/ serves the app shell" "$home" "FinanceFlow"
assert_contains "/ still references the OCR library" "$home" "tesseract"

if [ -n "$MARKER" ]; then
  assert_contains "build marker matches $MARKER" "$home" "<!-- build: $MARKER -->"
fi

# SPA fallback: an unknown path must still serve the app shell.
#
# The two targets differ in HTTP status, and this matters — asserting 200
# on Pages would fail every single release and trigger a false rollback:
#
#   container : nginx `try_files ... /index.html` serves the app with 200.
#   pages     : GitHub Pages serves 404.html (our copy of index.html) with
#               status 404. That is by design and cannot be configured away;
#               the browser still loads the app and the client-side router
#               takes over. So on Pages we assert on the body, not the code.
fallback_body=$(curl -s "$BASE/some/deep/route" 2>/dev/null || true)
fallback_code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/some/deep/route" 2>/dev/null || echo "000")

if [ "$TARGET" = "container" ]; then
  assert_eq "unknown route returns 200 (nginx try_files)" "$fallback_code" "200"
fi
assert_contains "unknown route serves the app shell (SPA fallback, code=$fallback_code)" \
  "$fallback_body" "FinanceFlow"

# --- Container-only checks ---------------------------------------------
if [ "$TARGET" = "container" ]; then
  body=$(curl -fsS "$BASE/healthz" 2>/dev/null || true)
  assert_eq "/healthz returns ok" "$body" "ok"

  # Header names are case-insensitive per RFC 9110, so compare lowercased.
  headers=$(curl -fsSI "$BASE/" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  assert_contains "X-Content-Type-Options: nosniff" "$headers" "x-content-type-options: nosniff"
  assert_contains "X-Frame-Options: SAMEORIGIN" "$headers" "x-frame-options: sameorigin"

  gzip_headers=$(curl -fsSI -H "Accept-Encoding: gzip" "$BASE/" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  if contains "$gzip_headers" "content-encoding: gzip"; then
    pass "gzip compression active"
  else
    echo "  warn gzip compression not active (non-blocking)"
  fi
else
  echo "  skip /healthz (not served on GitHub Pages)"
  echo "  skip response-header checks (Pages does not expose custom headers)"
fi

# --- Docker-level hardening checks (only when a container name is given) ---
if [ -n "$CONTAINER" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    flunk "docker not available but --container was passed"
  else
    uid=$(docker exec "$CONTAINER" id -u 2>/dev/null || echo "ERR")
    if [ "$uid" != "0" ] && [ "$uid" != "ERR" ]; then
      pass "container runs as non-root (uid=$uid)"
    else
      flunk "container runs as non-root (uid=$uid)"
    fi

    # HEALTHCHECK needs a few cycles to report; poll instead of reading once.
    health="starting"
    for _ in $(seq 1 20); do
      health=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "none")
      if [ "$health" = "healthy" ]; then break; fi
      sleep 2
    done
    assert_eq "HEALTHCHECK reports healthy" "$health" "healthy"

    restarts=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo "999")
    assert_eq "no restarts / crash-loop" "$restarts" "0"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "smoke test FAILED"
  exit 1
fi
echo "smoke test passed"
