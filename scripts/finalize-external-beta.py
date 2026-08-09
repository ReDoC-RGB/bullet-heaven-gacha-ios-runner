#!/usr/bin/env python3
"""Finalize Rivetkind build 39 for the existing external TestFlight group."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import time
from pathlib import Path

import jwt
import requests


API_ROOT = "https://api.appstoreconnect.apple.com"
APP_ID = "6799331457"
GROUP_ID = "4ed23db8-45ce-4a56-b68f-8a98b89308c0"
BUILD_NUMBER = "39"
LOCALE = "en-US"
WHAT_TO_TEST = (
    "Test Rivetkind 1.38 build 39. Run away continuously and confirm enemies keep fair "
    "pressure from ahead and the sides without visible pop-ins or impossible escapes. "
    "Coin rewards should be much lower than build 38. During an upgrade choice, use the "
    "two reroll tokens and confirm each refresh offers three distinct, character-correct "
    "choices; a third reroll must be unavailable. Report unfair spawns, pathing stalls, "
    "reward duplication, excessive coins, broken rerolls, or non-Mia in-run choices."
)


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.removeprefix("export ").split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values


class Apple:
    def __init__(self, key_id: str, issuer_id: str, private_key: bytes):
        now = int(dt.datetime.now(dt.timezone.utc).timestamp())
        encoded = jwt.encode(
            {"iss": issuer_id, "iat": now - 5, "exp": now + 900, "aud": "appstoreconnect-v1"},
            private_key,
            algorithm="ES256",
            headers={"kid": key_id, "typ": "JWT"},
        )
        self.session = requests.Session()
        self.session.headers.update(
            {"Authorization": f"Bearer {encoded}", "Content-Type": "application/json"}
        )

    def request(self, method: str, path: str, expected: set[int], **kwargs) -> dict | None:
        response = self.session.request(method, API_ROOT + path, timeout=45, **kwargs)
        if response.status_code not in expected:
            raise RuntimeError(
                f"Apple API {method} {path} failed with HTTP {response.status_code}: "
                f"{response.text[:1800]}"
            )
        return response.json() if response.content else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apple-env", type=Path, required=True)
    parser.add_argument("--api-key", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    args = parser.parse_args()

    env = load_env(args.apple_env)
    apple = Apple(
        env["APP_STORE_CONNECT_KEY_ID"],
        env["APP_STORE_CONNECT_ISSUER_ID"],
        args.api_key.read_bytes(),
    )
    deadline = time.monotonic() + args.timeout_seconds
    build: dict | None = None
    last_state: str | None = None
    while time.monotonic() < deadline:
        payload = apple.request(
            "GET",
            "/v1/builds",
            {200},
            params={
                "filter[app]": APP_ID,
                "filter[version]": BUILD_NUMBER,
                "sort": "-uploadedDate",
                "limit": "10",
            },
        )
        matches = payload["data"] if payload else []
        if len(matches) > 1:
            raise RuntimeError(f"more than one Rivetkind build {BUILD_NUMBER} exists")
        if matches:
            build = matches[0]
            state = build["attributes"].get("processingState")
            if state != last_state:
                print(f"Apple build {BUILD_NUMBER} processingState={state}", flush=True)
                last_state = state
            if state == "VALID":
                break
            if state in {"FAILED", "INVALID"}:
                raise RuntimeError(f"Apple processing ended in {state}")
        time.sleep(20)
    else:
        raise RuntimeError(f"timed out waiting for Apple build {BUILD_NUMBER} to become VALID")

    assert build is not None
    build_id = build["id"]
    if build["attributes"].get("buildAudienceType") != "APP_STORE_ELIGIBLE":
        raise RuntimeError(f"build {BUILD_NUMBER} is not eligible for external TestFlight distribution")
    build_app = apple.request(
        "GET", f"/v1/builds/{build_id}/relationships/app", {200}
    )["data"]
    if build_app.get("id") != APP_ID:
        raise RuntimeError(f"build {BUILD_NUMBER} belongs to an unexpected App Store Connect app")
    groups = apple.request(
        "GET", f"/v1/apps/{APP_ID}/betaGroups", {200}, params={"limit": "200"}
    )["data"]
    target_groups = [item for item in groups if item["id"] == GROUP_ID]
    if len(target_groups) != 1 or target_groups[0]["attributes"].get("isInternalGroup") is not False:
        raise RuntimeError("the authorized external TestFlight group is unavailable")
    encryption_before = build["attributes"].get("usesNonExemptEncryption")
    if encryption_before is not False:
        result = apple.request(
            "PATCH",
            f"/v1/builds/{build_id}",
            {200},
            json={
                "data": {
                    "type": "builds",
                    "id": build_id,
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
        )
        encryption_after = result["data"]["attributes"].get("usesNonExemptEncryption")
    else:
        encryption_after = encryption_before
    if encryption_after is not False:
        raise RuntimeError("build encryption exemption was not recorded as false")

    localizations = apple.request(
        "GET",
        "/v1/betaBuildLocalizations",
        {200},
        params={"filter[build]": build_id, "limit": "50"},
    )["data"]
    matches = [item for item in localizations if item["attributes"].get("locale") == LOCALE]
    if len(matches) > 1:
        raise RuntimeError("duplicate English beta build localizations")
    if matches:
        localization = apple.request(
            "PATCH",
            f"/v1/betaBuildLocalizations/{matches[0]['id']}",
            {200},
            json={
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": matches[0]["id"],
                    "attributes": {"whatsNew": WHAT_TO_TEST},
                }
            },
        )["data"]
        localization_created = False
    else:
        localization = apple.request(
            "POST",
            "/v1/betaBuildLocalizations",
            {201},
            json={
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": LOCALE, "whatsNew": WHAT_TO_TEST},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )["data"]
        localization_created = True

    assigned = apple.request(
        "GET", f"/v1/betaGroups/{GROUP_ID}/builds", {200}, params={"limit": "200"}
    )["data"]
    if build_id not in {item["id"] for item in assigned}:
        assignment_deadline = time.monotonic() + 600
        while True:
            response = apple.session.request(
                "POST",
                API_ROOT + f"/v1/builds/{build_id}/relationships/betaGroups",
                timeout=45,
                json={"data": [{"type": "betaGroups", "id": GROUP_ID}]},
            )
            if response.status_code == 204:
                break
            if response.status_code == 404 and time.monotonic() < assignment_deadline:
                print("Apple external-group relationship is still propagating; retrying", flush=True)
                time.sleep(20)
                continue
            raise RuntimeError(
                "Apple API external-group assignment failed with HTTP "
                f"{response.status_code}: {response.text[:1800]}"
            )
        assigned = apple.request(
            "GET", f"/v1/betaGroups/{GROUP_ID}/builds", {200}, params={"limit": "200"}
        )["data"]
        if build_id not in {item["id"] for item in assigned}:
            raise RuntimeError("build was not assigned to Rivetkind External Beta")

    submissions = apple.request(
        "GET",
        "/v1/betaAppReviewSubmissions",
        {200},
        params={"filter[build]": build_id, "limit": "10"},
    )["data"]
    if len(submissions) > 1:
        raise RuntimeError(f"multiple beta review submissions exist for build {BUILD_NUMBER}")
    if submissions:
        submission = submissions[0]
        submitted_now = False
    else:
        submission = apple.request(
            "POST",
            "/v1/betaAppReviewSubmissions",
            {201},
            json={
                "data": {
                    "type": "betaAppReviewSubmissions",
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )["data"]
        submitted_now = True

    receipt = {
        "schema": "rivetkind_external_beta_finalize_v1",
        "status": "PASS",
        "appId": APP_ID,
        "versionName": "1.38",
        "buildNumber": 39,
        "buildId": build_id,
        "processingState": build["attributes"].get("processingState"),
        "usesNonExemptEncryption": encryption_after,
        "localizationId": localization["id"],
        "localizationCreated": localization_created,
        "whatToTest": WHAT_TO_TEST,
        "groupId": GROUP_ID,
        "buildAssignedToExternalGroup": True,
        "reviewSubmissionId": submission["id"],
        "betaReviewState": submission["attributes"].get("betaReviewState"),
        "submittedNow": submitted_now,
        "protectedValuesPrinted": False,
    }
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(args.receipt, 0o600)
    print("PASS Rivetkind 1.38 build 39 assigned to external beta and submitted for review", flush=True)


if __name__ == "__main__":
    main()
