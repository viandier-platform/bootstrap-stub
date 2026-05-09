#!/usr/bin/env bash
# bootstrap.sh
#
# Public stub for the Viandier bootstrap.
# Authenticates to Infisical with a Universal Auth machine identity,
# fetches a fine-grained GitHub PAT, downloads the real hardening
# script from the private repo, and executes it with all passed args.
#
# Usage:
#   export INFISICAL_CLIENT_ID=...
#   export INFISICAL_CLIENT_SECRET=...
#   curl -fsSL https://viandier.com/bootstrap | sudo -E bash -s -- --profile server
#
# This stub is non-functional without valid INFISICAL_CLIENT_ID and
# INFISICAL_CLIENT_SECRET set in the environment of a privileged shell
# in the Viandier Infisical project.

set -euo pipefail
IFS=$'\n\t'

readonly INFISICAL_HOST="${INFISICAL_HOST:-https://app.infisical.com}"
readonly INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID must be set}"
readonly INFISICAL_ENV="${INFISICAL_ENV:-prod}"
readonly GH_OWNER="${GH_OWNER:-viandier-platform}"
readonly GH_REPO="${GH_REPO:-bootstrap}"
readonly GH_REF="${GH_REF:-main}"
readonly GH_PATH="${GH_PATH:-scripts/ubuntu-harden.sh}"

readonly STUB_VERSION="0.1.0"

log()  { printf "\033[1;34m[stub]\033[0m %s\n" "$*" >&2; }
warn() { printf "\033[1;33m[stub]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[stub]\033[0m %s\n" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

[[ $EUID -eq 0 ]] || die "Run as root (use sudo -E to preserve env)"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || die "Required command not found: $cmd. Install with: apt-get install -y $cmd"
done

[[ -n "${INFISICAL_CLIENT_ID:-}" ]] || die "INFISICAL_CLIENT_ID not set in environment"
[[ -n "${INFISICAL_CLIENT_SECRET:-}" ]] || die "INFISICAL_CLIENT_SECRET not set in environment"

log "Stub v${STUB_VERSION} starting"
log "Target: ${GH_OWNER}/${GH_REPO}@${GH_REF}:${GH_PATH}"

log "Authenticating to Infisical"
auth_response="$(curl -sS --fail --max-time 30 \
  --request POST \
  --url "${INFISICAL_HOST}/api/v1/auth/universal-auth/login" \
  --header 'Content-Type: application/json' \
  --data "$(jq -nc \
    --arg cid "$INFISICAL_CLIENT_ID" \
    --arg cs "$INFISICAL_CLIENT_SECRET" \
    '{clientId: $cid, clientSecret: $cs}')" \
  || die "Infisical auth request failed")"

access_token="$(echo "$auth_response" | jq -r '.accessToken // empty')"
[[ -n "$access_token" ]] || die "No accessToken in Infisical response"

log "Fetching GitHub PAT from Infisical"
secret_response="$(curl -sS --fail --max-time 30 \
  --get \
  --url "${INFISICAL_HOST}/api/v3/secrets/raw/github_pat" \
  --header "Authorization: Bearer ${access_token}" \
  --data-urlencode "workspaceId=${INFISICAL_PROJECT_ID}" \
  --data-urlencode "environment=${INFISICAL_ENV}" \
  --data-urlencode "secretPath=/bootstrap/_global" \
  || die "Failed to fetch github_pat from Infisical")"

gh_pat="$(echo "$secret_response" | jq -r '.secret.secretValue // empty')"
[[ -n "$gh_pat" ]] || die "No secretValue in Infisical github_pat response"

log "Downloading hardening script"
script_url="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/${GH_REF}/${GH_PATH}"

tmp_script="$(mktemp /tmp/ubuntu-harden.XXXXXX.sh)"
trap 'rm -f "$tmp_script"' EXIT

http_status="$(curl -sS --max-time 60 \
  --output "$tmp_script" \
  --write-out '%{http_code}' \
  --header "Authorization: token ${gh_pat}" \
  --header "Accept: application/vnd.github.raw" \
  "$script_url")"

[[ "$http_status" == "200" ]] || die "GitHub returned HTTP ${http_status} fetching ${GH_PATH}"

[[ -s "$tmp_script" ]] || die "Downloaded script is empty"

bash -n "$tmp_script" || die "Downloaded script has bash syntax errors"

chmod +x "$tmp_script"

log "Handing off to ubuntu-harden.sh"

exec "$tmp_script" "$@"