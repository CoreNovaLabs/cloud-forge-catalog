#!/usr/bin/env python3
"""Generate a new catalog app from apps.seed.yaml and _template files."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_templates import generate_iac, render_template


DEFAULT_AWS_AMI = "ami-04cf9ac8716f030d6"
DEFAULT_ALIYUN_IMAGE = "aliyun_3_x64_20G_alibase_20260122.vhd"
VALID_TIERS = {"certified", "community", "experimental"}
VALID_CATEGORIES = {"devtools", "automation", "monitoring", "database", "cms", "other"}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_seed(path: Path) -> list[dict]:
    text = path.read_text(encoding="utf-8")
    if path.suffix in {".yaml", ".yml"}:
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            fail(f"PyYAML is required for YAML seed files: python3 -m pip install pyyaml ({exc})")
        data = yaml.safe_load(text)
    else:
        data = json.loads(text)
    apps = data.get("apps") if isinstance(data, dict) else data
    if not isinstance(apps, list) or not apps:
        fail(f"{path}: expected non-empty apps list")
    return apps


def find_seed_entry(seed_apps: list[dict], app_id: str) -> dict:
    for entry in seed_apps:
        if entry.get("id") == app_id:
            return entry
    fail(f"app id {app_id!r} not found in seed file")


def indent_block(text: str, prefix: str) -> str:
    lines = text.strip().splitlines()
    if not lines:
        return ""
    return "\n".join(f"{prefix}{line}" for line in lines)


def build_compose_env(entry: dict) -> str:
    env = entry.get("environment") or {}
    if not env:
        return ""
    lines = ["    environment:"]
    for key, value in env.items():
        lines.append(f"      - {key}={value}")
    return "\n".join(lines)


def build_compose_command(entry: dict) -> str:
    command = entry.get("command")
    if not command:
        return ""
    if isinstance(command, list):
        return f"    command: {json.dumps(command)}"
    return f"    command: {command}"


def build_compose_volumes(entry: dict, app_id: str) -> str:
    data_path = entry.get("data_path") or f"/opt/cloud-forge/data/{app_id}"
    mount = entry.get("volume_mount")
    if mount:
        host, container = mount.split(":", 1)
        host = host.replace("{{DATA_PATH}}", data_path)
        return f"      - {host}:{container}"
    return f"      - {data_path}:/data"


def build_compose_volumes_section(entry: dict, app_id: str) -> str:
    if entry.get("stateless"):
        return ""
    block = build_compose_volumes(entry, app_id)
    return f"    volumes:\n{block}\n"


def build_chown_line(entry: dict) -> str:
    uid = entry.get("uid")
    gid = entry.get("gid", uid)
    data_path = entry.get("data_path")
    if uid is None or not data_path:
        return ""
    return f"chown -R {uid}:{gid} {data_path}"


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if content.endswith("\n") else content + "\n", encoding="utf-8")
    path.chmod(0o755)


def generate_app(root: Path, entry: dict, *, force: bool = False) -> None:
    app_id = entry["id"]
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", app_id):
        fail(f"invalid app id: {app_id!r}")

    app_dir = root / "apps" / app_id
    manifest_path = app_dir / "manifest.json"
    if manifest_path.exists() and not force:
        fail(f"{manifest_path} already exists (use --force to overwrite generated files)")

    service_name = entry.get("service_name") or app_id.replace("-", "_")
    upstream_port = int(entry["port"])
    data_path = entry.get("data_path") or f"/opt/cloud-forge/data/{app_id}"
    tier = entry.get("tier", "community")
    if tier not in VALID_TIERS:
        fail(f"invalid tier: {tier!r}")

    category = entry.get("category", "other")
    if category not in VALID_CATEGORIES:
        fail(f"invalid category: {category!r}")

    aws_instance_default = entry.get("aws_instance_default", "t3.small")
    aws_instance_options = entry.get("aws_instance_options", [aws_instance_default])
    aliyun_instance_default = entry.get("aliyun_instance_default", "ecs.t6-c1m1.large")
    aliyun_instance_options = entry.get(
        "aliyun_instance_options",
        [aliyun_instance_default],
    )
    aws_disk = str(entry.get("aws_disk_gb", 20))
    aliyun_disk = str(entry.get("aliyun_disk_gb", aws_disk))
    smoke_paths = entry.get("smoke_health_paths", ["/", "/health"])
    smoke_wait = int(entry.get("smoke_wait_seconds", 90))
    tags = entry.get("tags") or [app_id, "self-hosted"]

    template_values = {
        "APP_ID": app_id,
        "APP_NAME": entry.get("name", app_id),
        "APP_DESC": entry.get("desc", f"Deploy {entry.get('name', app_id)} with Cloud Forge"),
        "APP_ICON": entry.get("icon", "📦"),
        "CATEGORY": category,
        "TAGS_JSON": json.dumps(tags, ensure_ascii=False),
        "STARS": str(int(entry.get("stars", 0))),
        "TIER": tier,
        "AWS_AMI_DEFAULT": entry.get("aws_ami", DEFAULT_AWS_AMI),
        "ALIYUN_IMAGE_DEFAULT": entry.get("aliyun_image", DEFAULT_ALIYUN_IMAGE),
        "AWS_INSTANCE_DEFAULT": aws_instance_default,
        "AWS_INSTANCE_OPTIONS_JSON": json.dumps(aws_instance_options),
        "ALIYUN_INSTANCE_DEFAULT": aliyun_instance_default,
        "ALIYUN_INSTANCE_OPTIONS_JSON_ARRAY": json.dumps(aliyun_instance_options),
        "AWS_DISK_DEFAULT": aws_disk,
        "ALIYUN_DISK_DEFAULT": aliyun_disk,
        "SMOKE_HEALTH_PATHS_JSON": json.dumps(smoke_paths),
        "SMOKE_WAIT_SECONDS": str(smoke_wait),
        "SERVICE_NAME": service_name,
        "DOCKER_IMAGE": entry["image"],
        "UPSTREAM_PORT": str(upstream_port),
        "DATA_PATH": data_path,
        "COMPOSE_ENV_BLOCK": build_compose_env(entry),
        "COMPOSE_COMMAND_BLOCK": build_compose_command(entry),
        "COMPOSE_VOLUMES_SECTION": build_compose_volumes_section(entry, app_id),
        "CHOWN_LINE": build_chown_line(entry),
    }

    template_dir = root / "apps" / "_template"

    compose_yml = render_template(
        (template_dir / "compose" / "docker-compose.yml.tmpl").read_text(encoding="utf-8"),
        template_values,
    )
    app_env = render_template(
        (template_dir / "compose" / "app.env.tmpl").read_text(encoding="utf-8"),
        template_values,
    )
    aws_setup = render_template(
        (template_dir / "aws" / "setup.sh.tmpl").read_text(encoding="utf-8"),
        template_values,
    )
    aliyun_setup = render_template(
        (template_dir / "aliyun" / "setup.sh.tmpl").read_text(encoding="utf-8"),
        template_values,
    )
    manifest = render_template(
        (template_dir / "manifest.json.tmpl").read_text(encoding="utf-8"),
        template_values,
    )

    (app_dir / "compose").mkdir(parents=True, exist_ok=True)
    (app_dir / "compose" / "docker-compose.yml").write_text(compose_yml, encoding="utf-8")
    (app_dir / "compose" / "app.env").write_text(app_env, encoding="utf-8")
    write_executable(app_dir / "aws" / "setup.sh", aws_setup)
    write_executable(app_dir / "aliyun" / "setup.sh", aliyun_setup)
    manifest_path.write_text(manifest, encoding="utf-8")

    manifest_data = json.loads(manifest)
    generate_iac(root, app_id, manifest_data)
    print(f"==> generated app {app_id} at apps/{app_id}/")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate catalog app from seed entry")
    parser.add_argument("app_id", help="App id defined in apps.seed.yaml")
    parser.add_argument(
        "--seed",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "apps.seed.yaml",
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--force", action="store_true", help="Overwrite existing app files")
    args = parser.parse_args()

    root = args.root.resolve()
    seed_path = args.seed.resolve()
    if not seed_path.is_file():
        fail(f"seed file not found: {seed_path}")

    entry = find_seed_entry(load_seed(seed_path), args.app_id)
    generate_app(root, entry, force=args.force)


if __name__ == "__main__":
    main()
