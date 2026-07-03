# Changelog

All notable changes to Cloud Forge Catalog are documented in this file.

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

- Aliyun templates remain in the catalog for future deploy support
- Aliyun image IDs are still placeholders until Aliyun deploy is implemented
