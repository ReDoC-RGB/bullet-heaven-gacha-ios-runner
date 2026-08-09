#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

required=(
  RIVETKIND_APPLE_P12_B64 RIVETKIND_APPLE_P12_PASSWORD RIVETKIND_APPLE_PROFILE_B64
  RIVETKIND_ASC_KEY_ID RIVETKIND_ASC_ISSUER_ID RIVETKIND_ASC_PRIVATE_KEY_B64
  BHG_EXPORT_SHA256 BHG_EXPORT_MANIFEST_SHA256 BHG_EXPORT_INVENTORY_COUNT
  BHG_EXPORT_FRAMED_TREE_SHA256 BHG_CANDIDATE_COMMIT BHG_CANDIDATE_TREE
  BHG_EXPORT_TOKEN BHG_EXPORT_URL BHG_MANIFEST_URL
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'required protected input is missing\n' >&2; exit 2; }
done

readonly EXPECTED_TEAM_ID="7D88UFWRTZ"
readonly EXPECTED_BUNDLE="com.wellmadesystems.bulletheavengacha.audition"
readonly EXPECTED_VERSION="1.39"
readonly EXPECTED_BUILD="40"
readonly EXPECTED_PROFILE_NAME="Rivetkind TestFlight App Store v1"
readonly EXPECTED_PROFILE_UUID="71a04e62-08f5-4602-a0ba-c4a493ec9578"
readonly EXPECTED_PROFILE_SHA="74e871f8c0230508983303e80f07d5517cf4a61eec245ca4bc233a524e0ff371"
readonly EXPECTED_CERT_SHA="3870fd7a823c074b79fdf2862c3a57b5432bcce43b963e759f81ea3789e1a107"

ROOT="${RUNNER_TEMP}/bhg-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
RESULT_DIR="${RUNNER_TEMP}/rivetkind-testflight-result-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
DIAGNOSTIC_DIR="${RUNNER_TEMP}/bhg-diagnostic-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
KEYCHAIN="${ROOT}/rivetkind-testflight.keychain-db"
EXPORT_ARCHIVE="${ROOT}/rivetkind-xcode-export.tar.gz"
EXPORT_MANIFEST="${ROOT}/rivetkind-xcode-export-manifest.json"
mkdir -p "${ROOT}"
cleanup() { bash "${GITHUB_WORKSPACE}/scripts/cleanup-testflight.sh"; }
trap cleanup EXIT

bash "${GITHUB_WORKSPACE}/scripts/require-xcode26.sh"

PROTECTED_VALUES_FILE="${ROOT}/protected-values.nul"
python3 - "${PROTECTED_VALUES_FILE}" <<'PY'
import os,re,sys
protected_name=re.compile(r'(TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTHORIZATION|_URL$|^URL$|P12|PROFILE.*B64|_B64$|PRIVATE_KEY|API_KEY|ISSUER)',re.I)
values=[value.encode() for name,value in os.environ.items() if value and protected_name.search(name)]
open(sys.argv[1],'wb').write(b'\0'.join(values)+b'\0')
PY
chmod 0600 "${PROTECTED_VALUES_FILE}"

python3 - "${GITHUB_WORKSPACE}/release-authority.json" <<'PY'
import json,os,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
assert set(x)=={'schema','archiveSha256','manifestSha256','manifestByteLength','inventoryCount','framedTreeSha256','candidateCommit','candidateTree'}
expected={
  'archiveSha256':os.environ['BHG_EXPORT_SHA256'],
  'manifestSha256':os.environ['BHG_EXPORT_MANIFEST_SHA256'],
  'inventoryCount':int(os.environ['BHG_EXPORT_INVENTORY_COUNT']),
  'framedTreeSha256':os.environ['BHG_EXPORT_FRAMED_TREE_SHA256'],
  'candidateCommit':os.environ['BHG_CANDIDATE_COMMIT'],
  'candidateTree':os.environ['BHG_CANDIDATE_TREE'],
}
assert x['schema']==1 and all(x[k]==v for k,v in expected.items())
PY

curl --fail --silent --show-error --location --proto '=https' \
  --header "Authorization: Bearer ${BHG_EXPORT_TOKEN}" \
  --output "${EXPORT_ARCHIVE}" "${BHG_EXPORT_URL}"
