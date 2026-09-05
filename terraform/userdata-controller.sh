#!/bin/bash
# userdata-controller.sh — runs once at instance boot
# Installs packages needed on the Ansible controller

apt-get update -y || (sleep 10 && apt-get update -y)

# Install Python pip (provides python3 -m pip, not the pip3 command directly)
for i in 1 2 3 4 5; do
  apt-get install -y python3-pip python3-venv && break
  sleep 10
done

# Install Ansible and AWS CLI via python3 -m pip (more reliable than pip3 command)
python3 -m pip install ansible awscli --break-system-packages

# Install Docker (for building images)
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker