#!/bin/bash
# ==============================================================================
# setup-controller.sh — hybrid approach: run after terraform apply
#
# Usage:   bash setup-controller.sh
# Requires: terraform/ applied, ansible/ terraform applied, aws CLI + SSM plugin
#
# What it does:
#   1. Detects instance IDs automatically
#   2. Waits for SSM Online on all 3 instances
#   3. Waits for cloud-init to finish on all 3 instances
#   4. Self-heals Ansible on the controller (installs pip/ansible/awscli
#      via SSM if user_data failed — e.g. transient apt mirror errors)
#   5. Generates SSH key on the controller
#   6. Distributes the public key to web & monitoring
#   7. Copies all ansible + grafana files to the controller
#   8. Accepts SSH host keys on controller
#   9. Runs playbook-connectivity.yaml (connectivity test)
#  10. Installs geerlingguy.docker role + community.docker collection
#  11. Runs playbook-docker.yaml (install Docker on web & monitoring)
#  12. Installs prometheus.prometheus collection
#  13. Runs playbook-node-exporter.yaml (install node_exporter on web)
#  14. Runs playbook-monitoring.yaml (deploy Prometheus + Grafana)
#  15. Retrieves tunnel token and installs Cloudflare Tunnel on monitoring
#  16. Runs playbook-web.yaml (deploy app container from existing ECR image)
#
# Package installs (Ansible, Docker, AWS CLI, cloudflared) are handled by
# user_data scripts in terraform/ — no waiting for apt-get here.
#
# On re-deploy (terraform destroy + apply), just run this script again.
# ==============================================================================

set -e

REGION="ap-southeast-1"
echo "=== Getting instance IDs ==="
CTRL_ID=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=devops-ansible-controller" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
WEB_ID=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=devops-web-server" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
MON_ID=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=devops-monitoring-server" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
echo "  Controller: $CTRL_ID"
echo "  Web:        $WEB_ID"
echo "  Monitoring: $MON_ID"

echo ""
echo "=== Waiting for SSM Online on all instances ==="
MAX_RETRIES=60  # 10 minutes max (60 * 10s)
RETRY=0
while true; do
  if [ $RETRY -ge $MAX_RETRIES ]; then
    echo "  ERROR: timeout waiting for SSM Online after $((MAX_RETRIES * 10)) seconds"
    echo "  Check that instances exist and have the EC2-SSM-Role IAM profile attached."
    echo "  Also check for terminated instances with the same tags in EC2 console."
    exit 1
  fi

  CTRL_STATUS=$(aws ssm describe-instance-information --region $REGION --filters "Key=InstanceIds,Values=$CTRL_ID" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "not found")
  WEB_STATUS=$(aws ssm describe-instance-information --region $REGION --filters "Key=InstanceIds,Values=$WEB_ID" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "not found")
  MON_STATUS=$(aws ssm describe-instance-information --region $REGION --filters "Key=InstanceIds,Values=$MON_ID" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "not found")

  echo "  Controller: $CTRL_STATUS | Web: $WEB_STATUS | Monitoring: $MON_STATUS"

  if [ "$CTRL_STATUS" = "Online" ] && [ "$WEB_STATUS" = "Online" ] && [ "$MON_STATUS" = "Online" ]; then
    echo "  All instances Online"
    break
  fi

  RETRY=$((RETRY + 1))
  sleep 10
done

echo ""
echo "=== Waiting for cloud-init to finish on all instances ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" "$WEB_ID" "$MON_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["cloud-init status --wait"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: cloud-init failed on an instance" && exit 1
  sleep 10
done

echo ""
echo "=== Ensuring Ansible is installed on controller (self-heal) ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["command -v ansible-playbook >/dev/null 2>&1 && echo ANSIBLE_OK || (apt-get update -y || (sleep 10 && apt-get update -y)) && apt-get install -y python3-pip python3-venv && python3 -m pip install ansible awscli --break-system-packages && echo ANSIBLE_INSTALLED"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: ansible bootstrap failed on controller" && exit 1
  sleep 10
done

