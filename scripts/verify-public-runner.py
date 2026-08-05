#!/usr/bin/env python3
"""Fail-closed verifier for the Bullet Heaven public macOS signing runner."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


BUNDLE = "com.wellmadesystems.bulletheavengacha.audition"
BUILD_NUMBER = "8"
VERSION = "1.7"
EXPECTED_TEAM = "7D88UFWRTZ"
EXPECTED_PROFILE_UUID = "94d6d06b-6de2-4a35-b0ca-bc3e04efd801"
EXPECTED_PROFILE_SHA = "9261cfa49f68b936a2f0bf5fc65b657718812e1b810523a792cfafee98b9f9ff"
EXPECTED_CERT_SHA = "3870fd7a823c074b79fdf2862c3a57b5432bcce43b963e759f81ea3789e1a107"
EXPECTED_ARCHIVE_SHA = "3995f2ed4172b95852c87c7c8b56a8e0582761a228e217e113992a6fe9088caf"
EXPECTED_ARCHIVE_BYTES = 301584497
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")


def sha_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_inventory(items: list[dict]) -> list[dict]:
    return sorted(items, key=lambda item: item["path"].encode("utf-8"))


def framed_tree(items: list[dict]) -> str:
    digest = hashlib.sha256()
    for item in canonical_inventory(items):
        path = item["path"].encode("utf-8")
        digest.update(len(path).to_bytes(8, "big"))
        digest.update(path)
        digest.update(int(item["bytes"]).to_bytes(8, "big"))
        digest.update(int(item["mode"]).to_bytes(4, "big"))
        digest.update(bytes.fromhex(item["sha256"]))
    return digest.hexdigest()


def load_manifest(path: Path) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "schema",
        "status",
        "createdAtUtc",
        "candidateCommit",
        "candidateTree",
        "candidateParent",
        "bundleIdentifier",
        "marketingVersion",
        "buildNumber",
        "teamIdentifier",
        "unityVersion",
        "buildOptions",
        "signed",
        "totalPaths",
        "inventoryCount",
        "inventoryBytes",
        "framedTreeSha256",
        "unityLogSha256",
        "projectSettingsMutationPatchSha256",
        "fileInventory",
    }
    if set(manifest) != required:
        raise SystemExit("detached manifest shape mismatch")
    if manifest["schema"] != "bullet_heaven_gacha_gate_d_ios_xcode_export_manifest_v2" or manifest["status"] != "PASS":
        raise SystemExit("detached manifest schema/status mismatch")
    if not HEX40.fullmatch(manifest["candidateCommit"]) or not HEX40.fullmatch(manifest["candidateTree"]):
        raise SystemExit("candidate provenance shape mismatch")
    if manifest["candidateCommit"] != "ad95709b70c4f3db3c69ed243276a7ac8e55fcdb" or manifest["candidateTree"] != "46e1b04a870a5d2f8d3ecd167c9da4c035e2058f":
        raise SystemExit("candidate provenance authority mismatch")
    if (
        manifest["bundleIdentifier"] != BUNDLE
        or str(manifest["buildNumber"]) != BUILD_NUMBER
        or manifest["marketingVersion"] != VERSION
        or manifest["teamIdentifier"] != EXPECTED_TEAM
        or manifest["buildOptions"] != "Development"
        or manifest["signed"] is not False
    ):
        raise SystemExit("detached manifest application identity mismatch")
    for key in ("framedTreeSha256", "unityLogSha256", "projectSettingsMutationPatchSha256"):
        if not HEX64.fullmatch(manifest[key]):
            raise SystemExit("detached manifest hash shape mismatch")
    inventory = manifest["fileInventory"]
    if not isinstance(inventory, list) or not inventory:
        raise SystemExit("empty export fileInventory")
    paths: list[str] = []
    folded: set[str] = set()
    for item in inventory:
        if (
            set(item) != {"path", "bytes", "mode", "sha256"}
            or not isinstance(item["bytes"], int)
            or item["bytes"] < 0
            or not isinstance(item["mode"], int)
            or item["mode"] < 0
            or item["mode"] > 0o7777
            or not HEX64.fullmatch(item["sha256"])
        ):
            raise SystemExit("invalid export inventory entry")
        pure = PurePosixPath(item["path"])
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != item["path"] or not item["path"]:
            raise SystemExit("unsafe export inventory path")
        if item["path"].casefold() in folded:
            raise SystemExit("case-colliding export inventory path")
        folded.add(item["path"].casefold())
        paths.append(item["path"])
    if paths != [item["path"] for item in canonical_inventory(inventory)] or len(paths) != len(set(paths)):
        raise SystemExit("inventory order/uniqueness mismatch")
    if (
        len(inventory) != manifest["inventoryCount"]
        or sum(item["bytes"] for item in inventory) != manifest["inventoryBytes"]
        or manifest["totalPaths"] < len(inventory)
        or framed_tree(inventory) != manifest["framedTreeSha256"]
    ):
        raise SystemExit("inventory totals or framedTreeSha256 mismatch")
    return manifest


def verify_export(args) -> None:
    archive = Path(args.archive)
    manifest = load_manifest(Path(args.manifest))
    expected = args.expected_sha.lower()
    if (
        expected != EXPECTED_ARCHIVE_SHA
        or sha_file(archive) != expected
        or archive.stat().st_size != EXPECTED_ARCHIVE_BYTES
    ):
        raise SystemExit("archive SHA-256/byte length mismatch")
    expected_items = {item["path"]: item for item in manifest["fileInventory"]}
    actual: list[dict] = []
    seen_members: set[str] = set()
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            pure = PurePosixPath(member.name)
            root_directory = member.name.rstrip("/") == "xcode-export" and member.isdir()
            if (
                pure.is_absolute()
                or ".." in pure.parts
                or (not root_directory and not member.name.startswith("xcode-export/"))
                or member.name.casefold() in seen_members
            ):
                raise SystemExit("unsafe or duplicate archive member")
            seen_members.add(member.name.casefold())
            if member.issym() or member.islnk() or member.isdev():
                raise SystemExit("links/devices are forbidden in export archive")
            if not member.isfile():
                continue
            relative = member.name[len("xcode-export/") :]
            if relative not in expected_items:
                raise SystemExit("archive has undeclared file")
            stream = tar.extractfile(member)
            if stream is None:
                raise SystemExit("archive file stream missing")
            digest = hashlib.sha256()
            size = 0
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(block)
                digest.update(block)
            item = {
                "path": relative,
                "bytes": size,
                "mode": member.mode & 0o7777,
                "sha256": digest.hexdigest(),
            }
            if item != expected_items[relative]:
                raise SystemExit("archive file inventory mismatch")
            actual.append(item)
    if canonical_inventory(actual) != manifest["fileInventory"] or framed_tree(actual) != manifest["framedTreeSha256"]:
        raise SystemExit("archive inventory completeness mismatch")
    print("PASS private export archive and detached manifest verified before extraction")


def run_bytes(command: list[str]) -> bytes:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise SystemExit("verification command failed: " + command[0])
    return result.stdout


def verify_ipa_archive_safety(ipa: Path) -> None:
    seen: set[str] = set()
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise SystemExit("IPA ZIP integrity failure")
        for item in archive.infolist():
            name = item.filename
            directory = item.is_dir()
            normalized = name[:-1] if directory and name.endswith("/") else name
            pure = PurePosixPath(normalized)
            if (
                not normalized
                or "\\" in name
                or pure.is_absolute()
                or ".." in pure.parts
                or pure.as_posix() != normalized
                or re.match(r"^[A-Za-z]:", normalized)
                or normalized.casefold() in seen
            ):
                raise SystemExit("duplicate or unsafe IPA path")
            seen.add(normalized.casefold())
            mode = (item.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            if stat.S_ISLNK(mode) or kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise SystemExit("unsafe IPA ZIP entry type")
            if (directory and kind == stat.S_IFREG) or (not directory and kind == stat.S_IFDIR):
                raise SystemExit("unsafe IPA ZIP entry type")
    print("PASS IPA ZIP integrity/path/type/symlink safety verified before extraction")


def write_new_file(path: Path, payload: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        view = memoryview(payload)
        while view:
            view = view[os.write(descriptor, view) :]
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def verify_ipa(args) -> None:
    ipa = Path(args.ipa)
    manifest = load_manifest(Path(args.manifest))
    output = Path(args.output)
    verify_ipa_archive_safety(ipa)
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        apps = sorted(
            {
                name.split("/")[1]
                for name in names
                if name.startswith("Payload/") and len(name.split("/")) > 2 and name.split("/")[1].endswith(".app")
            }
        )
        if len(apps) != 1:
            raise SystemExit("IPA must contain one Payload app")
        prefix = "Payload/" + apps[0] + "/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        embedded = archive.read(prefix + "embedded.mobileprovision")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or PurePosixPath(executable).name != executable or prefix + executable not in names:
            raise SystemExit("IPA executable missing or unsafe")
    if (
        info.get("CFBundleIdentifier") != BUNDLE
        or str(info.get("CFBundleVersion")) != BUILD_NUMBER
        or info.get("CFBundleShortVersionString") != VERSION
    ):
        raise SystemExit("IPA native identity mismatch")
    expected_info = {
        "BHGCandidateCommit": manifest["candidateCommit"],
        "BHGCandidateTree": manifest["candidateTree"],
        "BHGBuildDesignation": "INTERNAL",
        "BHGBuildPipeline": "gate-d-native-v1",
        "BHGBuildProvenance": "private-linux-unity-export",
    }
    if any(info.get(key) != value for key, value in expected_info.items()):
        raise SystemExit("IPA provenance binding mismatch")
    with tempfile.TemporaryDirectory() as temporary:
        profile = Path(temporary) / "embedded.mobileprovision"
        profile.write_bytes(embedded)
        decoded = plistlib.loads(run_bytes(["security", "cms", "-D", "-i", str(profile)]))
    entitlements = decoded.get("Entitlements") or {}
    devices = decoded.get("ProvisionedDevices") or []
    team = (decoded.get("TeamIdentifier") or [None])[0]
    allowed_entitlements = {
        "application-identifier",
        "com.apple.developer.team-identifier",
        "keychain-access-groups",
        "get-task-allow",
        "beta-reports-active",
    }
    profile_sha = hashlib.sha256(embedded).hexdigest()
    if (
        profile_sha != EXPECTED_PROFILE_SHA
        or team != EXPECTED_TEAM
        or decoded.get("UUID") != EXPECTED_PROFILE_UUID
        or entitlements.get("application-identifier") != EXPECTED_TEAM + "." + BUNDLE
        or entitlements.get("get-task-allow") is not False
        or len(devices) != 1
        or decoded.get("ProvisionsAllDevices")
        or not set(entitlements).issubset(allowed_entitlements)
    ):
        raise SystemExit("embedded profile identity/type/device mismatch")
    if decoded.get("ExpirationDate").astimezone(timezone.utc) <= datetime.now(timezone.utc):
        raise SystemExit("embedded profile expired")
    certificates = decoded.get("DeveloperCertificates") or []
    cert_hashes = sorted(hashlib.sha256(bytes(value)).hexdigest() for value in certificates)
    expected_cert = os.environ.get("BHG_EXPECTED_CERT_SHA", "")
    app_signing_cert = os.environ.get("BHG_APP_SIGNING_CERT_SHA", "")
    expected_team = os.environ.get("BHG_EXPECTED_TEAM_ID", "")
    expected_profile = os.environ.get("BHG_EXPECTED_PROFILE_UUID", "")
    if expected_cert != EXPECTED_CERT_SHA or expected_cert not in cert_hashes:
        raise SystemExit("embedded profile certificate does not match imported distribution identity")
    if app_signing_cert != expected_cert:
        raise SystemExit("app CodeDirectory signer certificate does not match imported distribution identity")
    if expected_team != EXPECTED_TEAM or expected_profile != EXPECTED_PROFILE_UUID:
        raise SystemExit("embedded profile team/UUID does not match installed signing authority")
    verification = {
        "schema": 1,
        "status": "PASS",
        "runner": "macos-15",
        "ipaSha256": sha_file(ipa),
        "ipaByteLength": ipa.stat().st_size,
        "bundleIdentifier": BUNDLE,
        "versionName": VERSION,
        "buildNumber": int(BUILD_NUMBER),
        "candidateCommit": manifest["candidateCommit"],
        "candidateTree": manifest["candidateTree"],
        "exportArchiveSha256": EXPECTED_ARCHIVE_SHA,
        "exportFramedTreeSha256": manifest["framedTreeSha256"],
        "designation": "INTERNAL",
        "pipeline": "gate-d-native-v1",
        "provenance": "private-linux-unity-export",
        "profileSha256": profile_sha,
        "profileUuid": decoded.get("UUID"),
        "profileExpirationUtc": decoded.get("ExpirationDate").astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "provisionedDeviceCount": len(devices),
        "teamIdentifier": team,
        "profileCertificateSha256": cert_hashes,
        "appSigningCertificateSha256": app_signing_cert,
        "codesignDeepStrict": True,
        "arm64Verified": True,
        "ipaStructureVerified": True,
        "toolchain": {
            "xcodeVersion": run_bytes(["xcodebuild", "-version"]).decode(errors="replace").strip().splitlines(),
            "machine": platform.machine(),
            "imageOS": os.environ.get("ImageOS"),
            "imageVersion": os.environ.get("ImageVersion"),
        },
        "workflow": {
            "runId": os.environ.get("GITHUB_RUN_ID"),
            "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "runnerName": os.environ.get("RUNNER_NAME"),
        },
    }
    write_new_file(output, (json.dumps(verification, indent=2, sort_keys=True) + "\n").encode())
    print("PASS signed Ad Hoc IPA structure, identity, provenance, profile, and architecture verified")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    export = subparsers.add_parser("verify-export")
    export.add_argument("--archive", required=True)
    export.add_argument("--manifest", required=True)
    export.add_argument("--expected-sha", required=True)
    safety = subparsers.add_parser("verify-ipa-archive")
    safety.add_argument("--ipa", required=True)
    ipa = subparsers.add_parser("verify-ipa")
    ipa.add_argument("--ipa", required=True)
    ipa.add_argument("--manifest", required=True)
    ipa.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.mode == "verify-export":
        verify_export(args)
    elif args.mode == "verify-ipa-archive":
        verify_ipa_archive_safety(Path(args.ipa))
    else:
        verify_ipa(args)


if __name__ == "__main__":
    main()