curl --fail --silent --show-error --location --proto '=https' \
  --header "Authorization: Bearer ${BHG_EXPORT_TOKEN}" \
  --output "${EXPORT_MANIFEST}" "${BHG_MANIFEST_URL}"
[[ "$(shasum -a 256 "${EXPORT_ARCHIVE}" | cut -d ' ' -f 1)" == "${BHG_EXPORT_SHA256}" ]] || { printf 'archive authority mismatch\n' >&2; exit 2; }
[[ "$(shasum -a 256 "${EXPORT_MANIFEST}" | cut -d ' ' -f 1)" == "${BHG_EXPORT_MANIFEST_SHA256}" ]] || { printf 'manifest authority mismatch\n' >&2; exit 2; }
python3 "${GITHUB_WORKSPACE}/scripts/verify-public-runner.py" verify-export \
  --archive "${EXPORT_ARCHIVE}" --manifest "${EXPORT_MANIFEST}" --expected-sha "${BHG_EXPORT_SHA256}"
mkdir -p "${ROOT}/payload"
tar -xzf "${EXPORT_ARCHIVE}" -C "${ROOT}/payload" --no-same-owner --no-same-permissions
XCODE_ROOT="${ROOT}/payload/xcode-export"
[[ -d "${XCODE_ROOT}" ]] || { printf 'verified Xcode export root missing\n' >&2; exit 3; }

P12="${ROOT}/distribution.p12"
PROFILE="${ROOT}/rivetkind-appstore.mobileprovision"
python3 - "${P12}" "${PROFILE}" <<'PY'
import base64,os,sys
open(sys.argv[1],'wb').write(base64.b64decode(os.environ['RIVETKIND_APPLE_P12_B64'],validate=True))
open(sys.argv[2],'wb').write(base64.b64decode(os.environ['RIVETKIND_APPLE_PROFILE_B64'],validate=True))
PY
unset RIVETKIND_APPLE_P12_B64 RIVETKIND_APPLE_PROFILE_B64
chmod 0600 "${P12}" "${PROFILE}"

KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings -lut 21600 "${KEYCHAIN}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security import "${P12}" -k "${KEYCHAIN}" -P "${RIVETKIND_APPLE_P12_PASSWORD}" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null
security list-keychains -d user -s "${KEYCHAIN}"

PROFILE_PLIST="${ROOT}/profile.plist"
security cms -D -i "${PROFILE}" > "${PROFILE_PLIST}"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "${PROFILE_PLIST}")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${PROFILE_PLIST}")"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${PROFILE_PLIST}")"
APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${PROFILE_PLIST}")"
PROFILE_FILE_SHA="$(shasum -a 256 "${PROFILE}" | cut -d ' ' -f 1)"
python3 - "${PROFILE_PLIST}" <<'PY'
import plistlib,sys
x=plistlib.load(open(sys.argv[1],'rb')); e=x.get('Entitlements',{})
assert 'ProvisionedDevices' not in x and not x.get('ProvisionsAllDevices')
assert e.get('get-task-allow') is False and e.get('beta-reports-active') is True
PY
[[ "${PROFILE_FILE_SHA}" == "${EXPECTED_PROFILE_SHA}" && "${PROFILE_UUID}" == "${EXPECTED_PROFILE_UUID}" && "${PROFILE_NAME}" == "${EXPECTED_PROFILE_NAME}" && "${TEAM_ID}" == "${EXPECTED_TEAM_ID}" && "${APPLICATION_IDENTIFIER}" == "${EXPECTED_TEAM_ID}.${EXPECTED_BUNDLE}" ]] || { printf 'App Store profile authority mismatch\n' >&2; exit 4; }
PROFILE_DEST="${HOME}/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
mkdir -p "$(dirname "${PROFILE_DEST}")"
install -m 0600 "${PROFILE}" "${PROFILE_DEST}"
printf '%s\n' "${PROFILE_DEST}" > "${ROOT}/installed-profile-path.txt"

