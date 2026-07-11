#!/usr/bin/env python3
"""Sync n8n GA releases and immutable image digests from official sources."""

from __future__ import annotations

import concurrent.futures
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "apps" / "n8n" / "manifest.json"
COMPOSE = ROOT / "apps" / "n8n" / "compose" / "docker-compose.yml"
GITHUB_API = "https://api.github.com/repos/n8n-io/n8n"
GHCR_REPOSITORY = "n8n-io/n8n"
GHCR_IMAGE = "ghcr.io/n8n-io/n8n"
SEMVER_TAG = re.compile(r"^n8n@(\d+)\.(\d+)\.(\d+)$")
PLAIN_SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
ACCEPT_MANIFEST = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


def request(url: str, *, headers: dict[str, str] | None = None, method: str = "GET"):
    merged = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "cloud-forge-catalog-version-sync",
    }
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token and url.startswith("https://api.github.com/"):
        merged["Authorization"] = f"Bearer {token}"
    if headers:
        merged.update(headers)
    return urllib.request.urlopen(urllib.request.Request(url, headers=merged, method=method), timeout=30)


def request_json(url: str, *, headers: dict[str, str] | None = None):
    with request(url, headers=headers) as response:
        return json.load(response), response.headers


def github_pages(path: str) -> list[dict]:
    items: list[dict] = []
    page = 1
    while True:
        data, _ = request_json(f"{GITHUB_API}/{path}?per_page=100&page={page}")
        if not data:
            return items
        items.extend(data)
        page += 1


def stable_version(releases: list[dict]) -> str:
    stable = next((item for item in releases if item.get("tag_name") == "stable"), None)
    if not stable:
        stable, _ = request_json(f"{GITHUB_API}/releases/tags/stable")
    body = str(stable.get("body") or "")
    match = re.search(r"\[(\d+\.\d+\.\d+)\]", body)
    if not match:
        raise RuntimeError("could not determine n8n stable version from the official stable release")
    return match.group(1)


def semver_key(version: str) -> tuple[int, int, int]:
    match = PLAIN_SEMVER.fullmatch(version)
    if not match:
        raise ValueError(version)
    return tuple(int(part) for part in match.groups())


def ghcr_token() -> str:
    query = urllib.parse.urlencode(
        {"service": "ghcr.io", "scope": f"repository:{GHCR_REPOSITORY}:pull"}
    )
    data, _ = request_json(f"https://ghcr.io/token?{query}")
    token = str(data.get("token") or "")
    if not token:
        raise RuntimeError("GHCR did not return an anonymous pull token")
    return token


def ghcr_tags(token: str) -> set[str]:
    url = f"https://ghcr.io/v2/{GHCR_REPOSITORY}/tags/list?n=1000"
    tags: set[str] = set()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    while url:
        data, response_headers = request_json(url, headers=headers)
        tags.update(str(tag) for tag in data.get("tags") or [])
        link = response_headers.get("Link", "")
        match = re.search(r"<([^>]+)>;\s*rel=\"next\"", link)
        url = urllib.parse.urljoin("https://ghcr.io", match.group(1)) if match else ""
    return tags


def manifest_digest(version: str, token: str) -> tuple[str, str | None]:
    url = f"https://ghcr.io/v2/{GHCR_REPOSITORY}/manifests/{urllib.parse.quote(version)}"
    try:
        with request(
            url,
            method="HEAD",
            headers={"Authorization": f"Bearer {token}", "Accept": ACCEPT_MANIFEST},
        ) as response:
            digest = str(response.headers.get("Docker-Content-Digest") or "")
    except Exception:
        return version, None
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        return version, None
    return version, digest


