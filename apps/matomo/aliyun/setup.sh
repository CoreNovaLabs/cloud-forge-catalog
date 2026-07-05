#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/matomo
chown -R 1000:1000 /opt/cloud-forge/data/matomo
