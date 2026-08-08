#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
ROOT="${RUNNER_TEMP}/bhg-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
KEY_RECORD="${ROOT}/installed-api-key-path.txt"
if [[ -f "${KEY_RECORD}" ]]; then
  KEY_PATH="$(cat "${KEY_RECORD}")"
  case "${KEY_PATH}" in
    "${HOME}/.appstoreconnect/private_keys/AuthKey_"*.p8) rm -f -- "${KEY_PATH}" ;;
    *) printf 'refusing unexpected App Store Connect key cleanup path\n' >&2 ;;
  esac
fi
bash "${GITHUB_WORKSPACE}/scripts/cleanup.sh"