def build_items(
    tags: list[dict],
    releases: list[dict],
    stable: str,
    verified_version: str,
    known_images: dict[str, str],
) -> list[dict]:
    prereleases = {
        str(item.get("tag_name") or "")
        for item in releases
        if item.get("draft") or item.get("prerelease")
    }
    published_at = {
        str(item["tag_name"]).removeprefix("n8n@"): str(item.get("published_at") or "")
        for item in releases
        if SEMVER_TAG.fullmatch(str(item.get("tag_name") or ""))
        and not item.get("draft")
        and not item.get("prerelease")
    }
    stable_key = semver_key(stable)
    versions = {
        match.group(1) + "." + match.group(2) + "." + match.group(3)
        for item in tags
        if (match := SEMVER_TAG.fullmatch(str(item.get("name") or "")))
        and str(item.get("name")) not in prereleases
    }
    # A clean semver tag can still belong to n8n's prerelease channel. Versions newer
    # than the official `stable` alias are excluded unless a non-prerelease release exists.
    versions = {
        version
        for version in versions
        if semver_key(version) <= stable_key or version in published_at
    }

    token = ghcr_token()
    available_tags = ghcr_tags(token)
    candidates = sorted(versions & available_tags, key=semver_key, reverse=True)
    digests: dict[str, str] = {
        version: image.rsplit("@", 1)[-1]
        for version, image in known_images.items()
        if re.fullmatch(rf"{re.escape(GHCR_IMAGE)}@sha256:[a-f0-9]{{64}}", image)
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
        for version, digest in executor.map(lambda value: manifest_digest(value, token), candidates):
            if digest:
                digests[version] = digest

    if stable not in digests:
        raise RuntimeError(f"official immutable image digest is unavailable for upstream stable n8n {stable}")
    if verified_version not in digests:
        raise RuntimeError(f"official immutable image digest is unavailable for verified n8n {verified_version}")

    result: list[dict] = []
    for version in sorted(versions, key=semver_key, reverse=True):
        digest = digests.get(version)
        item: dict[str, object] = {
            "version": version,
            "verified": version == verified_version,
            "deployable": bool(digest),
            "lifecycle": "stable" if version == stable else ("archived" if digest else "unavailable"),
            "source_url": f"https://github.com/n8n-io/n8n/releases/tag/n8n%40{version}",
        }
        if published_at.get(version):
            item["published_at"] = published_at[version]
        if digest:
            item["image"] = f"{GHCR_IMAGE}@{digest}"
        else:
            item["unavailable_reason"] = "The official immutable container image could not be resolved from GHCR."
        result.append(item)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--promote-stable",
        action="store_true",
        help="Make the current upstream stable release the verified default after smoke testing",
    )
    parser.add_argument(
        "--verified-at",
        help="UTC date/time of the completed local smoke (required with --promote-stable)",
    )
    args = parser.parse_args()
    if args.promote_stable and not args.verified_at:
        parser.error("--promote-stable requires --verified-at evidence")

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    previous = manifest.get("versions") or {}
    known_images = {
        str(item.get("version")): str(item.get("image"))
        for item in previous.get("items") or []
        if isinstance(item, dict) and item.get("image")
    }
    tags = github_pages("tags")
    releases = github_pages("releases")
    stable = stable_version(releases)
    verified_version = stable if args.promote_stable else str(previous.get("default") or "")
    if not verified_version:
        raise RuntimeError("first sync requires --promote-stable and --verified-at after a successful smoke")
    items = build_items(tags, releases, stable, verified_version, known_images)
    previous_verification = {
        str(item.get("version")): item.get("verification")
        for item in previous.get("items") or []
        if isinstance(item, dict) and item.get("verification")
    }
    for item in items:
        if item["version"] in previous_verification:
            item["verification"] = previous_verification[item["version"]]
        if args.promote_stable and item["version"] == stable:
            item["verification"] = {
                "level": "local-smoke",
                "tested_at": args.verified_at,
                "health_path": "/healthz",
                "platforms": ["local-docker"],
            }
    source = {
        "repository": "https://github.com/n8n-io/n8n",
        "registry": GHCR_IMAGE,
        "policy": "All official clean-semver tags up to the stable channel; GitHub prereleases are excluded.",
        "upstream_stable": stable,
        "synced_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    comparable_previous = {**previous, "source": {**(previous.get("source") or {}), "synced_at": ""}}
    comparable_next = {"default": verified_version, "items": items, "source": {**source, "synced_at": ""}}
    if comparable_previous == comparable_next and previous.get("source", {}).get("synced_at"):
        source["synced_at"] = previous["source"]["synced_at"]
    manifest["versions"] = {"default": verified_version, "items": items, "source": source}
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    stable_image = next(str(item["image"]) for item in items if item["version"] == verified_version)
    compose = COMPOSE.read_text(encoding="utf-8")
    compose = re.sub(
        r"(?m)^\s*image:\s*.*$",
        f"    image: ${{CLOUD_FORGE_APP_IMAGE:-{stable_image}}}",
        compose,
        count=1,
    )
    COMPOSE.write_text(compose, encoding="utf-8")

    deployable = sum(1 for item in items if item["deployable"])
    unavailable = len(items) - deployable
    print(
        f"Synced {len(items)} n8n GA versions: upstream_stable={stable}, verified_default={verified_version}, "
        f"deployable={deployable}, unavailable={unavailable}"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
