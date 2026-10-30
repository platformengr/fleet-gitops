# shellcheck shell=bash
# bootstrap/lib/common.sh: shared helpers for the bootstrap scripts.
#
# Source it from a script that already runs with `set -euo pipefail`:
#   . "$(dirname "$0")/../lib/common.sh"
#
# Provides: logging, a `run` wrapper that honours --dry-run, require_cmd,
# confirm, wait helpers, env-file loading and cluster inventory writers.

# ---------------------------------------------------------------------------
# Globals (scripts may override before or after sourcing)
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"         # 1 = print mutating commands instead of running them
ASSUME_YES="${ASSUME_YES:-0}"   # 1 = answer "yes" to confirm prompts

BOOTSTRAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${BOOTSTRAP_LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BOOTSTRAP_DIR}/.." && pwd)"
export BOOTSTRAP_LIB_DIR BOOTSTRAP_DIR REPO_ROOT

# Default Git URL Argo CD reads from. Override with REPO_URL=... and keep the
# manifests in sync with scripts/set-repo-url.sh.
DEFAULT_REPO_URL="https://github.com/abrahamberg/fleet-gitops.git"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_blue=$'\033[34m'
  _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_bold=$'\033[1m'
else
  _c_reset=""; _c_dim=""; _c_blue=""; _c_green=""; _c_yellow=""; _c_red=""; _c_bold=""
fi

