#!/usr/bin/env python3
"""Validate Cloud Forge catalog manifests with no third-party dependencies."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


APP_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
APP_VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
IMAGE_RE = {
    "aws": re.compile(r"^(ami-[a-z0-9]+|ssm:/[A-Za-z0-9/_./-]+)$"),
    "aliyun": re.compile(r"^(m-[a-zA-Z0-9-]+|aliyun_[a-zA-Z0-9_]+\.vhd)$"),
}
VALID_CATEGORIES = {"devtools", "automation", "monitoring", "database", "cms", "other"}
VALID_CLOUDS = {"aws", "aliyun"}
VALID_TIERS = {"certified", "community", "experimental"}
VALID_AMI_ROLES = {"web", "db", "tcp"}
DIRECT_TCP_ROLES = {"db", "tcp"}
AWS_AMI_BY_ROLE = {
    "web": "ami-0777e5ab470bf89c1",
    "db": "ami-0f6b6dc8c575106cb",
    "tcp": "ami-0f6b6dc8c575106cb",
}
IMMUTABLE_IMAGE_RE = re.compile(
    r"^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?/[A-Za-z0-9_./-]+@sha256:[a-f0-9]{64}$"
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")


def assert_string(value: object, field: str, path: Path) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{path}: {field} must be a non-empty string")
    return value


def validate_template_path(root: Path, rel_path: str, manifest: Path) -> None:
    if rel_path.startswith("/") or ".." in Path(rel_path).parts:
        fail(f"{manifest}: template path must be repository-relative: {rel_path}")

    full_path = root / rel_path
    if not full_path.is_file():
        fail(f"{manifest}: missing template {rel_path}")

    if full_path.suffix == ".json":
        read_json(full_path)
    elif full_path.suffix not in {".yaml", ".yml"}:
        fail(f"{manifest}: template must be .json, .yaml, or .yml: {rel_path}")


def validate_compose_package(root: Path, app_id: str, manifest: Path) -> None:
    manifest_data = read_json(manifest)
    role = str(manifest_data.get("ami_role") or "web")
    compose_dir = root / "apps" / app_id / "compose"
    compose_path = compose_dir / "docker-compose.yml"
    app_env_path = compose_dir / "app.env"

    if not compose_path.is_file():
        fail(f"{manifest}: missing shared compose {compose_path.relative_to(root)}")

    compose_text = compose_path.read_text(encoding="utf-8")
    if "cloud-forge" not in compose_text:
        fail(f"{compose_path}: docker-compose must attach services to the cloud-forge network")

    if "external: true" in compose_text:
        fail(f"{compose_path}: app compose must not declare cloud-forge as external (platform creates the network on merge)")

    has_host_ports = re.search(r"^\s*ports\s*:", compose_text, re.MULTILINE) is not None
    if role in DIRECT_TCP_ROLES:
        if not has_host_ports:
            fail(f"{compose_path}: {role} apps must publish the service port for direct TCP access")
    elif has_host_ports:
        fail(f"{compose_path}: must not publish host ports (Caddy is the edge proxy)")

    if "privileged:" in compose_text or "network_mode:" in compose_text:
        fail(f"{compose_path}: must not use privileged mode or custom network_mode")

    if "docker.sock" in compose_text:
        fail(f"{compose_path}: must not mount docker.sock")

    if re.search(r"^\s*image:\s*docker\.1ms\.run/", compose_text, re.MULTILINE):
        fail(f"{compose_path}: image must use official Docker Hub names, not registry mirrors")

    if re.search(r":latest\s*$", compose_text, re.MULTILINE):
        fail(f"{compose_path}: image must pin a tag or digest, not :latest")

    if not app_env_path.is_file():
        fail(f"{manifest}: missing shared compose env {app_env_path.relative_to(root)}")

    app_env_text = app_env_path.read_text(encoding="utf-8")
    if role in DIRECT_TCP_ROLES:
        service_port = manifest_data.get("service_port")
        if not isinstance(service_port, int) or service_port <= 0:
            fail(f"{manifest}: {role} apps must declare a positive service_port")
        if f"CLOUD_FORGE_SERVICE_PORT={service_port}" not in app_env_text:
            fail(f"{app_env_path}: {role} apps must define CLOUD_FORGE_SERVICE_PORT={service_port}")
    else:
        if "CLOUD_FORGE_CADDY_UPSTREAM=" not in app_env_text:
            fail(f"{app_env_path}: must define CLOUD_FORGE_CADDY_UPSTREAM")

        upstream_match = re.search(r"CLOUD_FORGE_CADDY_UPSTREAM=http://([^:/]+):(\d+)", app_env_text)
        if not upstream_match:
            fail(f"{app_env_path}: CLOUD_FORGE_CADDY_UPSTREAM must be http://<service>:<port>")
        upstream_host = upstream_match.group(1)
        if not re.search(rf"^\s*{re.escape(upstream_host)}\s*:", compose_text, re.MULTILINE):
            fail(
                f"{app_env_path}: upstream host {upstream_host!r} must match a service name in {compose_path.name}"
            )

    uses_secret_file = "/opt/cloud-forge/compose.app.env" in compose_text
    has_secret_env = "CLOUD_FORGE_SECRET_ENV=" in app_env_text
    if uses_secret_file and not has_secret_env:
        fail(f"{compose_path}: env_file requires CLOUD_FORGE_SECRET_ENV in {app_env_path.name}")
    if has_secret_env and not uses_secret_file:
        fail(f"{app_env_path}: CLOUD_FORGE_SECRET_ENV requires env_file /opt/cloud-forge/compose.app.env in compose")

    for host_path in re.findall(r"-\s+(/opt/cloud-forge/[^\s:]+):", compose_text):
        if not host_path.startswith("/opt/cloud-forge/data/"):
            fail(f"{compose_path}: volume host path must be under /opt/cloud-forge/data/: {host_path}")

    aws_setup = root / "apps" / app_id / "aws" / "setup.sh"
    aliyun_setup = root / "apps" / app_id / "aliyun" / "setup.sh"
    for setup_path in (aws_setup, aliyun_setup):
        if setup_path.is_file() and not setup_path.stat().st_mode & 0o111:
            fail(f"{setup_path}: setup.sh must be executable (chmod 755)")


def validate_cloud_setup(root: Path, app_id: str, cloud: str, manifest: Path) -> None:
    setup_path = root / "apps" / app_id / cloud / "setup.sh"
    if setup_path.exists() and not setup_path.is_file():
        fail(f"{manifest}: {cloud}/setup.sh must be a regular file when present")


def validate_manifest(root: Path, manifest: Path) -> None:
    data = read_json(manifest)
    app_id = assert_string(data.get("id"), "id", manifest)
    if not APP_ID_RE.match(app_id):
        fail(f"{manifest}: invalid app id {app_id!r}")
    if manifest.parent.name != app_id:
        fail(f"{manifest}: id={app_id} does not match directory {manifest.parent.name}")

    for field in ("name", "desc", "category", "version"):
        assert_string(data.get(field), field, manifest)

    if data["category"] not in VALID_CATEGORIES:
        fail(f"{manifest}: unsupported category {data['category']!r}")
    if not SEMVER_RE.match(data["version"]):
        fail(f"{manifest}: version must be semver")
    if "min_cli_version" in data and not SEMVER_RE.match(str(data["min_cli_version"])):
        fail(f"{manifest}: min_cli_version must be semver")

    versions = data.get("versions")
    if versions is not None:
        if not isinstance(versions, dict):
            fail(f"{manifest}: versions must be an object")
        default_version = assert_string(versions.get("default"), "versions.default", manifest)
        items = versions.get("items")
        if not isinstance(items, list) or not items:
            fail(f"{manifest}: versions.items must be a non-empty array")
        seen_versions: set[str] = set()
        verified_versions: set[str] = set()
        image_backed_versions = any(isinstance(item, dict) and item.get("image") for item in items)
        for index, item in enumerate(items):
            if not isinstance(item, dict):
                fail(f"{manifest}: versions.items[{index}] must be an object")
            app_version = assert_string(item.get("version"), f"versions.items[{index}].version", manifest)
            if not APP_VERSION_RE.fullmatch(app_version):
                fail(f"{manifest}: invalid application version {app_version!r}")
            if app_version in seen_versions:
                fail(f"{manifest}: duplicate application version {app_version!r}")
            seen_versions.add(app_version)
            if not isinstance(item.get("verified"), bool):
                fail(f"{manifest}: versions.items[{index}].verified must be boolean")
            if item["verified"]:
                verified_versions.add(app_version)
            deployable = item.get("deployable", True)
            if not isinstance(deployable, bool):
                fail(f"{manifest}: versions.items[{index}].deployable must be boolean")
            lifecycle = item.get("lifecycle")
            if lifecycle is not None and lifecycle not in {"stable", "archived", "unavailable"}:
                fail(f"{manifest}: invalid lifecycle for version {app_version!r}")
            image = item.get("image")
            if image is not None and (not isinstance(image, str) or not IMMUTABLE_IMAGE_RE.fullmatch(image)):
                fail(f"{manifest}: version {app_version!r} image must be an immutable sha256 reference")
            if image_backed_versions and deployable and not image:
                fail(f"{manifest}: deployable version {app_version!r} must have an immutable image")
            if item["verified"] and not deployable:
                fail(f"{manifest}: verified version {app_version!r} must be deployable")
            verification = item.get("verification")
            if verification is not None:
                if not isinstance(verification, dict):
                    fail(f"{manifest}: version {app_version!r} verification must be an object")
                if verification.get("level") not in {"local-smoke", "cloud-e2e"}:
                    fail(f"{manifest}: version {app_version!r} has invalid verification level")
                if not isinstance(verification.get("tested_at"), str) or not verification["tested_at"]:
                    fail(f"{manifest}: version {app_version!r} verification needs tested_at")
            if image_backed_versions and item["verified"] and verification is None:
                fail(f"{manifest}: verified immutable version {app_version!r} needs verification evidence")
            if lifecycle == "unavailable" and deployable:
                fail(f"{manifest}: unavailable version {app_version!r} cannot be deployable")
            if not deployable and not item.get("unavailable_reason"):
                fail(f"{manifest}: non-deployable version {app_version!r} needs unavailable_reason")
        if default_version not in seen_versions:
            fail(f"{manifest}: versions.default must match an item")
        if default_version not in verified_versions:
            fail(f"{manifest}: versions.default must be a verified version")

    tier = data.get("tier", "community")
    if tier not in VALID_TIERS:
        fail(f"{manifest}: unsupported tier {tier!r}")

    role = str(data.get("ami_role") or "web")
    if role not in VALID_AMI_ROLES:
        fail(f"{manifest}: unsupported ami_role {role!r}")
    if "service_scheme" in data:
        assert_string(data.get("service_scheme"), "service_scheme", manifest)

    smoke = data.get("smoke")
    if smoke is not None:
        if not isinstance(smoke, dict):
            fail(f"{manifest}: smoke must be an object")
        paths = smoke.get("health_paths")
        if paths is not None:
            if not isinstance(paths, list) or not paths:
                fail(f"{manifest}: smoke.health_paths must be a non-empty array")
            for path in paths:
                if not isinstance(path, str) or not path:
                    fail(f"{manifest}: smoke.health_paths entries must be non-empty strings")
                if not path.startswith("/"):
                    fail(f"{manifest}: smoke.health_paths entries must start with /: {path!r}")
        wait_seconds = smoke.get("wait_seconds")
        if wait_seconds is not None and (not isinstance(wait_seconds, int) or wait_seconds < 1):
            fail(f"{manifest}: smoke.wait_seconds must be a positive integer")

    clouds = data.get("clouds")
    if not isinstance(clouds, list) or not clouds:
        fail(f"{manifest}: clouds must be a non-empty array")
    if len(set(clouds)) != len(clouds):
        fail(f"{manifest}: clouds must not contain duplicates")
    unknown_clouds = sorted(set(clouds) - VALID_CLOUDS)
    if unknown_clouds:
        fail(f"{manifest}: unsupported clouds {unknown_clouds}")

    images = data.get("images")
    templates = data.get("templates")
    if not isinstance(images, dict):
        fail(f"{manifest}: images must be an object")
    if not isinstance(templates, dict):
        fail(f"{manifest}: templates must be an object")

    for cloud in clouds:
        image = assert_string(images.get(cloud), f"images.{cloud}", manifest)
        if not IMAGE_RE[cloud].match(image):
            fail(f"{manifest}: invalid {cloud} image id {image!r}")

        ref = templates.get(cloud)
        if not isinstance(ref, dict):
            fail(f"{manifest}: templates.{cloud} must be an object")
        rel_path = assert_string(ref.get("path"), f"templates.{cloud}.path", manifest)
        validate_template_path(root, rel_path, manifest)

    expected_aws_ami = AWS_AMI_BY_ROLE[role]
    if "aws" in clouds and images.get("aws") != expected_aws_ami:
        fail(
            f"{manifest}: images.aws must use Marketplace {role} AMI {expected_aws_ami}, "
            f"got {images.get('aws')!r}"
        )
    latest_ami = ((data.get("params") or {}).get("LatestAmiId") or {}).get("aws") or {}
    if "aws" in clouds and latest_ami.get("default") != expected_aws_ami:
        fail(f"{manifest}: params.LatestAmiId.aws.default must match images.aws")

    validate_compose_package(root, app_id, manifest)
    for cloud in clouds:
        validate_cloud_setup(root, app_id, cloud, manifest)

    params = data.get("params", {})
    if params is not None and not isinstance(params, dict):
        fail(f"{manifest}: params must be an object")
    for name, definition in params.items():
        if not isinstance(definition, dict):
            fail(f"{manifest}: params.{name} must be an object")
        if "secret" in definition and not isinstance(definition["secret"], bool):
            fail(f"{manifest}: params.{name}.secret must be a boolean")
        if "required" in definition and not isinstance(definition["required"], bool):
            fail(f"{manifest}: params.{name}.required must be a boolean")
        for cloud_key in ("aws", "aliyun"):
            cloud_def = definition.get(cloud_key)
            if cloud_def is not None and not isinstance(cloud_def, dict):
                fail(f"{manifest}: params.{name}.{cloud_key} must be an object")
            if isinstance(cloud_def, dict) and "required" in cloud_def and not isinstance(cloud_def["required"], bool):
                fail(f"{manifest}: params.{name}.{cloud_key}.required must be a boolean")
            if isinstance(cloud_def, dict) and isinstance(cloud_def.get("options"), list):
                options = cloud_def["options"]
                if len(options) != len(set(str(option) for option in options)):
                    fail(f"{manifest}: params.{name}.{cloud_key}.options must not contain duplicates")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()

    root = args.root.resolve()
    manifests = sorted(
        path
        for path in root.glob("apps/*/manifest.json")
        if path.parent.name != "_template"
    )
    if not manifests:
        fail(f"{root}: no app manifests found")

    for manifest in manifests:
        validate_manifest(root, manifest)


if __name__ == "__main__":
    main()
