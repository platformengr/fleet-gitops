#!/usr/bin/env bash
# scripts/set-repo-url.sh: point the fleet at your own repository.
#
# Usage: scripts/set-repo-url.sh <git-url> [--codeowners <@user-or-@org/team>]
#   e.g. scripts/set-repo-url.sh https://github.com/alice/fleet-gitops.git --codeowners @alice
#
# Argo CD reads Git, so every manifest that names the fleet repo must name
# YOURS. This rewrites the current repo URL (taken from root-app.yaml), with or
# without .git, in:
#   root-app.yaml, applicationsets/*.yaml, products/*/product.yaml
# With --codeowners it also replaces every @platformengr/<team> owner in
# .github/CODEOWNERS (on a personal account there are no teams: use @you).
# Helm chart repositories are never touched. Portable: no `sed -i`.
set -euo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

NEW_URL="" CODEOWNER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --codeowners) [[ $# -ge 2 ]] || { usage; exit 2; }; CODEOWNER="$2"; shift ;;
    -*) echo "error: unknown flag $1" >&2; usage; exit 2 ;;
    *) [[ -z "$NEW_URL" ]] || { usage; exit 2; }; NEW_URL="$1" ;;
  esac
  shift
done
[[ -n "$NEW_URL" ]] || { usage; exit 2; }
case "$NEW_URL" in
  https://*|git@*|ssh://*) ;;
  *) echo "error: '$NEW_URL' does not look like a Git URL" >&2; exit 2 ;;
esac
if [[ -n "$CODEOWNER" && "$CODEOWNER" != @* ]]; then
  echo "error: --codeowners takes a GitHub handle such as @alice or @my-org/platform-team" >&2; exit 2
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OLD_URL="$(awk '/repoURL:/ {print $2; exit}' root-app.yaml | tr -d "\"'")"
OLD_BASE="${OLD_URL%.git}"
NEW_BASE="${NEW_URL%.git}"

ere_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|#/]/\\&/g'; }
repl_escape() { printf '%s' "$1" | sed -e 's/[\&#]/\\&/g'; }

rewrite() { # rewrite FILE SED_EXPR...
  local f="$1" tmp n; shift
  tmp="$(mktemp)"
  sed -E "$@" "$f" > "$tmp"
  n="$(diff "$f" "$tmp" | grep -c '^>' || true)"
  if [[ "$n" -gt 0 ]]; then
    cat "$tmp" > "$f"
    printf '  %-48s %s line(s)\n' "$f" "$n"
  fi
  rm -f "$tmp"
}

echo "Repo URL: ${OLD_URL} -> ${NEW_URL}"
if [[ "$OLD_BASE" != "$NEW_BASE" ]]; then
  # https://host/owner/repo.git -> new .git URL; https://host/owner/repo/... links -> new base
  for f in root-app.yaml applicationsets/*.yaml products/*/product.yaml; do
    [[ -f "$f" ]] || continue
    rewrite "$f" \
      -e "s#$(ere_escape "$OLD_BASE")\\.git#$(repl_escape "$NEW_BASE").git#g" \
      -e "s#$(ere_escape "$OLD_BASE")([/'\" ]|\$)#$(repl_escape "$NEW_BASE")\\1#g"
  done
else
  echo "  already pointing at ${NEW_URL}"
fi

if [[ -n "$CODEOWNER" ]]; then
  echo "CODEOWNERS: @platformengr/* -> ${CODEOWNER}"
  rewrite .github/CODEOWNERS -e "s#@platformengr/[A-Za-z0-9_-]+#$(repl_escape "$CODEOWNER")#g" \
    -e "s#(${CODEOWNER//\//\\/})( ${CODEOWNER//\//\\/})+#\\1#g"
fi

cat <<EOF

Review, then commit and push (Argo CD only sees what is in Git):
  git diff
  git commit -am "Point the fleet at ${NEW_BASE}" && git push
EOF
