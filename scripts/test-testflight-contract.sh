#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/scripts/build-upload-testflight.sh"
workflow="${root}/.github/workflows/upload-ios-testflight.yml"
bash -n "${script}"
bash -n "${root}/scripts/cleanup-testflight.sh"
grep -Fq "method':'app-store-connect'" "${script}"
grep -Fq -- "--validate-app" "${script}"
grep -Fq -- "--upload-app" "${script}"
grep -Fq "beta-reports-active" "${script}"
grep -Fq "ProvisionedDevices' not in profile" "${script}"
grep -Fq "manageAppVersionAndBuildNumber':False" "${script}"
grep -Fq "RIVETKIND_ASC_PRIVATE_KEY_B64" "${workflow}"
grep -Fq "cleanup-testflight.sh" "${workflow}"
printf 'PASS TestFlight workflow contract\n'
