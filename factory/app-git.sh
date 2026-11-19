#!/usr/bin/env bash
# Makes the next `git push` in this checkout use the GitHub App token ($FACTORY_APP_TOKEN), so the push
# starts the repository's own workflows (a push made with GITHUB_TOKEN does not; docs/permissions.md).
# actions/checkout leaves an http extraheader with GITHUB_TOKEN in the local git config; this replaces
# it. Without FACTORY_APP_TOKEN it warns and leaves GITHUB_TOKEN in place.
set -euo pipefail
if [ -z "${FACTORY_APP_TOKEN:-}" ]; then
  echo "::warning::FACTORY_APP_TOKEN is not set; pushing with GITHUB_TOKEN (CI will not start on this push)"
  exit 0
fi
echo "::add-mask::$FACTORY_APP_TOKEN"
auth=$(printf 'x-access-token:%s' "$FACTORY_APP_TOKEN" | base64 | tr -d '\n')
git config --local --unset-all 'http.https://github.com/.extraheader' 2>/dev/null || true
git config --local 'http.https://github.com/.extraheader' "AUTHORIZATION: basic $auth"
