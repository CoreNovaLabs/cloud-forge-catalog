#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/postgresql
chown -R 999:999 /opt/cloud-forge/data/postgresql
