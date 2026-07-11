#!/usr/bin/env bash
set -euo pipefail

sudo install -d -m 0755 /opt/cloud-forge/data/nginx/html
sudo tee /opt/cloud-forge/data/nginx/html/index.html >/dev/null <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Cloud Forge</title></head>
<body><h1>Cloud Forge NGINX</h1><p>NGINX is running on Alibaba Cloud.</p></body>
</html>
HTML
sudo chmod 0644 /opt/cloud-forge/data/nginx/html/index.html
