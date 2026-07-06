# Changelog

All notable changes to Cloud Forge Catalog are documented in this file.

## [Unreleased]

## [0.3.4] - 2026-07-06

### Fixed

- Aliyun templates now output `ServiceURL` with the actual EIP address when no custom domain is configured, instead of using the EIP allocation id/name from `Ref`.
- Regenerated catalog template checksums and `catalog_version: 0.3.4`.

## [0.3.3] - 2026-07-06

### Fixed

- Direct TCP AWS templates no longer emit the unused `UseHttp` condition.
- `scripts/build-index.sh` now centralizes the catalog version and generates `catalog_version: 0.3.3`.

### Added

- Batch 1 community apps: `vaultwarden`, `minio`, `code-server`, `freshrss`, `it-tools`, `linkding`, `excalidraw`
- `docs/LISTING.md` onboarding plan (local smoke only, zero cloud cost)
- `scripts/onboard-seed.sh` to generate seed apps and optional smoke tests
- `apps/_template/` shared templates for IaC and compose generation
- `scripts/generate-templates.sh` and `scripts/generate_app.py` to render `aws.yaml` / `aliyun.json` from manifests
- `scripts/generate-app.sh` and `apps.seed.yaml` for batch app scaffolding
- `scripts/local-smoke.sh` for local Docker compose smoke tests
- `scripts/list-verify-apps.sh` for tier-based cloud verify app selection
- Manifest `tier` field (`certified` | `community` | `experimental`) and optional `smoke` probe config
- Local smoke: `docker.1ms.run` mirror pulls, `.local-smoke/` volume rewrite, digest smoke tags

### Changed

- `local-smoke.sh` supports `CLOUD_FORGE_SMOKE_REGISTRY_MIRROR` (default `docker.1ms.run`)
- `index/apps.json` now lists 11 apps (4 certified + 7 community)
- Existing four apps marked `tier: certified` with smoke health paths
- Regenerated AWS/Aliyun templates from `_template` for all current apps
- `cloud-forge-cli` verify scripts now read app lists from `list-verify-apps.sh`

## [0.3.0] - 2026-07-04

### Added

- Aliyun bootstrap scripts: `scripts/aliyun/bootstrap-runtime.sh`, `bootstrap-app.sh`, `install-caddy-aliyun.sh`
- Production ROS templates for `hello-nginx`, `gitea`, `n8n`, and `uptime-kuma` (public Alinux3 + UserData + Docker Hub)
- `hello-nginx` Aliyun manifest and template
- Shared Docker Compose and upstream env under `apps/<id>/compose/` for AWS and Aliyun; `scripts/aws/bootstrap-app.sh` and thin CloudFormation UserData

### Changed

- Replaced placeholder Aliyun image IDs with public `aliyun_3_x64_20G_alibase_20260122.vhd` defaults
- Updated `cost_notice` and `min_cli_version: 0.3.0` for Aliyun deploy
- Reorganized cloud-specific scripts under `scripts/aws/` and `scripts/aliyun/`; SAM validation at `scripts/aws/validate-sam.sh`
- Aliyun bootstrap loads the shared compose package instead of per-cloud compose files
- Set `gitea` and `uptime-kuma` catalog price to `free`
- Fixed hello-nginx static file permissions for nginx container (`umask 022` in bootstrap)
- Regenerated `index/apps.json` with `catalog_version: 0.3.0`

### Notes

- Override `--image-id` if the public image ID changes in cn-hongkong
- Aliyun v1 is cn-hongkong only; mainland regions are deferred

## [0.2.0] - 2026-07-03

### Added

- Production-ready AWS templates for `gitea`, `n8n`, and `uptime-kuma`
- Shared Cloud Forge hardened runtime AMI defaults (`ami-04cf9ac8716f030d6`, Caddy via Docker Compose)
- Docker Compose + Caddy reverse-proxy UserData for all AWS app templates
- MIT License

### Changed

- Replaced placeholder AMI IDs with the hardened runtime AMI for AWS deployments
- Aligned app manifests with hello-nginx parameter conventions (`LatestAmiId`, optional `KeyName`, `CaddyTlsMode`)
- Regenerated `index/apps.json` for four deployable AWS apps
- Unified AWS UserData on Docker Compose: platform Caddy from AMI + per-app `docker-compose.app.yml` on the `cloud-forge` network
- `hello-nginx` now runs NGINX in Docker instead of a host package install
- App templates pass `CLOUD_FORGE_CADDY_PUBLIC_IP` from the stack Elastic IP for stable IP HTTPS

### Notes

- Aliyun ROS templates remain in the catalog for future deploy support
- Aliyun image IDs are still placeholders until Aliyun deploy is implemented
