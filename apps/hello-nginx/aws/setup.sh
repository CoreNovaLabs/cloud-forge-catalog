#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/cloud-forge/data/hello-nginx/html
tee /opt/cloud-forge/data/hello-nginx/html/index.html >/dev/null <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Cloud Forge</title></head>
<body><h1>Hello from Cloud Forge</h1><p>NGINX is running on AWS.</p></body>
</html>
HTML
