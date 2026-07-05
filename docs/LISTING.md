# Cloud Forge Catalog — App Listing Plan

Zero-cloud-cost onboarding for new apps. Local smoke uses [毫秒镜像](https://docker.1ms.run) (`docker.1ms.run`); committed compose files keep official Docker Hub image names for production deploys.

## Tiers

| Tier | Gate | Cloud E2E |
| --- | --- | --- |
| `community` | `local-smoke.sh` pass | No |
| `certified` | Dual-cloud verify scripts | Yes (manual, costs $) |
| `experimental` | Generated only | No |

## Weekly cadence (solo)

1. Pick 5 apps, add to `apps.seed.yaml`
2. `./scripts/onboard-seed.sh --smoke` (or per-app)
3. Open PR with smoke `PASS` lines in description
4. Merge → push → CDN updates `index/apps.json` and `apps/<id>/compose/*`

Before any paid cloud deploy, run `./scripts/cdn-preflight.sh <app-id>` (see below).

## Per-app workflow

```bash
cd cloud-forge-catalog
python3 -m venv .venv && .venv/bin/pip install pyyaml   # once

# 1. Add entry to apps.seed.yaml (tier: community, pin image tag or digest)

# 2. Generate + validate + smoke
./scripts/onboard-seed.sh --smoke vaultwarden

# 3. Or batch all seed apps
./scripts/onboard-seed.sh --smoke --force
```

### Local smoke only (no cloud charges)

- Default mirror: `docker.1ms.run` via `CLOUD_FORGE_SMOKE_REGISTRY_MIRROR`
- Volumes rewritten to `.local-smoke/<app>/data` (Mac Docker cannot mount `/opt/cloud-forge`)
- Digest-pinned images use temporary `:cloud-forge-smoke` tag in smoke compose only
- Production `apps/<id>/compose/docker-compose.yml` is unchanged
- After each smoke run, `local-smoke.sh` removes pulled app images by default (`CLOUD_FORGE_SMOKE_CLEAN_IMAGES=1`) to save disk during batch onboard

```bash
./scripts/local-smoke.sh vaultwarden
./scripts/local-smoke.sh --all --tier community
```

### Promote to certified (optional, costs money)

```bash
# Edit manifest tier → certified, then:
make index validate
./scripts/cdn-preflight.sh <app-id>   # after push to main
cd ../cloud-forge-cli
./scripts/verify-aws-apps.sh
./scripts/verify-aliyun-apps.sh
```

### CDN preflight (before cloud deploy)

Local smoke and CLI `file://` dry-run use the **local** catalog. ECS bootstrap pulls `apps/<id>/compose/*` from **jsDelivr**. Run this after push/merge:

```bash
./scripts/cdn-preflight.sh stirling-pdf
./scripts/cdn-preflight.sh --all --tier community
make cdn-preflight APP=homer
```

If jsDelivr is still syncing, retry or pin a commit: `./scripts/cdn-preflight.sh --ref 897a1d3 homer`

## Selection criteria (score ≥ 12 / 15)

| Dimension | Points |
| --- | --- |
| Demand (stars, self-host search) | 0–3 |
| Fits gitea/n8n/monitoring stack | 0–3 |
| Single-container (or simple compose) | 0–2 |
| Maintainable (pinned image, docs) | 0–2 |
| BYOC / dual-cloud advantage | 0–2 |

Skip: GPU-only, Helm-only, no Docker image, unclear license.

## Batch 1 (community, onboarded)

| App | Category |
| --- | --- |
| vaultwarden | passwords |
| minio | storage |
| code-server | IDE |
| freshrss | RSS |
| it-tools | utilities |
| linkding | bookmarks |
| excalidraw | whiteboard |

## Batch 2 (next seed candidates)

portainer (needs docker.sock — special template), hoppscotch, plausible (needs DB), ghost, metabase, ollama.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLOUD_FORGE_SMOKE_REGISTRY_MIRROR` | `docker.1ms.run` | Local image pull mirror |
| `CLOUD_FORGE_SMOKE_PROBE_IMAGE` | `curlimages/curl:8.5.0` | HTTP probe sidecar |
| `CLOUD_FORGE_SMOKE_WAIT` | `90` | Default wait seconds |
| `CLOUD_FORGE_SMOKE_ADMIN_PASSWORD` | _(auto)_ | Password for apps with `AdminPassword` during local smoke |
| `CLOUD_FORGE_SMOKE_CLEAN_IMAGES` | `1` | Remove app images after each smoke run (`0` to keep for debug) |
| `CLOUD_FORGE_VERIFY_TIERS` | `certified` | Cloud verify app filter |
