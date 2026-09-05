#!/bin/bash
# userdata-web.sh — runs once at instance boot
# Installs packages needed on the web server
# Docker is required for the app container + python3-pip for awscli (ECR login)

apt-get update -y || (sleep 10 && apt-get update -y)

curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

for i in 1 2 3 4 5; do
  apt-get install -y python3-pip && break
  sleep 10
done