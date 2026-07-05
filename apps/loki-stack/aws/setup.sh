#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/loki-stack
chown -R 10001:10001 /opt/cloud-forge/data/loki-stack
