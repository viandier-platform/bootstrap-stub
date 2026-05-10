#!/usr/bin/env bash
# bootstrap.sh
#
# Public stub for the Viandier bootstrap.
# Authenticates to Infisical, fetches a fine-grained GitHub PAT,
# downloads the entire private repo as a tarball, extracts it,
# and executes the real hardening script with all passed args.
#
# Usage:
#   export INFISICAL_CLIENT_ID=...
#   export INFISICAL_CLIENT_SECRET=...
#   export INFISICAL_PROJECT_ID=...
#   curl -fsSL https://bootstrap.viandier.com/bootstrap | sudo -E bash -s -- --profile server
#
# This stub is non-functional without valid INFISICAL_CLIENT_ID,
# INFISICAL_CLIENT_SECRET, and INFISICAL_PROJECT_ID set in the environment
# of a privileged shell in the Viandier Infisical project.

set -euo pipefail
IFS=$'\n\t'

# -------- config --------
readonly INFISICAL_HOST="${INFISICAL_HOST:-https://app.infisical.com}"
readonly INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID must be set}"
readonly INFISICAL_ENV="${INFISICAL_ENV:-prod}"
readonly GH_OWNER="${GH_OWNER:-viandier-platform}"
readonly GH_REPO="${GH_REPO:-bootstrap}"
readonly GH_REF="${GH_REF:-main}"
readonly SCRIPT_PATH_IN_REPO="${SCRIPT_PATH_IN_REPO:-scripts/ubuntu-harden.sh}"

readonly STUB_VERSION="0.3.0"

# -------- log helpers --------
log()  { printf "\033[1;34m[stub]\033[0m %s\n" "$*" >&2; }
warn() { printf "\033[1;33m[stub]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[stub]\033[0m %s\n" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

# -------- preflight --------
[[ $EUID -eq 0 ]] || die "Run as root (use sudo -E to preserve env)"

for cmd in curl jq tar; do
  command -v "$cmd" >/dev/null || die "Required command not found: $cmd. Install with: apt-get install -y $cmd"
done

[[ -n "${INFISICAL_CLIENT_ID:-}" ]] || die "INFISICAL_CLIENT_ID not set in environment"
[[ -n "${INFISICAL_CLIENT_SECRET:-}" ]] || die "INFISICAL_CLIENT_SECRET not set in environment"

log "Stub v${STUB_VERSION} starting"
log "Target: ${GH_OWNER}/${GH_REPO}@${GH_REF}"

# -------- auth to infisical --------
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

# -------- fetch github pat --------
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

# -------- resolve git ref to sha --------
log "Resolving ${GH_REF} to commit SHA"
sha_response="$(curl -sS --fail --max-time 30 \
  --header "Authorization: token ${gh_pat}" \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/commits/${GH_REF}" \
  || die "Failed to resolve git ref to SHA")"

HARDEN_VERSION="$(echo "$sha_response" | jq -r '.sha // "unknown"' | cut -c1-12)"
[[ "$HARDEN_VERSION" != "unknown" ]] || die "Could not resolve SHA from GitHub API"
export HARDEN_VERSION
log "Using HARDEN_VERSION=${HARDEN_VERSION}"

# -------- download whole repo as tarball --------
log "Downloading repo tarball"
tarball_url="https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/tarball/${GH_REF}"

work_dir="$(mktemp -d /tmp/ubuntu-harden.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

tarball="${work_dir}/repo.tar.gz"
http_status="$(curl -sS --max-time 120 \
  --location \
  --output "$tarball" \
  --write-out '%{http_code}' \
  --header "Authorization: token ${gh_pat}" \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "$tarball_url")"

[[ "$http_status" == "200" ]] || die "GitHub returned HTTP ${http_status} fetching tarball"
[[ -s "$tarball" ]] || die "Downloaded tarball is empty"

# -------- extract --------
log "Extracting"
extract_dir="${work_dir}/repo"
mkdir -p "$extract_dir"

# GitHub tarballs have a top-level directory like viandier-platform-bootstrap-<sha>/
# Strip the first path component so we get scripts/, manifests/, etc directly.
tar -xzf "$tarball" -C "$extract_dir" --strip-components=1

# -------- locate the entry point --------
entry_point="${extract_dir}/${SCRIPT_PATH_IN_REPO}"
[[ -f "$entry_point" ]] || die "Entry point not found: ${SCRIPT_PATH_IN_REPO}"
[[ -s "$entry_point" ]] || die "Entry point is empty: ${SCRIPT_PATH_IN_REPO}"

bash -n "$entry_point" || die "Entry point has bash syntax errors"
chmod +x "$entry_point"

# -------- exec --------
log "Handing off to ubuntu-harden.sh"

# Pass through Infisical creds (the real script needs them too) and all args.
exec "$entry_point" "$@"
