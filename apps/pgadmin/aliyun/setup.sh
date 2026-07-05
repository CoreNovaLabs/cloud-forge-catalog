#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/pgadmin
chown -R 5050:5050 /opt/cloud-forge/data/pgadmin
