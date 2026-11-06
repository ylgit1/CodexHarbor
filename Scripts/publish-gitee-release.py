#!/usr/bin/env python3
"""Publish one already-verified GitHub Release installer to Gitee Release.

Requires the GITEE_TOKEN GitHub Actions secret (Gitee personal access token
with projects/repository permission). Never prints or stores the token.
Safe to rerun after an interrupted upload: a matching existing attachment is
reused rather than duplicated.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

GITEE_API = "https://gitee.com/api/v5"
REPOSITORY = "yangxiaoyong01/CodexHarbor"


class PublishError(RuntimeError):
    pass


def api(path: str, *, token: str, method: str = "GET",
        data: bytes | None = None, content_type: str | None = None):
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "CodexHarbor-DualReleasePublisher",
        "Accept": "application/json",
    }
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(
        f"{GITEE_API}/repos/{REPOSITORY}/{path}",
        data=data, method=method, headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=210) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        if error.code in (401, 403):
            raise PublishError(
                f"Gitee API returned HTTP {error.code}; verify GITEE_TOKEN "
                "and its projects permission."
            ) from error
        # Do not print the response or request: they may contain a token.
        raise PublishError(f"Gitee API {method} {path}: HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise PublishError(
            f"Gitee API {method} {path}: network error ({type(error.reason).__name__})"
        ) from error


def get_release(tag: str, token: str):
    return api(f"releases/tags/{urllib.parse.quote(tag)}", token=token)


def list_attachments(release_id: int, token: str):
    data = api(f"releases/{release_id}/attach_files?per_page=100", token=token)
    if not isinstance(data, list):
        raise PublishError("Gitee API returned an unexpected attachment list.")
    return data


def create_release(tag: str, sha: str, token: str, notes: str):
    # Gitee OpenAPI v5 declares the release fields as formData.
    fields = {
        "access_token": token,
        "tag_name": tag,
        "name": f"Codex Harbor {tag}",
        "body": notes,
        "target_commitish": sha,
        "prerelease": "false",
    }
    response = api(
        "releases", token=token, method="POST",
        data=urllib.parse.urlencode(fields).encode("utf-8"),
        content_type="application/x-www-form-urlencoded",
    )
    if not isinstance(response, dict) or not response.get("id"):
        raise PublishError("Gitee did not confirm release creation.")
    return response


def upload_attachment(release_id: int, asset: Path, token: str):
    # Upload with the stdlib so GitHub Actions needs no additional packages.
    boundary = "codex-harbor-" + uuid.uuid4().hex
    prefix = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="access_token"\r\n\r\n'
        f"{token}\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{asset.name}"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode("utf-8")
    suffix = f"\r\n--{boundary}--\r\n".encode("ascii")
    # A single DMG is <100 MB (the Gitee Release per-file limit).
    content = prefix + asset.read_bytes() + suffix
    return api(
        f"releases/{release_id}/attach_files",
        token=token, method="POST",
        data=content,
        content_type=f"multipart/form-data; boundary={boundary}",
    )


def verify_local(asset: Path, expected_sha256: str):
    if not asset.is_file():
        raise PublishError(f"Missing installer: {asset}")
    h = hashlib.sha256()
    with asset.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    actual = h.hexdigest()
    if actual != expected_sha256:
        raise PublishError("Local installer SHA-256 does not match GitHub Release.")
    return asset.stat().st_size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="Existing vX.Y.Z Git tag")
    parser.add_argument("--commit", required=True, help="Source commit SHA on Gitee")
    parser.add_argument("--asset", required=True, type=Path, help="GitHub Release DMG")
    parser.add_argument("--sha256", required=True, help="Verified SHA-256 from GitHub")
    parser.add_argument("--notes", type=Path, help="Optional Markdown release notes")
    args = parser.parse_args()

    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        raise PublishError("Expected a version tag like v0.1.33.")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise PublishError("Expected a full source commit SHA.")
    if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
        raise PublishError("Expected an unmodified SHA-256 hex digest.")
    if args.asset.suffix.lower() != ".dmg":
        raise PublishError("Expected a DMG installer.")
    size = verify_local(args.asset, args.sha256)

    token = os.getenv("GITEE_TOKEN", "").strip()
    if not token:
        raise PublishError(
            "GITEE_TOKEN is not set. Configure it as a GitHub Actions "
            "repository secret; Git credentials alone cannot upload "
            "Gitee Release attachments."
        )

    release = get_release(args.tag, token)
    if not release:
        notes = (
            args.notes.read_text(encoding="utf-8") if args.notes else
            f"Codex Harbor {args.tag}\n\n"
            "Native macOS notch island with smooth expand/collapse and "
            "ChatGPT foreground-only visibility.\n\n"
            f"Source commit: {args.commit}\n"
            f"ARM64 DMG SHA-256: {args.sha256}\n"
        )
        release = create_release(args.tag, args.commit, token, notes)

    if release.get("tag_name") != args.tag:
        raise PublishError("Gitee Release tag does not match the requested tag.")
    release_id = int(release["id"])

    files = list_attachments(release_id, token)
    matching = [f for f in files if f.get("name") == args.asset.name]
    if matching:
        if len(matching) != 1 or int(matching[0].get("size", -1)) != size:
            raise PublishError("Gitee already has a conflicting attachment name.")
    else:
        print(f"Uploading verified {size}-byte installer to Gitee {args.tag}...")
        try:
            upload_attachment(release_id, args.asset, token)
        except PublishError:
            # The server may have accepted the upload before the connection
            # failed. Check before attempting a duplicate.
            pass
        files = list_attachments(release_id, token)
        matching = [f for f in files if f.get("name") == args.asset.name]
        if len(matching) != 1 or int(matching[0].get("size", -1)) != size:
            raise PublishError(
                "Gitee attachment upload has not been confirmed; "
                "check the release and rerun this command."
            )

    asset_url = matching[0].get("browser_download_url")
    if not asset_url or not asset_url.startswith(
        f"https://gitee.com/{REPOSITORY}/releases/download/"
    ):
        raise PublishError("Gitee did not return the official download URL.")

    print("GITEE_RELEASE_URL=" +
          f"https://gitee.com/{REPOSITORY}/releases/tag/{args.tag}")
    print("GITEE_ASSET_URL=" + asset_url)
    print("INSTALLER_SHA256=" + args.sha256)
    print("GITEE_ATTACHMENT_SIZE=" + str(size))


if __name__ == "__main__":
    try:
        main()
    except (PublishError, OSError, ValueError) as error:
        print(f"Gitee publishing failed: {error}", file=sys.stderr)
        sys.exit(1)
