#!/usr/bin/env bash
set -euo pipefail

sudo install -d -m 0755 /opt/cloud-forge/data/n8n
sudo chown -R 1000:1000 /opt/cloud-forge/data/n8n
