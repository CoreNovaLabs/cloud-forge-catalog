#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/alertmanager
chown -R 65534:65534 /opt/cloud-forge/data/alertmanager
