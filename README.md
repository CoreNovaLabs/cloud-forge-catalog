# Cloud Forge Catalog

Template catalog for Cloud Forge CLI. This repository contains the generated app index (`index/apps.json`), infrastructure templates (CloudFormation / ROS), and JSON Schema for app manifests.

## Repository Layout

```
cloud-forge-catalog/
├── index/
│   └── apps.json              # Generated catalog index consumed by the CLI
├── apps/
│   ├── _template/             # Shared IaC/compose templates for generators
│   └── <app-id>/
│       ├── manifest.json      # App metadata edited by contributors
│       ├── compose/           # Shared Docker Compose + upstream (AWS + Aliyun)
│       ├── aws/               # Optional AWS-only setup.sh
│       ├── aliyun/            # Optional Aliyun-only setup.sh
│       └── templates/
│           ├── aws.yaml       # CloudFormation (generated or hand-edited)
│           └── aliyun.json    # ROS (generated or hand-edited)
├── apps.seed.yaml             # Batch app definitions for generate-app.sh
├── schema/
│   └── app-v1.schema.json     # Manifest validation schema
└── scripts/
    ├── build-index.sh         # Builds index/apps.json from app manifests
    ├── generate-templates.sh # Render aws.yaml / aliyun.json from _template
    ├── generate-app.sh      # Create a new app from apps.seed.yaml
    ├── local-smoke.sh       # Local Docker smoke tests for compose packages
    ├── cdn-preflight.sh     # Verify compose/index on jsDelivr before cloud deploy
    ├── list-verify-apps.sh  # Select apps for cloud verify by tier
    ├── validate.sh
    ├── validate_catalog.py
    ├── aws/
    │   ├── bootstrap-app.sh
    │   └── validate-sam.sh
    └── aliyun/
        ├── bootstrap-app.sh
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

Deploy and delete support **AWS** and **Aliyun** (default region `cn-hongkong`; other regions via `--region`—mainland China may fail bootstrap due to network restrictions). Both clouds load a shared app package from `apps/<id>/compose/` (Docker Compose + upstream). Cloud-specific bootstrap dispatchers (`scripts/aws/bootstrap-app.sh`, `scripts/aliyun/bootstrap-app.sh`) apply optional `aws/setup.sh` or `aliyun/setup.sh` hooks.

### Custom domains

- **AWS:** `--domain` + `--hosted-zone-id` creates a Route53 A record; bootstrap passes `CLOUD_FORGE_DOMAIN_NAME` to Caddy for domain HTTPS.
- **Aliyun:** `--domain` + `--dns-domain` creates an `ALIYUN::DNS::DomainRecord` A record (domain must be hosted in Alibaba Cloud DNS; RAM user needs DNS write access).
- **Manual DNS:** pass `--domain` only; create an A record to the stack EIP yourself.
- Without `--domain`, Caddy uses Let's Encrypt IP certificates (`ip-letsencrypt`) and `ServiceURL` is the elastic IP.

## Adding an App

### Manual

1. Copy `apps/gitea/` to `apps/<your-app>/`
2. Edit `manifest.json`, `compose/`, optional `aws/setup.sh` / `aliyun/setup.sh`
3. Run `./scripts/generate-templates.sh <app-id>` (or hand-edit templates)
4. Run `make validate && make index && ./scripts/local-smoke.sh <app-id>`
5. Open a pull request

### Batch pipeline (AI + generator)

1. Add an entry to `apps.seed.yaml`
2. Generate the app skeleton:

```bash
python3 -m pip install pyyaml   # once, for YAML seed loading
./scripts/generate-app.sh vaultwarden
```

3. Validate locally:

```bash
make generate-all              # regenerate IaC + index + validate
./scripts/local-smoke.sh vaultwarden
./scripts/local-smoke.sh --all --tier community
```

4. Promote quality with manifest `tier`:

| Tier | Meaning | Cloud verify |
| --- | --- | --- |
| `certified` | Dual-cloud E2E verified | Always included |
| `community` | Local Docker smoke passed | Optional random sample |
| `experimental` | Best effort | Excluded by default |

Cloud verify app selection (used by `cloud-forge-cli/scripts/verify-*-apps.sh`):

```bash
./scripts/list-verify-apps.sh
CLOUD_FORGE_VERIFY_TIERS=certified,community CLOUD_FORGE_VERIFY_SAMPLE=0.1 ./scripts/list-verify-apps.sh
```

Full listing plan: [docs/LISTING.md](docs/LISTING.md)

The minimal validation app is `hello-nginx`. Use it as the local acceptance sample for the CLI and catalog integration.

## Commands

```bash
make index                  # Generate index/apps.json
make validate               # Validate manifests, template paths, and index structure
make validate-aws           # Lint AWS CloudFormation templates locally with AWS SAM CLI
make generate-templates     # Regenerate aws.yaml / aliyun.json for all apps
make generate-all           # generate-templates + index + validate
make local-smoke APP=gitea  # Local Docker smoke test for one app
make local-smoke-certified  # Local smoke for all certified apps
make cdn-preflight APP=gitea  # After push: verify CDN has compose package
make onboard-smoke ARGS="vaultwarden"  # Generate + local smoke one seed app
make onboard-smoke ARGS="--force"      # Regenerate all seed apps + smoke
```

After pushing new apps to `main`, run `./scripts/cdn-preflight.sh <app-id>` before any paid `cloud-forge deploy`. Bootstrap on ECS pulls compose from jsDelivr, not from your local tree.

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