P12_CERT_PEM="${ROOT}/distribution-cert.pem"
P12_CERT_DER="${ROOT}/distribution-cert.der"
openssl pkcs12 -in "${P12}" -clcerts -nokeys -passin "pass:${RIVETKIND_APPLE_P12_PASSWORD}" -out "${P12_CERT_PEM}" >/dev/null 2>&1
openssl x509 -in "${P12_CERT_PEM}" -outform DER -out "${P12_CERT_DER}"
P12_CERT_SHA1="$(shasum -a 1 "${P12_CERT_DER}" | cut -d ' ' -f 1 | tr '[:lower:]' '[:upper:]')"
[[ "$(shasum -a 256 "${P12_CERT_DER}" | cut -d ' ' -f 1)" == "${EXPECTED_CERT_SHA}" ]] || { printf 'distribution certificate authority mismatch\n' >&2; exit 5; }
IDENTITY_OUTPUT="$(security find-identity -v -p codesigning "${KEYCHAIN}")"
IDENTITY_COUNT="$(printf '%s\n' "${IDENTITY_OUTPUT}" | "${GITHUB_WORKSPACE}/scripts/count-signing-identities.sh" "${P12_CERT_SHA1}")"
[[ "${IDENTITY_COUNT}" == 1 ]] || { printf 'usable distribution identity mismatch\n' >&2; exit 5; }
unset IDENTITY_OUTPUT RIVETKIND_APPLE_P12_PASSWORD KEYCHAIN_PASSWORD

WORKSPACE_COUNT="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcworkspace' -print | wc -l | tr -d ' ')"
PROJECT_COUNT="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcodeproj' -print | wc -l | tr -d ' ')"
XCODE_CONTAINER_ARGS=()
if [[ "${WORKSPACE_COUNT}" == 1 ]]; then
  WORKSPACE="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcworkspace' -print -quit)"
  XCODE_CONTAINER_ARGS=(-workspace "${WORKSPACE}")
elif [[ "${WORKSPACE_COUNT}" == 0 && "${PROJECT_COUNT}" == 1 ]]; then
  PROJECT="$(find "${XCODE_ROOT}" -maxdepth 1 -type d -name '*.xcodeproj' -print -quit)"
  XCODE_CONTAINER_ARGS=(-project "${PROJECT}")
else
  printf 'expected exactly one Xcode workspace or project\n' >&2
  exit 5
fi

ARCHIVE_PATH="${ROOT}/Rivetkind.xcarchive"
XCODE_LOG="${ROOT}/xcodebuild.log"
set +e
xcodebuild "${XCODE_CONTAINER_ARGS[@]}" -scheme Unity-iPhone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${P12_CERT_SHA1}" \
  OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN}" PROVISIONING_PROFILE_SPECIFIER_APP="${PROFILE_NAME}" archive >"${XCODE_LOG}" 2>&1
XCODEBUILD_STATUS=$?
set -e
if [[ "${XCODEBUILD_STATUS}" -ne 0 ]]; then
  python3 "${GITHUB_WORKSPACE}/scripts/stage-xcode-diagnostic.py" --raw-log "${XCODE_LOG}" \
    --output-dir "${DIAGNOSTIC_DIR}" --exit-status "${XCODEBUILD_STATUS}" --phase archive \
    --protected-values-file "${PROTECTED_VALUES_FILE}" || true
  printf 'Xcode archive failed; sanitized diagnostic staged\n' >&2
  exit 6
fi

EXPORT_OPTIONS="${ROOT}/ExportOptions.plist"
export RIVETKIND_PROFILE_NAME="${PROFILE_NAME}"
python3 - "${EXPORT_OPTIONS}" <<'PY'
import os,plistlib,sys
value={
  'method':'app-store-connect','destination':'export','signingStyle':'manual',
  'teamID':'7D88UFWRTZ','stripSwiftSymbols':True,'uploadSymbols':True,
  'manageAppVersionAndBuildNumber':False,
  'provisioningProfiles':{'com.wellmadesystems.bulletheavengacha.audition':os.environ['RIVETKIND_PROFILE_NAME']},
}
plistlib.dump(value,open(sys.argv[1],'wb'),sort_keys=True)
PY
unset RIVETKIND_PROFILE_NAME
IPA_DIR="${ROOT}/ipa-output"
mkdir -p "${IPA_DIR}"
set +e
xcodebuild -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${IPA_DIR}" -exportOptionsPlist "${EXPORT_OPTIONS}" >>"${XCODE_LOG}" 2>&1
XCODEBUILD_EXPORT_STATUS=$?
set -e
if [[ "${XCODEBUILD_EXPORT_STATUS}" -ne 0 ]]; then
  python3 "${GITHUB_WORKSPACE}/scripts/stage-xcode-diagnostic.py" --raw-log "${XCODE_LOG}" \
    --output-dir "${DIAGNOSTIC_DIR}" --exit-status "${XCODEBUILD_EXPORT_STATUS}" --phase export \
    --protected-values-file "${PROTECTED_VALUES_FILE}" || true
  printf 'Xcode App Store export failed; sanitized diagnostic staged\n' >&2
  exit 7
