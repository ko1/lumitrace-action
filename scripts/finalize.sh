#!/usr/bin/env bash
# Shared finalize step for the report/ and merge/ actions.
#
# Given a merged trace JSON (+ optional self-contained HTML), upload it to the
# backend when an OIDC token is available (id-token: write), then build and post
# the GitHub Check Run. Reading inputs from LUMITRACE_* env vars keeps the two
# callers in sync — they only differ in how they produce the JSON/HTML.
#
# Inputs (env): LUMITRACE_OUT (json path, required), LUMITRACE_HTML_OUT (html
# path, optional), LUMITRACE_ENDPOINT, LUMITRACE_AUDIENCE, LUMITRACE_HEAD_SHA
# (required), LUMITRACE_WORKSPACE, LUMITRACE_CHECK_NAME, GH_TOKEN (for gh api).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUT="${LUMITRACE_OUT:?finalize: LUMITRACE_OUT is required}"
HTML="${LUMITRACE_HTML_OUT:-}"
ENDPOINT="${LUMITRACE_ENDPOINT:-}"; ENDPOINT="${ENDPOINT%/}"
AUDIENCE="${LUMITRACE_AUDIENCE:-lumitrace-ci}"
HEAD_SHA="${LUMITRACE_HEAD_SHA:?finalize: LUMITRACE_HEAD_SHA is required}"
WS="${LUMITRACE_WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"

if [ ! -s "$OUT" ]; then
  echo "lumitrace: no trace output at $OUT (diff had no traced lines?) — skipping check."
  exit 0
fi

# Upload to the backend ONLY when an OIDC token is available — i.e. the workflow
# granted id-token: write. No token, no endpoint, or any failure just means no
# hosted-report link: this never fails the job (lumitrace never blocks CI).
DETAILS=""
if [ -n "$ENDPOINT" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  OIDC="$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
          "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${AUDIENCE}" 2>/dev/null \
          | ruby -rjson -e 'begin; print JSON.parse(STDIN.read)["value"]; rescue; end' || true)"
  if [ -n "$OIDC" ]; then
    # gzip the (highly compressible) JSON/HTML before upload — a big diff can
    # produce MB-scale reports, and this is paid on every run. The server stores
    # and serves the gzip bytes as-is.
    tmp="${RUNNER_TEMP:-/tmp}"
    json_up="$OUT"
    gzip -c "$OUT" > "$tmp/lumitrace.json.gz" 2>/dev/null && json_up="$tmp/lumitrace.json.gz"
    html_field=()
    if [ -n "$HTML" ] && [ -s "$HTML" ]; then
      html_up="$HTML"
      gzip -c "$HTML" > "$tmp/lumitrace.html.gz" 2>/dev/null && html_up="$tmp/lumitrace.html.gz"
      html_field=(-F "html=@${html_up}")
    fi
    VIEW="$(curl -sS -X POST "${ENDPOINT}/api/v1/upload" \
            -H "Authorization: Bearer $OIDC" \
            -F "json=@${json_up}" "${html_field[@]}" 2>/dev/null \
            | ruby -rjson -e 'begin; print JSON.parse(STDIN.read)["view_url"]; rescue; end' || true)"
    [ -n "$VIEW" ] && DETAILS="${ENDPOINT}${VIEW}"
  fi
fi

ruby "$ROOT_DIR/build_check.rb" "$OUT" "$HEAD_SHA" "$WS" "$DETAILS" > "${RUNNER_TEMP:-/tmp}/lumitrace-check.json"
gh api "repos/${GITHUB_REPOSITORY}/check-runs" --input "${RUNNER_TEMP:-/tmp}/lumitrace-check.json" --silent
echo "lumitrace: posted check run '${LUMITRACE_CHECK_NAME:-lumitrace}' for ${HEAD_SHA}"
