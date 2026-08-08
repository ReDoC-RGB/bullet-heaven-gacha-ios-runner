#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preflight="${root}/scripts/require-xcode26.sh"

bash -n "${preflight}"
grep -Fq 'runs-on: macos-26' "${root}/.github/workflows/build-ios-adhoc.yml"
grep -Fq 'runs-on: macos-26' "${root}/.github/workflows/upload-ios-testflight.yml"
grep -Fq 'require-xcode26.sh' "${root}/scripts/build-sign-return.sh"
grep -Fq 'require-xcode26.sh' "${root}/scripts/build-upload-testflight.sh"
grep -Fq 'show-sdk-version' "${preflight}"
grep -Fq 'xcodebuild -version' "${preflight}"
grep -Fq '"${xcode_major}" -ge 26' "${preflight}"
grep -Fq '"${sdk_major}" -ge 26' "${preflight}"

printf 'PASS both iOS workflows require macOS 26, Xcode 26, and iPhoneOS SDK 26\n'
