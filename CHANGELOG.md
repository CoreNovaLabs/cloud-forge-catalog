# Changelog

All notable changes to Cloud Forge Catalog are documented in this file.

## [0.3.0] - 2026-07-04

### Added

- Aliyun bootstrap scripts: `scripts/aliyun/bootstrap-runtime.sh`, `bootstrap-app.sh`, `install-caddy-aliyun.sh`
- Production ROS templates for `hello-nginx`, `gitea`, `n8n`, and `uptime-kuma` (public Alinux3 + UserData + Docker Hub)
- `hello-nginx` Aliyun manifest and template

### Changed

- Replaced placeholder Aliyun image IDs with public `aliyun_3_x64_20G_alibase_20260122.vhd` defaults
- Updated `cost_notice` and `min_cli_version: 0.3.0` for Aliyun deploy
- Regenerated `index/apps.json`

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
