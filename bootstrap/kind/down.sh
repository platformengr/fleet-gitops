#!/usr/bin/env bash
# bootstrap/kind/down.sh: delete the local kind fleet.
# Usage: bootstrap/kind/down.sh [--yes] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: bootstrap/kind/down.sh [--yes] [--dry-run]
Deletes the kind clusters platform, dev and prod (HUB_NAME overrides "platform").
USAGE
}
parse_common_flags usage "$@"

HUB_NAME="${HUB_NAME:-platform}"
CLUSTERS=(prod dev "$HUB_NAME")

require_cmd kind
confirm "Delete kind clusters: ${CLUSTERS[*]}?" || die "aborted"

for c in "${CLUSTERS[@]}"; do
  if is_dry_run || kind get clusters 2>/dev/null | grep -qx "$c"; then
    run kind delete cluster --name "$c"
  else
    info "kind cluster '$c' not found, skipping"
  fi
done
ok "kind fleet removed. clusters/*.yaml still hold the old IPs; up.sh rewrites them."
