#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/nextcloud
chown -R 33:33 /opt/cloud-forge/data/nextcloud
