#!/bin/bash
# ==============================================================================
# setup-controller.sh — reusable steps to prepare the Ansible controller
#
# Run these commands ONE BY ONE after `terraform apply`.
# Each step is independent — you can stop and resume anywhere.
#
# Prerequisites:
#   - terraform/ applied (3 EC2 running)
#   - ansible/ terraform applied (inventory.ini generated)
#   - aws CLI configured, session-manager-plugin installed
#
# Usage:
#   Step 1: generate inventory from ansible/terraform
#   Step 2: find instance IDs (SSM needs them)
#   Step 3: install Ansible on the controller
#   Step 4: generate SSH key on the controller
#   Step 5: distribute the public key to web & monitoring
#   Step 6: copy ansible files (inventory, playbook) to controller
#   Step 7: run the connectivity test
# ==============================================================================

echo "=== Step 0: Get instance IDs ==="
# Run this first so you have the IDs for subsequent commands.
# These come from the terraform output after applying terraform/
aws ec2 describe-instances \
  --region ap-southeast-1 \
  --filters "Name=tag:Name,Values=devops-ansible-controller" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text

aws ec2 describe-instances \
  --region ap-southeast-1 \
  --filters "Name=tag:Name,Values=devops-web-server" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text

aws ec2 describe-instances \
  --region ap-southeast-1 \
  --filters "Name=tag:Name,Values=devops-monitoring-server" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text

# After running, export the IDs:
#   CTRL_ID=i-xxxx
#   WEB_ID=i-xxxx
#   MON_ID=i-xxxx


echo ""
echo "=== Step 1: Generate inventory.ini ==="
cd /home/luqmansyakir/devops-bootcamp-project/ansible
terraform init     # first time only
terraform apply    # creates/updates ansible/inventory.ini
cat inventory.ini  # verify the IPs are correct


echo ""
echo "=== Step 2: Verify SSM connectivity ==="
aws ssm describe-instance-information \
  --region ap-southeast-1 \
  --filters "Key=InstanceIds,Values=$CTRL_ID,$WEB_ID,$MON_ID" \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}' \
  --output table
# All three should show "Online". If not, wait ~2 min and retry.


echo ""
echo "=== Step 3: Install Ansible on controller ==="
CMD_ID=$(aws ssm send-command \
  --region ap-southeast-1 \
  --instance-ids "$CTRL_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "sudo apt-get update -y",
    "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ansible"
  ]' \
  --query 'Command.CommandId' \
  --output text)
echo "Command ID: $CMD_ID"

# Check status (repeat until Status=Success)
aws ssm get-command-invocation \
  --region ap-southeast-1 \
  --command-id "$CMD_ID" \
  --instance-id "$CTRL_ID" \
  --query '{Status:Status,Output:StandardOutputContent}' \
  --output json


echo ""
echo "=== Step 4: Generate SSH key on controller ==="
CMD_ID=$(aws ssm send-command \
  --region ap-southeast-1 \
  --instance-ids "$CTRL_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "sudo -u ubuntu mkdir -p /home/ubuntu/.ssh",
    "sudo -u ubuntu ssh-keygen -t ed25519 -f /home/ubuntu/.ssh/id_ed25519 -N \"\" -q",
    "sudo -u ubuntu cat /home/ubuntu/.ssh/id_ed25519.pub"
  ]' \
  --query 'Command.CommandId' \
  --output text)
echo "Command ID: $CMD_ID"

# Wait ~5s, then check output to get the public key
aws ssm get-command-invocation \
  --region ap-southeast-1 \
  --command-id "$CMD_ID" \
  --instance-id "$CTRL_ID" \
  --query 'StandardOutputContent' \
  --output text

# Copy the public key string (starts with ssh-ed25519 AAA...) into the next step


echo ""
echo "=== Step 5: Add controller's SSH key to web & monitoring ==="
# Replace YOUR_PUB_KEY with the key from Step 4 output
CONTROLLER_PUB_KEY="ssh-ed25519 AAA... ubuntu@ip-10-0-0-135"

aws ssm send-command \
  --region ap-southeast-1 \
  --instance-ids "$WEB_ID" "$MON_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "sudo -u ubuntu mkdir -p /home/ubuntu/.ssh",
    "echo "'"$CONTROLLER_PUB_KEY"'" >> /home/ubuntu/.ssh/authorized_keys",
    "chmod 600 /home/ubuntu/.ssh/authorized_keys",
    "sudo -u ubuntu cat /home/ubuntu/.ssh/authorized_keys"
  ]' \
  --query 'Command.CommandId' \
  --output text

# Wait ~5s, then verify the key was added on both targets


echo ""
echo "=== Step 6: Copy ansible files to controller ==="
cd /home/luqmansyakir/devops-bootcamp-project/ansible

# Base64-encode each file to avoid escape issues in SSM
INV_B64=$(base64 -w0 inventory.ini)
CFG_B64=$(base64 -w0 ansible.cfg)
PB_B64=$(base64 -w0 playbook-connectivity.yaml)

CMD_ID=$(aws ssm send-command \
  --region ap-southeast-1 \
  --instance-ids "$CTRL_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "sudo -u ubuntu mkdir -p /home/ubuntu/ansible",
    "echo "'"$INV_B64"'" | base64 -d > /home/ubuntu/ansible/inventory.ini",
    "echo "'"$CFG_B64"'" | base64 -d > /home/ubuntu/ansible/ansible.cfg",
    "echo "'"$PB_B64"'" | base64 -d > /home/ubuntu/ansible/playbook-connectivity.yaml",
    "chown -R ubuntu:ubuntu /home/ubuntu/ansible",
    "ls -la /home/ubuntu/ansible"
  ]' \
  --query 'Command.CommandId' \
  --output text)

# Check — should see 3 files (inventory.ini, ansible.cfg, playbook-connectivity.yaml)
aws ssm get-command-invocation \
  --region ap-southeast-1 \
  --command-id "$CMD_ID" \
  --instance-id "$CTRL_ID" \
  --query '{Status:Status,Output:StandardOutputContent}' \
  --output json


echo ""
echo "=== Step 7: Run connectivity test ==="
CMD_ID=$(aws ssm send-command \
  --region ap-southeast-1 \
  --instance-ids "$CTRL_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "sudo -u ubuntu ansible-playbook -i /home/ubuntu/ansible/inventory.ini /home/ubuntu/ansible/playbook-connectivity.yaml"
  ]' \
  --query 'Command.CommandId' \
  --output text)

# Wait ~15s for playbook to finish
sleep 15

aws ssm get-command-invocation \
  --region ap-southeast-1 \
  --command-id "$CMD_ID" \
  --instance-id "$CTRL_ID" \
  --query '{Status:Status,Output:StandardOutputContent}' \
  --output json

# Expected result:
#   web_node        : ok=2    failed=0
#   monitoring_node : ok=2    failed=0
echo ""
echo "=== Done. Controller ready to manage servers ==="