fi
IPA_COUNT="$(find "${IPA_DIR}" -maxdepth 1 -type f -name '*.ipa' -print | wc -l | tr -d ' ')"
[[ "${IPA_COUNT}" == 1 ]] || { printf 'expected one App Store IPA\n' >&2; exit 8; }
IPA="$(find "${IPA_DIR}" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
python3 "${GITHUB_WORKSPACE}/scripts/verify-public-runner.py" verify-ipa-archive --ipa "${IPA}"

VERIFY_ROOT="${ROOT}/verify-ipa"
mkdir -p "${VERIFY_ROOT}"
unzip -q "${IPA}" -d "${VERIFY_ROOT}"
APP_COUNT="$(find "${VERIFY_ROOT}/Payload" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')"
[[ "${APP_COUNT}" == 1 ]] || { printf 'expected one signed app in IPA\n' >&2; exit 9; }
APP="$(find "${VERIFY_ROOT}/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
codesign --verify --deep --strict --verbose=2 "${APP}"
(
  cd "${ROOT}"
  codesign --display --extract-certificates "${APP}"
)
[[ "$(shasum -a 256 "${ROOT}/codesign0" | cut -d ' ' -f 1)" == "${EXPECTED_CERT_SHA}" ]] || { printf 'app signer certificate mismatch\n' >&2; exit 10; }
python3 - "${APP}/Info.plist" "${APP}/embedded.mobileprovision" "${EXPORT_MANIFEST}" <<'PY'
import hashlib,json,plistlib,subprocess,sys,tempfile
info=plistlib.load(open(sys.argv[1],'rb')); manifest=json.load(open(sys.argv[3],encoding='utf-8'))
assert info['CFBundleIdentifier']=='com.wellmadesystems.bulletheavengacha.audition'
assert info['CFBundleShortVersionString']=='1.39' and str(info['CFBundleVersion'])=='40'
assert info['BHGCandidateCommit']==manifest['candidateCommit'] and info['BHGCandidateTree']==manifest['candidateTree']
profile_bytes=open(sys.argv[2],'rb').read()
assert hashlib.sha256(profile_bytes).hexdigest()=='74e871f8c0230508983303e80f07d5517cf4a61eec245ca4bc233a524e0ff371'
with tempfile.NamedTemporaryFile() as decoded:
 subprocess.run(['security','cms','-D','-i',sys.argv[2]],check=True,stdout=decoded)
 decoded.flush(); profile=plistlib.load(open(decoded.name,'rb'))
e=profile.get('Entitlements',{})
assert profile['UUID']=='71a04e62-08f5-4602-a0ba-c4a493ec9578'
assert profile['TeamIdentifier']==['7D88UFWRTZ']
assert e['application-identifier']=='7D88UFWRTZ.com.wellmadesystems.bulletheavengacha.audition'
assert e.get('get-task-allow') is False and e.get('beta-reports-active') is True
assert 'ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices')
PY
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP}/Info.plist")"
lipo -archs "${APP}/${EXECUTABLE}" | tr ' ' '\n' | grep -Fx arm64 >/dev/null

ASC_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
ASC_KEY_PATH="${ASC_KEY_DIR}/AuthKey_${RIVETKIND_ASC_KEY_ID}.p8"
mkdir -p "${ASC_KEY_DIR}"
python3 - "${ASC_KEY_PATH}" <<'PY'
import base64,os,sys
open(sys.argv[1],'wb').write(base64.b64decode(os.environ['RIVETKIND_ASC_PRIVATE_KEY_B64'],validate=True))
PY
chmod 0600 "${ASC_KEY_PATH}"
printf '%s\n' "${ASC_KEY_PATH}" > "${ROOT}/installed-api-key-path.txt"
unset RIVETKIND_ASC_PRIVATE_KEY_B64

