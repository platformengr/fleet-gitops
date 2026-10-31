#!/usr/bin/env bash
# scripts/trace.sh: follow a change from Git to the clusters.
#
# Usage: scripts/trace.sh [COMMIT] [--context CTX] [--selector LABELS]
#   scripts/trace.sh                               latest commit on origin/main
#   scripts/trace.sh 3f2a9c1 --selector fleet.gitops/product=checkout
#
# For every Argo CD Application on the hub: the revision it last synced, whether
# that revision already contains COMMIT (reconciled) or not yet (pending), and
# its sync and health status. This is the last step of the change journey:
#   issue -> pull request -> checks -> approval -> merge -> reconciled -> healthy
set -euo pipefail

CTX="kind-platform" SELECTOR="" COMMIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CTX="$2"; shift ;;
    --selector|-l) SELECTOR="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) COMMIT="$1" ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
git fetch -q origin main 2>/dev/null || true
COMMIT="$(git rev-parse "${COMMIT:-origin/main}")"
printf 'Commit %s: %s\n' "${COMMIT:0:9}" "$(git log -1 --format='%s (%an, %ar)' "$COMMIT")"
printf 'Hub context: %s\n\n' "$CTX"

kubectl --context "$CTX" -n argocd get applications ${SELECTOR:+-l "$SELECTOR"} -o json \
  | python3 -c '
import json, subprocess, sys
commit = sys.argv[1]
apps = json.load(sys.stdin)["items"]
def contains(rev):
    if not rev:
        return False
    if rev == commit:
        return True
    # A sync of a later commit includes this one.
    return subprocess.run(["git", "merge-base", "--is-ancestor", commit, rev],
                          capture_output=True).returncode == 0
rows = []
for a in sorted(apps, key=lambda a: a["metadata"]["name"]):
    st = a.get("status", {})
    rev = st.get("sync", {}).get("revision", "") or ""
    if len(rev) == 40 and all(c in "0123456789abcdef" for c in rev):
        state = "reconciled" if contains(rev) else "pending"
    else:
        state = "n/a (Helm chart " + (rev or "?") + ")"
    rows.append((a["metadata"]["name"], rev[:9] or "-", state,
                 st.get("sync", {}).get("status", "-"), st.get("health", {}).get("status", "-"),
                 (st.get("operationState", {}) or {}).get("finishedAt", "-")))
w = [max(len(r[i]) for r in rows + [("APPLICATION", "REVISION", "THIS COMMIT", "SYNC", "HEALTH", "SYNCED AT")]) for i in range(6)]
for r in [("APPLICATION", "REVISION", "THIS COMMIT", "SYNC", "HEALTH", "SYNCED AT")] + rows:
    print("  ".join(c.ljust(w[i]) for i, c in enumerate(r)))
' "$COMMIT"
