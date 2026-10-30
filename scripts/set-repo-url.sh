#!/usr/bin/env bash
# scripts/set-repo-url.sh: point Argo CD manifests at your fork.
#
# Usage: scripts/set-repo-url.sh <git-url>
#   e.g. scripts/set-repo-url.sh https://github.com/my-org/fleet-gitops.git
#
# Rewrites the fleet-gitops repo URL in:
#   root-app.yaml                        (repoURL)
#   applicationsets/*.yaml               (repoURL, incl. git generators)
#   applicationsets/fleet-platform-project.yaml (AppProject sourceRepos entry)
# Matches any https://<host>/<owner>/fleet-gitops(.git) or git@<host>:<owner>/fleet-gitops(.git)
# URL, plus the exact URL currently in root-app.yaml (so renamed forks work).
# Helm chart repositories are never touched. Portable: no `sed -i`.
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

[[ $# -eq 1 ]] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

NEW_URL="$1"
case "$NEW_URL" in
  https://*|http://*|git@*|ssh://*) ;;
  *) echo "error: '$NEW_URL' does not look like a Git URL" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILES=(root-app.yaml applicationsets/*.yaml)

# Current URL in root-app.yaml (first repoURL).
OLD_URL="$(awk '/repoURL:/ {print $2; exit}' root-app.yaml | tr -d "\"'")"

# Escape a string for use as a literal in a sed ERE / replacement.
ere_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|#]/\\&/g'; }
repl_escape() { printf '%s' "$1" | sed -e 's/[\&#]/\\&/g'; }

NEW_REPL="$(repl_escape "$NEW_URL")"
OLD_ERE="$(ere_escape "$OLD_URL")"
# Generic fleet-gitops pattern; the trailing group keeps the delimiter after the URL.
GENERIC_ERE="(https?://|ssh://|git@)[^[:space:]'\"]+/fleet-gitops(\\.git)?"

# Only lines that are a repoURL or a list item (AppProject sourceRepos).
LINE_FILTER="(repoURL:|^[[:space:]]*-[[:space:]])"

changed_total=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  tmp="$(mktemp)"
  sed -E \
    -e "/${LINE_FILTER}/ s#${OLD_ERE}([[:space:]'\"]|\$)#${NEW_REPL}\\1#g" \
    -e "/${LINE_FILTER}/ s#${GENERIC_ERE}([[:space:]'\"]|\$)#${NEW_REPL}\\3#g" \
    "$f" > "$tmp"
  n="$(diff "$f" "$tmp" | grep -c '^>' || true)"
  if [[ "$n" -gt 0 ]]; then
    cat "$tmp" > "$f"
    printf '  %-48s %s line(s) changed\n' "$f" "$n"
    changed_total=$((changed_total + n))
  fi
  rm -f "$tmp"
done

if [[ "$changed_total" -eq 0 ]]; then
  echo "No changes: manifests already point at ${NEW_URL}."
  exit 0
fi

echo
echo "Rewrote ${changed_total} line(s): ${OLD_URL} -> ${NEW_URL}"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git --no-pager diff --stat -- "${FILES[@]}" || true
fi
cat <<EOF

Argo CD reads Git, so commit and push before applying root-app.yaml:
  git add root-app.yaml applicationsets/
  git commit -m "Point Argo CD at ${NEW_URL}"
  git push
EOF
