#!/usr/bin/env python3
"""Generate Cloud Forge IaC templates from apps/_template and manifest.json."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


DEFAULT_AWS_AMI = "ami-04cf9ac8716f030d6"
DEFAULT_ALIYUN_IMAGE = "aliyun_3_x64_20G_alibase_20260122.vhd"
VALID_TIERS = {"certified", "community", "experimental"}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def to_pascal(app_id: str) -> str:
    parts = [part for part in app_id.split("-") if part]
    if not parts:
        fail(f"invalid app id: {app_id!r}")
    return "".join(part[:1].upper() + part[1:] for part in parts)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def has_admin_password(manifest: dict) -> bool:
    return "AdminPassword" in (manifest.get("params") or {})


def build_aws_secret_params_block(manifest: dict) -> str:
    if not has_admin_password(manifest):
        return ""
    return """  AdminPassword:
    Type: String
    NoEcho: true
    MinLength: 8"""


def build_aws_secret_userdata_block(manifest: dict) -> str:
    if not has_admin_password(manifest):
        return ""
    return "          export CLOUD_FORGE_APP_ADMIN_PASSWORD=${AdminPassword}"


def build_aliyun_secret_params_block(manifest: dict) -> str:
    if not has_admin_password(manifest):
        return ""
    return """,
    "AdminPassword": { "Type": "String", "NoEcho": true, "MinLength": 8 }"""


def build_aliyun_secret_userdata_block(manifest: dict) -> str:
    if not has_admin_password(manifest):
        return ""
    return "export CLOUD_FORGE_APP_ADMIN_PASSWORD=${AdminPassword}\\n"


def cloud_param(manifest: dict, name: str, cloud: str, field: str, default=None):
    params = manifest.get("params") or {}
    definition = params.get(name) or {}
    cloud_def = definition.get(cloud) or {}
    if field in cloud_def:
        return cloud_def[field]
    if field in definition:
        return definition[field]
    return default


def render_template(template_text: str, values: dict[str, str]) -> str:
    rendered = template_text
    for key, value in values.items():
        rendered = rendered.replace(f"{{{{{key}}}}}", value)
    if "{{" in rendered:
        leftovers = sorted(set(re.findall(r"\{\{[A-Z0-9_]+\}\}", rendered)))
        if leftovers:
            fail(f"unresolved template placeholders: {', '.join(leftovers)}")
    return rendered


def load_template(root: Path, name: str) -> str:
    path = root / "apps" / "_template" / name
    if not path.is_file():
        fail(f"missing template {path}")
    return path.read_text(encoding="utf-8")


def generate_iac(root: Path, app_id: str, manifest: dict) -> None:
    app_prefix = to_pascal(app_id)
    app_name = manifest.get("name") or app_id

    aws_default = cloud_param(manifest, "InstanceType", "aws", "default", "t3.small")
    aws_options = cloud_param(manifest, "InstanceType", "aws", "options", [aws_default])
    aliyun_default = cloud_param(manifest, "InstanceType", "aliyun", "default", "ecs.t6-c1m1.large")
    aliyun_options = cloud_param(
        manifest, "InstanceType", "aliyun", "options", [aliyun_default]
    )

    aws_disk = str(cloud_param(manifest, "DiskSize", "aws", "default", "20"))
    aliyun_disk = str(cloud_param(manifest, "DiskSize", "aliyun", "default", aws_disk))

    aws_ami = (manifest.get("images") or {}).get("aws") or DEFAULT_AWS_AMI
    aliyun_image = (manifest.get("images") or {}).get("aliyun") or DEFAULT_ALIYUN_IMAGE

    values = {
        "APP_ID": app_id,
        "APP_NAME": app_name,
        "APP_PREFIX": app_prefix,
        "AWS_INSTANCE_DEFAULT": aws_default,
        "AWS_INSTANCE_OPTIONS_CFN": ", ".join(aws_options),
        "AWS_DISK_DEFAULT": aws_disk,
        "AWS_AMI_DEFAULT": aws_ami,
        "ALIYUN_INSTANCE_DEFAULT": aliyun_default,
        "ALIYUN_INSTANCE_OPTIONS_JSON": ", ".join(json.dumps(option) for option in aliyun_options),
        "ALIYUN_DISK_DEFAULT": aliyun_disk,
        "ALIYUN_IMAGE_DEFAULT": aliyun_image,
        "APP_SECRET_PARAMS_BLOCK": build_aws_secret_params_block(manifest),
        "APP_SECRET_USERDATA_BLOCK": build_aws_secret_userdata_block(manifest),
        "APP_SECRET_USERDATA_ALIYUN": build_aliyun_secret_userdata_block(manifest),
    }

    aliyun_values = {
        **values,
        "APP_SECRET_PARAMS_BLOCK": build_aliyun_secret_params_block(manifest),
    }

    aws_out = root / "apps" / app_id / "templates" / "aws.yaml"
    aliyun_out = root / "apps" / app_id / "templates" / "aliyun.json"
    aws_out.parent.mkdir(parents=True, exist_ok=True)

    aws_text = render_template(load_template(root, "aws.yaml.tmpl"), values)
    aliyun_text = render_template(load_template(root, "aliyun.json.tmpl"), aliyun_values)

    aws_out.write_text(aws_text, encoding="utf-8")
    aliyun_out.write_text(aliyun_text, encoding="utf-8")
    print(f"  wrote {aws_out.relative_to(root)}")
    print(f"  wrote {aliyun_out.relative_to(root)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate IaC templates for catalog apps")
    parser.add_argument("app_id", nargs="?", help="Single app id to generate")
    parser.add_argument("--all", action="store_true", help="Generate for all apps except _template")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()

    root = args.root.resolve()
    if args.all:
        app_ids = sorted(
            path.parent.name
            for path in root.glob("apps/*/manifest.json")
            if path.parent.name != "_template"
        )
    elif args.app_id:
        app_ids = [args.app_id]
    else:
        parser.error("provide app_id or --all")

    for app_id in app_ids:
        manifest_path = root / "apps" / app_id / "manifest.json"
        if not manifest_path.is_file():
            fail(f"missing manifest for {app_id}: {manifest_path}")
        manifest = read_json(manifest_path)
        if manifest.get("id") and manifest["id"] != app_id:
            fail(f"{manifest_path}: id={manifest['id']} != directory {app_id}")
        tier = manifest.get("tier", "community")
        if tier not in VALID_TIERS:
            fail(f"{manifest_path}: invalid tier {tier!r}")
        print(f"==> generate-templates {app_id} (tier={tier})")
        generate_iac(root, app_id, manifest)


if __name__ == "__main__":
    main()
