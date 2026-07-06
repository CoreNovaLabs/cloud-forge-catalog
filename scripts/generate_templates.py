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
# Pin jsdelivr when @main is stale; bump with catalog releases that change bootstrap scripts.
CATALOG_CDN_REF = "66fb52b"
VALID_TIERS = {"certified", "community", "experimental"}
DIRECT_TCP_ROLES = {"db", "tcp"}


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


def app_role(manifest: dict) -> str:
    return str(manifest.get("ami_role") or "web")


def is_direct_tcp(manifest: dict) -> bool:
    return app_role(manifest) in DIRECT_TCP_ROLES


def service_scheme(manifest: dict, app_id: str) -> str:
    if manifest.get("service_scheme"):
        return str(manifest["service_scheme"])
    return {
        "postgresql": "postgresql",
        "mariadb": "mysql",
        "redis": "redis",
        "mongodb": "mongodb",
    }.get(app_id, "tcp")


def service_port(manifest: dict) -> int:
    value = manifest.get("service_port")
    if value is None:
        return 0
    return int(value)


def app_prefix(app_id: str) -> str:
    return to_pascal(app_id)


def build_aws_security_group_ingress_block(manifest: dict) -> str:
    port = service_port(manifest)
    if is_direct_tcp(manifest) and port > 0:
        return (
            "        - IpProtocol: tcp\n"
            f"          FromPort: {port}\n"
            f"          ToPort: {port}\n"
            "          CidrIp: !Ref AllowedIP\n"
        )
    return (
        "        - IpProtocol: tcp\n"
        "          FromPort: 80\n"
        "          ToPort: 80\n"
        "          CidrIp: 0.0.0.0/0\n"
        "        - IpProtocol: tcp\n"
        "          FromPort: 443\n"
        "          ToPort: 443\n"
        "          CidrIp: 0.0.0.0/0\n"
    )


def build_aws_use_http_condition_block(manifest: dict) -> str:
    if is_direct_tcp(manifest):
        return ""
    return "  UseHttp: !Equals [!Ref CaddyTlsMode, http]"


def build_aliyun_security_group_ingress_block(manifest: dict) -> str:
    port = service_port(manifest)
    if is_direct_tcp(manifest) and port > 0:
        return (
            "[\n"
            f'          {{ "IpProtocol": "tcp", "PortRange": "{port}/{port}", "SourceCidrIp": {{ "Ref": "AllowedIP" }} }},\n'
            '          { "IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": { "Ref": "AllowedIP" } }\n'
            "        ]"
        )
    return (
        "[\n"
        '          { "IpProtocol": "tcp", "PortRange": "80/80", "SourceCidrIp": "0.0.0.0/0" },\n'
        '          { "IpProtocol": "tcp", "PortRange": "443/443", "SourceCidrIp": "0.0.0.0/0" },\n'
        '          { "IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": { "Ref": "AllowedIP" } }\n'
        "        ]"
    )


def build_aws_service_url_value(manifest: dict, app_id: str) -> str:
    prefix = app_prefix(app_id)
    port = service_port(manifest)
    if is_direct_tcp(manifest):
        scheme = service_scheme(manifest, app_id)
        if port <= 0:
            port = 0
        return (
            "!If\n"
            "      - HasDomain\n"
            f"      - !Sub '{scheme}://${{DomainName}}:{port}'\n"
            "      - !Sub '" + scheme + "://${" + prefix + "EIP}:" + str(port) + "'"
        )
    return (
        "!If\n"
        "      - HasDomain\n"
        "      - !If\n"
        "        - UseHttp\n"
        "        - !Sub 'http://${DomainName}'\n"
        "        - !Sub 'https://${DomainName}'\n"
        "      - !If\n"
        "        - UseHttp\n"
        "        - !Sub 'http://${" + prefix + "EIP}'\n"
        "        - !Sub 'https://${" + prefix + "EIP}'"
    )


def build_aliyun_service_url_value(manifest: dict, app_id: str) -> str:
    prefix = app_prefix(app_id)
    port = service_port(manifest)
    eip_address = {"Fn::GetAtt": [f"{prefix}EIP", "EipAddress"]}
    if is_direct_tcp(manifest):
        scheme = service_scheme(manifest, app_id)
        return json.dumps(
            {
                "Fn::If": [
                    "HasDomain",
                    {"Fn::Sub": f"{scheme}://${{DomainName}}:{port}"},
                    {"Fn::Join": ["", [f"{scheme}://", eip_address, f":{port}"]]},
                ]
            },
            ensure_ascii=False,
        )
    return json.dumps(
        {
            "Fn::If": [
                "HasDomain",
                {
                    "Fn::If": [
                        "UseHttp",
                        {"Fn::Sub": "http://${DomainName}"},
                        {"Fn::Sub": "https://${DomainName}"},
                    ]
                },
                {
                    "Fn::If": [
                        "UseHttp",
                        {"Fn::Join": ["", ["http://", eip_address]]},
                        {"Fn::Join": ["", ["https://", eip_address]]},
                    ]
                },
            ]
        },
        ensure_ascii=False,
    )


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
        "APP_SECURITY_GROUP_INGRESS_BLOCK": build_aws_security_group_ingress_block(manifest),
        "APP_USE_HTTP_CONDITION_BLOCK": build_aws_use_http_condition_block(manifest),
        "APP_SERVICE_URL_VALUE": build_aws_service_url_value(manifest, app_id),
        "CATALOG_CDN_REF": CATALOG_CDN_REF,
    }

    aliyun_values = {
        **values,
        "APP_SECRET_PARAMS_BLOCK": build_aliyun_secret_params_block(manifest),
        "APP_SECURITY_GROUP_INGRESS_BLOCK": build_aliyun_security_group_ingress_block(manifest),
        "APP_SERVICE_URL_VALUE": build_aliyun_service_url_value(manifest, app_id),
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
