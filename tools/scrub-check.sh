#!/usr/bin/env bash
#
# Fails if anything that looks like an environment-specific identifier has been
# committed. Run by CI on every push, and worth running before you commit.
#
#   ./tools/scrub-check.sh
#
# The check is deliberately pattern-based rather than a list of known-bad values:
# a public repository must not contain the very identifiers it is trying to keep
# out. It looks for classes of identifier, not specific ones.
#
# Genuine exceptions (vendor product GUIDs and the like) go in
# tools/scrub-allow.txt, one fixed string per line.
#
# Written for bash 3.2 so it runs on stock macOS as well as CI.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ALLOW="tools/scrub-allow.txt"
findings=0

FILELIST="$(mktemp)"
trap 'rm -f "$FILELIST"' EXIT

# Only inspect files that are (or would be) tracked, so ignored artefacts such
# as logs/ and a local config.env never trip the check.
if git rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git ls-files)" ]; then
  git ls-files > "$FILELIST"
else
  find . -type f \
    -not -path './.git/*' -not -path './logs/*' -not -path './test-results/*' \
    -not -name 'config.env' -not -name 'config.env.bak' \
    | sed 's|^\./||' > "$FILELIST"
fi

file_count="$(wc -l < "$FILELIST" | tr -d ' ')"

# A scan of nothing must never look like a pass.
if [ "$file_count" -eq 0 ]; then
  echo "FAIL: no files to scan - the file list is empty, so this proves nothing." >&2
  exit 2
fi

allow_args=()
if [ -f "$ALLOW" ]; then
  ALLOWTMP="$(mktemp)"
  trap 'rm -f "$FILELIST" "$ALLOWTMP"' EXIT
  grep -v '^[[:space:]]*#' "$ALLOW" | grep -v '^[[:space:]]*$' > "$ALLOWTMP" || true
  if [ -s "$ALLOWTMP" ]; then
    allow_args=(-v -F -f "$ALLOWTMP")
  fi
fi

report() {
  label="$1"
  pattern="$2"
  hits="$(grep -InE "$pattern" $(cat "$FILELIST" | tr '\n' ' ') 2>/dev/null \
          | grep -v '^tools/scrub-check.sh:' \
          | grep -v "^${ALLOW}:" || true)"
  if [ -n "$hits" ] && [ "${#allow_args[@]}" -gt 0 ]; then
    hits="$(printf '%s\n' "$hits" | grep "${allow_args[@]}" || true)"
  fi

  if [ -n "$hits" ]; then
    echo "FAIL: $label"
    printf '%s\n' "$hits" | sed 's/^/    /'
    echo
    findings=$((findings + 1))
  else
    echo "ok:   no $label"
  fi
}

echo "Scrubbing $file_count files for identifiers"
echo

# Subscription IDs, tenant IDs, object IDs, and anything else GUID-shaped.
report "GUIDs (subscription / tenant / object IDs)" \
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# Fully-qualified Azure resource IDs embed a subscription GUID.
report "Azure resource IDs" '/subscriptions/[0-9a-fA-F-]{8,}'

# RFC1918 addresses - internal host targeting.
report "private IPv4 addresses" \
  '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'

# Email addresses - usernames and org domains.
report "email addresses" \
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(edu|com|org|net|gov|io|ac\.[a-z]{2})'

# Credential-shaped assignments. The tooling relies on `az login` and should
# never carry a secret of its own.
report "credential-shaped assignments" \
  '(password|passwd|secret|client_secret|api_?key|access_?token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+_-]{8,}'

echo
if [ "$findings" -ne 0 ]; then
  echo "$findings identifier class(es) found - do not publish until these are removed."
  echo "If a match is a genuine false positive (a vendor product GUID, say),"
  echo "add the exact string to $ALLOW with a comment explaining why."
  exit 1
fi

echo "Clean: no environment-specific identifiers found across $file_count files."
exit 0
