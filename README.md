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
│       └── templates/
│           ├── aws.yaml       # CloudFormation
│           └── aliyun.json    # ROS
├── schema/
│   └── app-v1.schema.json     # Manifest validation schema
└── scripts/
    └── build-index.sh         # Builds index/apps.json from app manifests
```

## CLI Integration

The CLI fetches the catalog index over HTTP and downloads templates on demand:

```yaml
# ~/.cloud-forge/config.yaml
store:
  url: https://raw.githubusercontent.com/CoreNovaLabs/cloud-forge-catalog/main/index/apps.json
  cache_ttl: 24h
```

For local development, use a `file://` URL:

```bash
export CLOUD_FORGE_STORE_URL="file:///path/to/cloud-forge-catalog/index/apps.json"
```

## Adding an App

1. Copy `apps/gitea/` to `apps/<your-app>/`
2. Edit `manifest.json` and the template files
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

- Catalog versions follow SemVer and are published through Git tags, for example `v1.0.0`
- The CLI can pin a catalog version with `--catalog-version v1.0.0`
