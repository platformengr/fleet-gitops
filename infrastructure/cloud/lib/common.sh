# shellcheck shell=bash
# infrastructure/cloud/lib/common.sh: shared helpers for the cloud bootstrap scripts.
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
BOOTSTRAP_VERSION="$(git -C "${BOOTSTRAP_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
export BOOTSTRAP_LIB_DIR BOOTSTRAP_DIR BOOTSTRAP_VERSION

# These scripts live inside the fleet repo (infrastructure/cloud/), so the
# fleet repo defaults to two levels up. --fleet-dir / FLEET_REPO_DIR override it.
FLEET_DIR=""
DEFAULT_FLEET_DIR="$(cd "${BOOTSTRAP_DIR}/../.." && pwd)"
INIT_FLEET_DIR="${INIT_FLEET_DIR:-0}"   # 1 = allow an empty directory 
# Where the course's reference fleet lives (shown in messages only).
REFERENCE_REPO_URL="https://github.com/platformengr/fleet-gitops.git"

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
  info "loading settings from ${file#"${BOOTSTRAP_DIR}"/}"
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

# manifest_repo_url  prints the repoURL currently in FLEET_DIR/root-app.yaml
# (empty when the file does not exist yet).
manifest_repo_url() {
  [[ -f "${FLEET_DIR}/root-app.yaml" ]] || return 0
  awk '/repoURL:/ {print $2; exit}' "${FLEET_DIR}/root-app.yaml" | tr -d "\"'"
}

# fleet_origin  prints the fleet dir's git origin URL (empty if none).
fleet_origin() {
  git -C "$FLEET_DIR" remote get-url origin 2>/dev/null || true
}

# _norm_url URL  normalises host/owner/repo (no scheme, ssh form, .git, case).
_norm_url() {
  printf '%s' "$1" | sed -E 's#^(https?://|git@)##; s#:#/#; s#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]'
}

# check_repo_url  compares root-app.yaml's repoURL with the fleet dir's git
# origin (or REPO_URL when you set it). Returns 1 and explains on a mismatch.
check_repo_url() {
  local have origin want
  have="$(manifest_repo_url)"
  if [[ -z "$have" ]]; then
    info "no root-app.yaml in ${FLEET_DIR} yet, skipping the repoURL check"
    return 0
  fi
  origin="$(fleet_origin)"
  want="${REPO_URL:-$origin}"
  if [[ -z "$want" ]]; then
    warn "${FLEET_DIR} has no 'origin' remote; Argo CD will read ${have}"
    return 0
  fi
  if [[ "$(_norm_url "$want")" != "$(_norm_url "$have")" ]]; then
    warn "root-app.yaml points at ${have} but ${REPO_URL:+REPO_URL is }${REPO_URL:-your origin is }${want}."
    warn "Argo CD reads Git, not your laptop. Point the manifests at your repo:"
    warn "  (cd ${FLEET_DIR} && scripts/set-repo-url.sh ${want}) then commit and push."
    return 1
  fi
  ok "manifests point at your origin (${want})"
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

# set_inventory_server NAME SERVER [ENVIRONMENT WAVE REGION]
# Updates only the server: line of FLEET_DIR/clusters/NAME.yaml (portable: no
# sed -i). If the file does not exist yet , creates it with the
# standard fields instead.
set_inventory_server() {
  local name="$1" server="$2" env="${3:-$1}" wave="${4:-0}" region="${5:-local}"
  local file="${FLEET_DIR}/clusters/${name}.yaml" tmp
  if [[ ! -f "$file" ]]; then
    info "clusters/${name}.yaml does not exist yet; creating it"
    write_inventory "$name" "$server" "$env" "$wave" "$region"
    return 0
  fi
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
# Writes a complete inventory file (creating clusters/ if needed). Keeps an
# existing lokiEndpoint if none given.
write_inventory() {
  local name="$1" server="$2" env="$3" wave="$4" region="$5" loki="${6:-}"
  local file="${FLEET_DIR}/clusters/${name}.yaml"
  if [[ -z "$loki" ]]; then loki="$(_inventory_field "$file" lokiEndpoint)"; fi
  loki="${loki:-http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push}"
  local body
  body="$(printf 'name: %s\nprovider: %s\nserver: %s\nenvironment: %s\nupgradeWave: "%s"\nregion: %s\nlokiEndpoint: %s\n' \
    "$name" "${CLOUD_PROVIDER:-external}" "$server" "$env" "$wave" "$region" "$loki")"
  if is_dry_run; then
    _print_cmd "# write clusters/${name}.yaml"
    printf '%s\n' "$body" | sed 's/^/    | /' >&2
    return 0
  fi
  mkdir -p "${FLEET_DIR}/clusters"
  printf '%s\n' "$body" > "$file"
  ok "wrote clusters/${name}.yaml (server: ${server})"
}

# ---------------------------------------------------------------------------
# Fleet repo location
# ---------------------------------------------------------------------------

# fleet_dir_help  prints the shared flag lines for usage() functions.
fleet_dir_help() {
  cat <<'HELP'
  --fleet-dir DIR   your fleet repo (default: $FLEET_REPO_DIR, else the repo
                    these scripts live in)
  --init-fleet-dir  allow a fleet dir without root-app.yaml
  --version         print the commit these scripts come from
HELP
}

_fleet_dir_error() {
  err "Could not find your fleet repo. ${1:-}"
  cat >&2 <<MSG

The scripts expect to run from a fleet repo (a directory with root-app.yaml),
normally the one they live in. Pass --fleet-dir DIR to use another checkout.
Reference fleet: ${REFERENCE_REPO_URL%.git}
MSG
  exit 2
}

# resolve_fleet_dir  sets FLEET_DIR (absolute). Down scripts set
# FLEET_DIR_OPTIONAL=1 to tolerate a missing fleet dir instead of failing.
resolve_fleet_dir() {
  local optional="${FLEET_DIR_OPTIONAL:-0}" dir="${FLEET_DIR_ARG:-${FLEET_REPO_DIR:-}}"
  if [[ -z "$dir" ]]; then
    if [[ -f "${PWD}/root-app.yaml" || "${INIT_FLEET_DIR}" == "1" ]]; then dir="$PWD"; else dir="$DEFAULT_FLEET_DIR"; fi
  fi
  if [[ -z "$dir" ]]; then
    if [[ "$optional" == "1" ]]; then FLEET_DIR="$PWD"; export FLEET_DIR; return 0; fi
    _fleet_dir_error "No --fleet-dir given and ${PWD} has no root-app.yaml."
  fi
  dir="${dir/#\~/$HOME}"
  if [[ ! -d "$dir" ]]; then
    if [[ "${INIT_FLEET_DIR}" == "1" ]]; then
      case "$dir" in /*) ;; *) dir="${PWD}/${dir}" ;; esac
      if is_dry_run; then info "would create ${dir}"; else mkdir -p "$dir"; fi
    elif [[ "$optional" == "1" ]]; then
      FLEET_DIR="$dir"; export FLEET_DIR; return 0
    else
      _fleet_dir_error "Directory not found: ${dir}"
    fi
  fi
  if [[ -d "$dir" ]]; then dir="$(cd "$dir" && pwd)"; fi
  if [[ ! -f "${dir}/root-app.yaml" && "${INIT_FLEET_DIR}" != "1" && "$optional" != "1" ]]; then
    _fleet_dir_error "${dir} has no root-app.yaml (add --init-fleet-dir if this is a new, empty repo)."
  fi
  FLEET_DIR="$dir"
  export FLEET_DIR
  if [[ ! -f "${FLEET_DIR}/root-app.yaml" && "$optional" != "1" ]]; then
    warn "${FLEET_DIR}/root-app.yaml does not exist yet: it will not be applied."
  fi
}

# ---------------------------------------------------------------------------
# Flag parsing shared by up.sh / down.sh
# ---------------------------------------------------------------------------
# Sets DRY_RUN, ASSUME_YES, ENV_FILE, NO_GIT_CHECK, SKIP_ROOT_APP, ARGOCD_PROFILE,
# FLEET_DIR. Unknown flags fail. Callers pass a usage function name.
parse_common_flags() {
  local usage_fn="$1"; shift
  ENV_FILE="${ENV_FILE:-}"; NO_GIT_CHECK="${NO_GIT_CHECK:-0}"; SKIP_ROOT_APP="${SKIP_ROOT_APP:-0}"
  FLEET_DIR_ARG=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)        DRY_RUN=1 ;;
      -y|--yes)         ASSUME_YES=1 ;;
      --env-file)       [[ $# -ge 2 ]] || die "--env-file needs a path"; ENV_FILE="$2"; shift ;;
      --env-file=*)     ENV_FILE="${1#*=}" ;;
      --fleet-dir)      [[ $# -ge 2 ]] || die "--fleet-dir needs a path"; FLEET_DIR_ARG="$2"; shift ;;
      --fleet-dir=*)    FLEET_DIR_ARG="${1#*=}" ;;
      --init-fleet-dir) INIT_FLEET_DIR=1 ;;
      --no-git-check)   NO_GIT_CHECK=1 ;;
      --skip-root-app)  SKIP_ROOT_APP=1 ;;
      --profile)        [[ $# -ge 2 ]] || die "--profile needs local|prod"; ARGOCD_PROFILE="$2"; shift ;;
      --profile=*)      ARGOCD_PROFILE="${1#*=}" ;;
      --version)        echo "fleet cloud scripts ${BOOTSTRAP_VERSION}"; exit 0 ;;
      -h|--help)        echo "fleet cloud scripts ${BOOTSTRAP_VERSION}"; "$usage_fn"; exit 0 ;;
      *)                err "unknown flag: $1"; "$usage_fn"; exit 2 ;;
    esac
    shift
  done
  export DRY_RUN ASSUME_YES ARGOCD_PROFILE
  info "fleet cloud scripts ${BOOTSTRAP_VERSION}"
  if is_dry_run; then warn "dry-run: mutating commands are printed, not executed"; fi
  resolve_fleet_dir
  info "fleet dir: ${FLEET_DIR}"
}
