#!/usr/bin/env bash
# Makes the next `git push` in this checkout use the GitHub App token ($FACTORY_APP_TOKEN), so the push
# starts the repository's own workflows (a push made with GITHUB_TOKEN does not; docs/permissions.md).
# actions/checkout leaves an http extraheader with GITHUB_TOKEN in the local git config; this replaces
# it.
#
# app.enabled (FACTORY_APP_ENABLED, default true, docs/config.md): when true, a missing FACTORY_APP_TOKEN
# is an error (exit 1): the App token step failed or its secrets are not set, and a GITHUB_TOKEN push
# would silently skip CI. When false, the kit runs without an App: it warns and leaves GITHUB_TOKEN.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
enabled=${FACTORY_APP_ENABLED:-$(bash "$here/config.sh" --default app.enabled)}
if [ "$enabled" = false ]; then
  echo "::warning::app.enabled is false; pushing with GITHUB_TOKEN (CI will not start on this push)"
  exit 0
fi
if [ -z "${FACTORY_APP_TOKEN:-}" ]; then
  echo "::error::app.enabled is true but FACTORY_APP_TOKEN is not set: set the FACTORY_APP_ID and FACTORY_APP_PRIVATE_KEY secrets, or set app.enabled: false in factory.yml"
  exit 1
fi
echo "::add-mask::$FACTORY_APP_TOKEN"
auth=$(printf 'x-access-token:%s' "$FACTORY_APP_TOKEN" | base64 | tr -d '\n')
git config --local --unset-all 'http.https://github.com/.extraheader' 2>/dev/null || true
git config --local 'http.https://github.com/.extraheader' "AUTHORIZATION: basic $auth"
