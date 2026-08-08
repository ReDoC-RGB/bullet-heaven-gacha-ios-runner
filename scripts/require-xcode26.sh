#!/usr/bin/env bash
set -euo pipefail

xcode_version="$(xcodebuild -version | awk 'NR==1 {print $2}')"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
xcode_major="${xcode_version%%.*}"
sdk_major="${sdk_version%%.*}"

[[ "${xcode_major}" =~ ^[0-9]+$ && "${sdk_major}" =~ ^[0-9]+$ ]] || {
  printf 'unable to determine Xcode/iPhoneOS SDK versions\n' >&2
  exit 2
}
[[ "${xcode_major}" -ge 26 && "${sdk_major}" -ge 26 ]] || {
  printf 'Xcode 26 with iPhoneOS SDK 26 or newer is required; found Xcode %s / SDK %s\n' "${xcode_version}" "${sdk_version}" >&2
  exit 2
}

printf 'PASS Xcode %s / iPhoneOS SDK %s\n' "${xcode_version}" "${sdk_version}"
