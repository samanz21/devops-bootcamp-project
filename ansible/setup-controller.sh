#!/bin/bash
# ==============================================================================
# setup-controller.sh — fully automated phase 2a + 2b setup (run from laptop)
#
# Usage:   bash setup-controller.sh
# Requires: terraform/ applied, ansible/ terraform applied, aws CLI + SSM plugin
#
# What it does:
#   1. Detects instance IDs automatically
#   2. Waits for SSM Online on all 3 instances
#   3. Installs Ansible on the controller
#   4. Generates SSH key on the controller
#   5. Distributes the public key to web & monitoring
#   6. Copies all ansible + grafana files to the controller
#   7. Installs geerlingguy.docker role + community.docker collection
#   8. Runs playbook-connectivity.yaml (connectivity test)
#   9. Runs playbook-docker.yaml (install Docker on web & monitoring)
#  10. Installs prometheus.prometheus.node_exporter role
#  11. Runs playbook-node-exporter.yaml (install node_exporter on web)
#  12. Runs playbook-monitoring.yaml (deploy Prometheus + Grafana stack)
#
# On re-deploy (terraform destroy + apply), just run this script again.
# ==============================================================================

set -e

REGION="ap-southeast-1"
echo "=== Getting instance IDs ==="
CTRL_ID=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=devops-ansible-controller" --query 'Reservations[0].Instances[0].InstanceId' --output text)
WEB_ID=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=devops-web-server" --query 'Reservations[0].Instances[0].InstanceId' --output text)
MON_ID=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=devops-monitoring-server" --query 'Reservations[0].Instances[0].InstanceId' --output text)
echo "  Controller: $CTRL_ID"
echo "  Web:        $WEB_ID"
echo "  Monitoring: $MON_ID"

echo ""
echo "=== Waiting for SSM Online on all instances ==="
while true; do
  STATUS=$(aws ssm describe-instance-information --region $REGION --filters "Key=InstanceIds,Values=$CTRL_ID,$WEB_ID,$MON_ID" --query 'InstanceInformationList[].PingStatus' --output text)
  if echo "$STATUS" | grep -q "Online" && [ "$(echo "$STATUS" | grep -c Online)" -eq 3 ]; then
    echo "  All instances Online"
    break
  fi
  echo "  Waiting... (status: $STATUS)"
  sleep 10
done

echo ""
echo "=== Installing Ansible on controller ==="
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo apt-get update -y","sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ansible"]' --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: install failed" && exit 1
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
COMPOSE_B64=$(base64 -w0 "$SCRIPT_DIR/compose.yaml")
PROM_B64=$(base64 -w0 "$SCRIPT_DIR/prometheus.yaml")
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters "commands=[\"sudo -u ubuntu mkdir -p /home/ubuntu/ansible/grafana\",\"echo $INV_B64 | base64 -d > /home/ubuntu/ansible/inventory.ini\",\"echo $CFG_B64 | base64 -d > /home/ubuntu/ansible/ansible.cfg\",\"echo $CONN_B64 | base64 -d > /home/ubuntu/ansible/playbook-connectivity.yaml\",\"echo $DOCKER_B64 | base64 -d > /home/ubuntu/ansible/playbook-docker.yaml\",\"echo $WEB_B64 | base64 -d > /home/ubuntu/ansible/playbook-web.yaml\",\"echo $REQ_B64 | base64 -d > /home/ubuntu/ansible/requirements.yml\",\"echo $MON_B64 | base64 -d > /home/ubuntu/ansible/playbook-monitoring.yaml\",\"echo $NEXP_B64 | base64 -d > /home/ubuntu/ansible/playbook-node-exporter.yaml\",\"echo $COMPOSE_B64 | base64 -d > /home/ubuntu/ansible/grafana/compose.yaml\",\"echo $PROM_B64 | base64 -d > /home/ubuntu/ansible/grafana/prometheus.yaml\",\"chown -R ubuntu:ubuntu /home/ubuntu/ansible\"]" --query 'Command.CommandId' --output text)
echo "  Command ID: $CMD_ID"
while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION --command-id "$CMD_ID" --instance-id "$CTRL_ID" --query 'Status' --output text)
  echo "  Status: $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "  ERROR: file copy failed" && exit 1
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
CMD_ID=$(aws ssm send-command --region $REGION --instance-ids "$CTRL_ID" --document-name "AWS-RunShellScript" --parameters 'commands=["sudo -u ubuntu ansible-galaxy role install prometheus.prometheus.node_exporter"]' --query 'Command.CommandId' --output text)
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
echo "=== DONE ==="