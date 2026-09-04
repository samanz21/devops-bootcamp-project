#!/bin/bash
# userdata-monitoring.sh — runs once at instance boot
# Installs packages needed on the monitoring server
# Docker for Prometheus/Grafana stack, cloudflared for Cloudflare Tunnel

apt-get update -y

curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

# Install cloudflared (Cloudflare Tunnel)
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update -y && apt-get install -y cloudflared