VALIDATE_LOG="${ROOT}/altool-validate.log"
UPLOAD_LOG="${ROOT}/altool-upload.log"
set +e
xcrun altool --validate-app --type ios --file "${IPA}" --apiKey "${RIVETKIND_ASC_KEY_ID}" --apiIssuer "${RIVETKIND_ASC_ISSUER_ID}" --output-format json >"${VALIDATE_LOG}" 2>&1
VALIDATE_STATUS=$?
set -e
if [[ "${VALIDATE_STATUS}" -ne 0 ]]; then
  python3 "${GITHUB_WORKSPACE}/scripts/stage-xcode-diagnostic.py" --raw-log "${VALIDATE_LOG}" \
    --output-dir "${DIAGNOSTIC_DIR}" --exit-status "${VALIDATE_STATUS}" --phase validation \
    --protected-values-file "${PROTECTED_VALUES_FILE}" || true
  printf 'Apple validation failed; sanitized diagnostic staged\n' >&2
  exit 11
fi
set +e
xcrun altool --upload-app --type ios --file "${IPA}" --apiKey "${RIVETKIND_ASC_KEY_ID}" --apiIssuer "${RIVETKIND_ASC_ISSUER_ID}" --output-format json >"${UPLOAD_LOG}" 2>&1
UPLOAD_STATUS=$?
set -e
if [[ "${UPLOAD_STATUS}" -ne 0 ]]; then
  python3 "${GITHUB_WORKSPACE}/scripts/stage-xcode-diagnostic.py" --raw-log "${UPLOAD_LOG}" \
    --output-dir "${DIAGNOSTIC_DIR}" --exit-status "${UPLOAD_STATUS}" --phase upload \
    --protected-values-file "${PROTECTED_VALUES_FILE}" || true
  printf 'Apple upload failed; sanitized diagnostic staged\n' >&2
  exit 12
fi

mkdir -p "${RESULT_DIR}"
export RIVETKIND_IPA_SHA="$(shasum -a 256 "${IPA}" | cut -d ' ' -f 1)"
export RIVETKIND_IPA_BYTES="$(stat -f %z "${IPA}")"
export RIVETKIND_VALIDATE_LOG_SHA="$(shasum -a 256 "${VALIDATE_LOG}" | cut -d ' ' -f 1)"
export RIVETKIND_UPLOAD_LOG_SHA="$(shasum -a 256 "${UPLOAD_LOG}" | cut -d ' ' -f 1)"
python3 - "${RESULT_DIR}/testflight-upload-receipt.json" <<'PY'
import json,os,sys
x={
 'schema':'rivetkind_testflight_upload_v1','status':'PASS','appId':'6799331457',
 'bundleIdentifier':'com.wellmadesystems.bulletheavengacha.audition','versionName':'1.39','buildNumber':40,
 'candidateCommit':os.environ['BHG_CANDIDATE_COMMIT'],'candidateTree':os.environ['BHG_CANDIDATE_TREE'],
 'ipaSha256':os.environ['RIVETKIND_IPA_SHA'],'ipaBytes':int(os.environ['RIVETKIND_IPA_BYTES']),
 'profileUuid':'71a04e62-08f5-4602-a0ba-c4a493ec9578',
 'profileSha256':'74e871f8c0230508983303e80f07d5517cf4a61eec245ca4bc233a524e0ff371',
 'distributionCertificateSha256':'3870fd7a823c074b79fdf2862c3a57b5432bcce43b963e759f81ea3789e1a107',
 'validationLogSha256':os.environ['RIVETKIND_VALIDATE_LOG_SHA'],
 'uploadLogSha256':os.environ['RIVETKIND_UPLOAD_LOG_SHA'],
 'workflowRunId':os.environ.get('GITHUB_RUN_ID'),'workflowRunAttempt':os.environ.get('GITHUB_RUN_ATTEMPT'),
 'appleValidation':'PASS','appleUpload':'PASS','protectedValuesPrinted':False,
}
open(sys.argv[1],'w',encoding='utf-8').write(json.dumps(x,indent=2,sort_keys=True)+'\n')
PY
chmod 0600 "${RESULT_DIR}/testflight-upload-receipt.json"
printf 'PASS Rivetkind 1.39 build 40 uploaded to Apple TestFlight processing\n'