echo ""
echo "=== Generating SSH key on controller ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu mkdir -p /home/ubuntu/.ssh","sudo -u ubuntu ssh-keygen -t ed25519 -f /home/ubuntu/.ssh/id_ed25519 -N \"\" -q","sudo -u ubuntu cat /home/ubuntu/.ssh/id_ed25519.pub"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
sleep 5
PUB_KEY=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'StandardOutputContent' --output text)
echo "  Public key: $PUB_KEY"

echo ""
echo "=== Distributing SSH key to web & monitoring ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$WEB_ID" "$MON_ID" --document-name "AWS-RunShellScript" --parameters "commands=[\"sudo -u ubuntu mkdir -p /home/ubuntu/.ssh\",\"echo '$PUB_KEY' >> /home/ubuntu/.ssh/authorized_keys\",\"chmod 600 /home/ubuntu/.ssh/authorized_keys\"]" --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$WEB_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: key distribution failed" && exit 1
  sleep 5
done

echo ""
echo "=== Copying ansible files to controller ==="
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INV_B64=$(base64 -w0 "$SCRIPT_DIR/inventory.ini")
CFG_B64=$(base64 -w0 "$SCRIPT_DIR/ansible.cfg")
CONN_B64=$(base64 -w0 "$SCRIPT_DIR/playbook-connectivity.yaml")
DOCKER_B64=$(base64 -w0 "$SCRIPT_DIR/playbook-docker.yaml")
WEB_B64=$(base64 -w0 "$SCRIPT_DIR/playbook-web.yaml")
REQ_B64=$(base64 -w0 "$SCRIPT_DIR/requirements.yml")
MON_B64=$(base64 -w0 "$SCRIPT_DIR/playbook-monitoring.yaml")
NEXP_B64=$(base64 -w0 "$SCRIPT_DIR/playbook-node-exporter.yaml")
COMPOSE_B64=$(base64 -w0 "$SCRIPT_DIR/grafana/compose.yaml")
PROM_B64=$(base64 -w0 "$SCRIPT_DIR/grafana/prometheus.yaml")
DS_B64=$(base64 -w0 "$SCRIPT_DIR/grafana/provisioning/datasources/datasource.yaml")
DP_B64=$(base64 -w0 "$SCRIPT_DIR/grafana/provisioning/dashboards/dashboard-provider.yaml")
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters "commands=[\"sudo -u ubuntu mkdir -p /home/ubuntu/ansible/grafana/provisioning/datasources\",\"sudo -u ubuntu mkdir -p /home/ubuntu/ansible/grafana/provisioning/dashboards\",\"echo $INV_B64 | base64 -d > /home/ubuntu/ansible/inventory.ini\",\"echo $CFG_B64 | base64 -d > /home/ubuntu/ansible/ansible.cfg\",\"echo $CONN_B64 | base64 -d > /home/ubuntu/ansible/playbook-connectivity.yaml\",\"echo $DOCKER_B64 | base64 -d > /home/ubuntu/ansible/playbook-docker.yaml\",\"echo $WEB_B64 | base64 -d > /home/ubuntu/ansible/playbook-web.yaml\",\"echo $REQ_B64 | base64 -d > /home/ubuntu/ansible/requirements.yml\",\"echo $MON_B64 | base64 -d > /home/ubuntu/ansible/playbook-monitoring.yaml\",\"echo $NEXP_B64 | base64 -d > /home/ubuntu/ansible/playbook-node-exporter.yaml\",\"echo $COMPOSE_B64 | base64 -d > /home/ubuntu/ansible/grafana/compose.yaml\",\"echo $PROM_B64 | base64 -d > /home/ubuntu/ansible/grafana/prometheus.yaml\",\"echo $DS_B64 | base64 -d > /home/ubuntu/ansible/grafana/provisioning/datasources/datasource.yaml\",\"echo $DP_B64 | base64 -d > /home/ubuntu/ansible/grafana/provisioning/dashboards/dashboard-provider.yaml\",\"chown -R ubuntu:ubuntu /home/ubuntu/ansible\"]" --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: file copy failed" && exit 1
  sleep 5
done

