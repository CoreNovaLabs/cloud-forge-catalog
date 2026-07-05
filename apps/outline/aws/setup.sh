#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/outline
chown -R 1001:1001 /opt/cloud-forge/data/outline
