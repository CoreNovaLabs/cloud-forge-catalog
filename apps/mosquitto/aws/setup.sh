#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/mosquitto
chown -R 1883:1883 /opt/cloud-forge/data/mosquitto