log()     { printf '%s==>%s %s\n' "${_c_blue}${_c_bold}" "${_c_reset}" "$*" >&2; }
info()    { printf '    %s\n' "$*" >&2; }
ok()      { printf '%s ok%s %s\n' "${_c_green}" "${_c_reset}" "$*" >&2; }
warn()    { printf '%swarn%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2; }
err()     { printf '%serror%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s## %s%s\n' "${_c_bold}" "$*" "${_c_reset}" >&2; }

is_dry_run() { [[ "${DRY_RUN}" == "1" ]]; }

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

# _print_cmd ARGS...  prints a shell-quoted command line.
_print_cmd() {
  local out="" a
  if [[ $# -eq 1 && "$1" == "#"* ]]; then printf '%s+ %s%s\n' "${_c_dim}" "$1" "${_c_reset}" >&2; return 0; fi
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$a "; else out+="$(printf '%q' "$a") "; fi
  done
  printf '%s+ %s%s\n' "${_c_dim}" "${out% }" "${_c_reset}" >&2
}

# run CMD ARGS...  runs a mutating command, or only prints it with --dry-run.
run() {
  if is_dry_run; then
    _print_cmd "$@"
    return 0
  fi
  _print_cmd "$@"
  "$@"
}

# run_stdin DESCRIPTION CMD ARGS...  like run, but the command reads a manifest
# from stdin. In dry-run mode the stdin is printed instead (callers must redact
# secrets before piping).
run_stdin() {
  local desc="$1"; shift
  if is_dry_run; then
    _print_cmd "$@"
    printf '%s    # stdin (%s):%s\n' "${_c_dim}" "$desc" "${_c_reset}" >&2
    sed 's/^/    | /' >&2
    return 0
  fi
  _print_cmd "$@" "<<< ${desc}"
  "$@"
}

# capture PLACEHOLDER CMD ARGS...  runs a read-only command and prints its
# stdout. In dry-run mode, when the command is not available or fails, the
# placeholder is printed instead so the rest of the flow can still be shown.
capture() {
  local placeholder="$1"; shift
  if is_dry_run; then
    local out=""
    if command -v "$1" >/dev/null 2>&1; then out="$("$@" 2>/dev/null || true)"; fi
    printf '%s' "${out:-$placeholder}"
    return 0
  fi
  "$@"
}

# require_cmd CMD [HINT]  fails if CMD is not on PATH (warns in dry-run).
require_cmd() {
  local cmd="$1" hint="${2:-}"
  if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
  if is_dry_run; then
    warn "'$cmd' not found on PATH (ignored in --dry-run)${hint:+. $hint}"
    return 0
  fi
  die "'$cmd' is required but not on PATH${hint:+. $hint}"
}

# confirm PROMPT  asks y/N; honours ASSUME_YES=1. Never prompts in dry-run.
confirm() {
  local prompt="${1:-Continue?}" reply
  if [[ "${ASSUME_YES}" == "1" ]] || is_dry_run; then return 0; fi
  if [[ ! -t 0 ]]; then die "$prompt (no TTY to confirm; re-run with --yes)"; fi
  read -r -p "${_c_yellow}${prompt}${_c_reset} [y/N] " reply
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# wait_for TIMEOUT_SECONDS DESCRIPTION CMD ARGS...  polls CMD until it succeeds.
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  if is_dry_run; then
    printf '%s+ # wait up to %ss for: %s%s\n' "${_c_dim}" "$timeout" "$desc" "${_c_reset}" >&2
    return 0
  fi
  local start now
  start="$(date +%s)"
  info "waiting for ${desc} (timeout ${timeout}s)"
  until "$@" >/dev/null 2>&1; do
    now="$(date +%s)"
    if (( now - start >= timeout )); then die "timed out waiting for ${desc}"; fi
    sleep 5
  done
  ok "$desc"
}

# ---------------------------------------------------------------------------
# Env files
# ---------------------------------------------------------------------------

# load_env PROVIDER_DIR [ENV_FILE]  sources ENV_FILE, else PROVIDER_DIR/env,
# else PROVIDER_DIR/env.example. Variables already exported in the shell win
# because env files use the VAR="${VAR:-default}" form.
load_env() {
  local dir="$1" file="${2:-}"
  if [[ -z "$file" ]]; then
    if [[ -f "$dir/env" ]]; then file="$dir/env"; else file="$dir/env.example"; fi
  fi
  [[ -f "$file" ]] || die "env file not found: $file"
  info "loading settings from ${file#"${REPO_ROOT}"/}"
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

# require_var NAME...  fails if a variable is empty (warns in dry-run).
require_var() {
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      if is_dry_run; then warn "$v is empty (ignored in --dry-run)"; else die "$v must be set (see env.example)"; fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Kube contexts
# ---------------------------------------------------------------------------

# context_server CONTEXT  prints the API server URL for a kubeconfig context.
context_server() {
  capture "https://<api-server-of-$1>" \
    kubectl config view --minify --context "$1" -o 'jsonpath={.clusters[0].cluster.server}'
}

# rename_context OLD NEW  renames a kubeconfig context, replacing NEW if present.
rename_context() {
  local old="$1" new="$2"
  [[ "$old" == "$new" ]] && return 0
  if ! is_dry_run && kubectl config get-contexts -o name 2>/dev/null | grep -qx "$new"; then
    run kubectl config delete-context "$new" >/dev/null
  fi
  run kubectl config rename-context "$old" "$new"
}

# ---------------------------------------------------------------------------
# Git / repo checks
# ---------------------------------------------------------------------------

# manifest_repo_url  prints the repoURL currently in root-app.yaml.
manifest_repo_url() {
  awk '/repoURL:/ {print $2; exit}' "${REPO_ROOT}/root-app.yaml" | tr -d "\"'"
}

# check_repo_url  warns when REPO_URL and the manifests disagree.
check_repo_url() {
  local want="${REPO_URL:-$DEFAULT_REPO_URL}" have
  have="$(manifest_repo_url)"
  if [[ "$want" != "$have" ]]; then
    warn "REPO_URL ($want) differs from root-app.yaml ($have)."
    warn "Run: scripts/set-repo-url.sh $want   then commit and push, before Argo CD can read your fork."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Cluster inventory (clusters/<name>.yaml)
# ---------------------------------------------------------------------------

# _inventory_field FILE KEY  prints a top-level scalar from an inventory file.
_inventory_field() {
  [[ -f "$1" ]] || return 0
  awk -v k="$2" -F': *' '$1 == k { v=$2; gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }' "$1"
}

# set_inventory_server NAME SERVER  updates only the server: line (portable: no sed -i).
set_inventory_server() {
  local name="$1" server="$2" file="${REPO_ROOT}/clusters/$1.yaml" tmp
  [[ -f "$file" ]] || die "inventory file not found: $file"
  if is_dry_run; then
    _print_cmd "# set server: ${server} in clusters/${name}.yaml"
    return 0
  fi
  tmp="$(mktemp)"
  awk -v s="$server" '/^server:/ { print "server: " s; next } { print }' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
  ok "clusters/${name}.yaml -> server: ${server}"
}

# write_inventory NAME SERVER ENVIRONMENT UPGRADE_WAVE REGION [LOKI_ENDPOINT]
# Writes a complete inventory file. Keeps an existing lokiEndpoint if none given.
write_inventory() {
  local name="$1" server="$2" env="$3" wave="$4" region="$5" loki="${6:-}"
  local file="${REPO_ROOT}/clusters/${name}.yaml"
  if [[ -z "$loki" ]]; then loki="$(_inventory_field "$file" lokiEndpoint)"; fi
  loki="${loki:-http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push}"
  local body
  body="$(printf 'name: %s\nserver: %s\nenvironment: %s\nupgradeWave: "%s"\nregion: %s\nlokiEndpoint: %s\n' \
    "$name" "$server" "$env" "$wave" "$region" "$loki")"
  if is_dry_run; then
    _print_cmd "# write clusters/${name}.yaml"
    printf '%s\n' "$body" | sed 's/^/    | /' >&2
    return 0
  fi
  printf '%s\n' "$body" > "$file"
  ok "wrote clusters/${name}.yaml (server: ${server})"
}

# ---------------------------------------------------------------------------
# Flag parsing shared by up.sh / down.sh
# ---------------------------------------------------------------------------
# Sets DRY_RUN, ASSUME_YES, ENV_FILE, NO_GIT_CHECK, SKIP_ROOT_APP, ARGOCD_PROFILE.
# Unknown flags fail. Callers pass a usage function name.
parse_common_flags() {
  local usage_fn="$1"; shift
  ENV_FILE="${ENV_FILE:-}"; NO_GIT_CHECK="${NO_GIT_CHECK:-0}"; SKIP_ROOT_APP="${SKIP_ROOT_APP:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)       DRY_RUN=1 ;;
      -y|--yes)        ASSUME_YES=1 ;;
      --env-file)      [[ $# -ge 2 ]] || die "--env-file needs a path"; ENV_FILE="$2"; shift ;;
      --env-file=*)    ENV_FILE="${1#*=}" ;;
      --no-git-check)  NO_GIT_CHECK=1 ;;
      --skip-root-app) SKIP_ROOT_APP=1 ;;
      --profile)       [[ $# -ge 2 ]] || die "--profile needs local|prod"; ARGOCD_PROFILE="$2"; shift ;;
      --profile=*)     ARGOCD_PROFILE="${1#*=}" ;;
      -h|--help)       "$usage_fn"; exit 0 ;;
      *)               err "unknown flag: $1"; "$usage_fn"; exit 2 ;;
    esac
    shift
  done
  export DRY_RUN ASSUME_YES ARGOCD_PROFILE
  if is_dry_run; then warn "dry-run: mutating commands are printed, not executed"; fi
}