echo ""
echo "=== Downloading Node Exporter Full dashboard on controller ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters "commands=[\"sudo -u ubuntu curl -sL 'https://grafana.com/api/dashboards/1860/revisions/latest/download' -o /home/ubuntu/ansible/grafana/provisioning/dashboards/node-exporter-full.json\",\"chown ubuntu:ubuntu /home/ubuntu/ansible/grafana/provisioning/dashboards/node-exporter-full.json\",\"ls -la /home/ubuntu/ansible/grafana/provisioning/dashboards/\"]" --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: dashboard download failed" && exit 1
  sleep 5
done

echo ""
echo "=== Fetching private IPs for SSH host key scan ==="
WEB_IP=$(aws ec2 describe-instances --region $REGION --instance-ids "$WEB_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
MON_IP=$(aws ec2 describe-instances --region $REGION --instance-ids "$MON_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "  Web IP:        $WEB_IP"
echo "  Monitoring IP: $MON_IP"

echo ""
echo "=== Accepting SSH host keys on controller ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters "commands=[\"sudo -u ubuntu ssh-keyscan -H $WEB_IP $MON_IP >> /home/ubuntu/.ssh/known_hosts 2>/dev/null\"]" --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: ssh-keyscan failed" && exit 1
  sleep 5
done

echo ""
echo "=== Running connectivity playbook ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-playbook -i /home/ubuntu/ansible/inventory.ini /home/ubuntu/ansible/playbook-connectivity.yaml"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
sleep 15
RESULT=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query '{Status:Status,Output:StandardOutputContent}' --output json)
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

echo ""
echo "=== Installing geerlingguy.docker role + community.docker collection ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-galaxy role install -r /home/ubuntu/ansible/requirements.yml","sudo -u ubuntu ansible-galaxy collection install community.docker"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: role install failed" && exit 1
  sleep 10
done

echo ""
echo "=== Installing Docker on web & monitoring (playbook-docker.yaml) ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-playbook -i /home/ubuntu/ansible/inventory.ini /home/ubuntu/ansible/playbook-docker.yaml"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
sleep 15
RESULT=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query '{Status:Status,Output:StandardOutputContent}' --output json)
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

echo ""
echo "=== Installing prometheus.prometheus.node_exporter role ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-galaxy collection install prometheus.prometheus"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: role install failed" && exit 1
  sleep 10
done

echo ""
echo "=== Installing node_exporter on web server (playbook-node-exporter.yaml) ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-playbook -i /home/ubuntu/ansible/inventory.ini /home/ubuntu/ansible/playbook-node-exporter.yaml"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
sleep 15
RESULT=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query '{Status:Status,Output:StandardOutputContent}' --output json)
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

echo ""
echo "=== Deploying Prometheus & Grafana (playbook-monitoring.yaml) ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-playbook -i /home/ubuntu/ansible/inventory.ini /home/ubuntu/ansible/playbook-monitoring.yaml"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
sleep 15
RESULT=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query '{Status:Status,Output:StandardOutputContent}' --output json)
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

echo ""
echo "=== Fetching tunnel token from SSM Parameter Store ==="
TUNNEL_TOKEN=$(aws ssm get-parameter --name /devops-bootcamp-2026/tunnel-token --with-decryption --region $REGION --query Parameter.Value --output text)
echo "  Token retrieved"

echo ""
echo "=== Installing Cloudflare Tunnel service ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$MON_ID" --document-name "AWS-RunShellScript" --parameters "commands=[\"sudo cloudflared service uninstall >/dev/null 2>&1; sudo cloudflared service install $TUNNEL_TOKEN\"]" --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$MON_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: tunnel install failed" && exit 1
  sleep 5
done

echo ""
echo "=== Deploying app container (playbook-web.yaml) ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-playbook -i /home/ubuntu/ansible/inventory.ini /home/ubuntu/ansible/playbook-web.yaml"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
sleep 15
RESULT=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query '{Status:Status,Output:StandardOutputContent}' --output json)
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

echo ""
echo "=== DONE ==="
echo "App should be live at: http://$(aws ec2 describe-instances --region $REGION --instance-ids "$WEB_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"