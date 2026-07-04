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
IMAGE_RE = {
    "aws": re.compile(r"^(ami-[a-z0-9]+|ssm:/[A-Za-z0-9/_./-]+)$"),
    "aliyun": re.compile(r"^(m-[a-zA-Z0-9-]+|aliyun_[a-zA-Z0-9_]+\.vhd)$"),
}
VALID_CATEGORIES = {"devtools", "automation", "monitoring", "database", "cms", "other"}
VALID_CLOUDS = {"aws", "aliyun"}


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()

    root = args.root.resolve()
    manifests = sorted(root.glob("apps/*/manifest.json"))
    if not manifests:
        fail(f"{root}: no app manifests found")

    for manifest in manifests:
        validate_manifest(root, manifest)


if __name__ == "__main__":
    main()
