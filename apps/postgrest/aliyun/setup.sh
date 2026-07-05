#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/postgrest
chown -R 1000:1000 /opt/cloud-forge/data/postgrest
