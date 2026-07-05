#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/mongodb
chown -R 999:999 /opt/cloud-forge/data/mongodb
