# Cloud Forge Catalog

Template catalog for Cloud Forge CLI. This repository contains the generated app index (`index/apps.json`), infrastructure templates (CloudFormation / ROS), and JSON Schema for app manifests.

## Repository Layout

```
cloud-forge-catalog/
├── index/
│   └── apps.json              # Generated catalog index consumed by the CLI
├── apps/
│   └── <app-id>/
│       ├── manifest.json      # App metadata edited by contributors
│       ├── compose/           # Shared Docker Compose + upstream (AWS + Aliyun)
│       ├── aws/               # Optional AWS-only setup.sh
│       ├── aliyun/            # Optional Aliyun-only setup.sh
│       └── templates/
│           ├── aws.yaml       # CloudFormation (thin UserData)
│           └── aliyun.json    # ROS
├── schema/
│   └── app-v1.schema.json     # Manifest validation schema
└── scripts/
    ├── build-index.sh         # Builds index/apps.json from app manifests
    ├── validate.sh            # Manifest + index validation (all clouds)
    ├── validate_catalog.py
    ├── aws/
    │   ├── bootstrap-app.sh   # Instance bootstrap on pre-baked AMI
    │   └── validate-sam.sh    # Local AWS CloudFormation lint (SAM CLI)
    └── aliyun/
        ├── bootstrap-app.sh   # Instance bootstrap dispatcher
        ├── bootstrap-runtime.sh
        └── install-caddy-aliyun.sh
```

## CLI Integration

The CLI fetches the catalog index over HTTP and downloads templates on demand.

Default index URL (configured in the CLI):

```text
https://cdn.jsdelivr.net/gh/CoreNovaLabs/cloud-forge-catalog@main/index/apps.json
```

Override with an environment variable:

```bash
export CLOUD_FORGE_STORE_URL="https://raw.githubusercontent.com/CoreNovaLabs/cloud-forge-catalog/main/index/apps.json"
export CLOUD_FORGE_STORE_URL="file:///path/to/cloud-forge-catalog/index/apps.json"
```

Deploy and delete support **AWS** and **Aliyun (`cn-hongkong`)**. Both clouds load a shared app package from `apps/<id>/compose/` (Docker Compose + upstream). Cloud-specific bootstrap dispatchers (`scripts/aws/bootstrap-app.sh`, `scripts/aliyun/bootstrap-app.sh`) apply optional `aws/setup.sh` or `aliyun/setup.sh` hooks.

## Adding an App

1. Copy `apps/gitea/` to `apps/<your-app>/`
2. Edit `manifest.json`, templates, `compose/docker-compose.yml`, `compose/app.env`, and optional cloud setup scripts
3. Run `make validate && make index`
4. Open a pull request

The minimal validation app is `hello-nginx`. It contains an AWS CloudFormation template that uses the public Amazon Linux 2023 SSM AMI parameter to install and start NGINX. Use it as the local acceptance sample for the CLI and catalog integration.

## Commands

```bash
make index        # Generate index/apps.json
make validate     # Validate manifests, template paths, and index structure
make validate-aws # Lint AWS CloudFormation templates locally with AWS SAM CLI
```

`make validate-aws` only runs local template linting. It does not create a CloudFormation stack, start EC2 instances, or allocate EIPs. It is useful for catching CloudFormation/SAM syntax and static rule issues before a commit. Runtime checks such as AMI availability, instance type availability in a target Region, and IAM permissions still require a Change Set or a sandbox AWS account.

Local dependencies:

```bash
brew tap aws/tap
brew install aws-sam-cli
python3 -m pip install cfn-lint
```

## Versioning

- Catalog versions follow SemVer and are published through Git tags, for example `v0.2.0`
- The CLI reads the catalog index from the default CDN URL or `CLOUD_FORGE_STORE_URL`
