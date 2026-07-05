#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/grafana
chown -R 472:472 /opt/cloud-forge/data/grafana
