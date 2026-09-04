#!/bin/bash
# userdata-controller.sh — runs once at instance boot
# Installs packages needed on the Ansible controller

apt-get update -y

# Install Ansible via pip (apt package 'ansible' not available on Ubuntu 24)
apt-get install -y python3-pip
pip3 install ansible --break-system-packages

# Install Docker (for building images)
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

# Install AWS CLI (for ECR push, SSM param read)
pip3 install awscli --break-system-packages