#!/bin/bash
# EC2 launch template user-data (Ubuntu Server 24.04 LTS).
# Edit the variables below, then paste the script into the launch template.
set -euxo pipefail

S3_BUCKET="CHANGE-ME-bucket"          # bucket holding library-release.tar.gz
DATABASE_URL="postgres://library:CHANGE-ME@CHANGE-ME.rds.amazonaws.com:5432/library"
PORT=8080

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl unzip python3-venv

# Ubuntu doesn't ship the AWS CLI; install v2 (needs outbound internet via the NAT gateway).
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Instance metadata (IMDSv2) so the UI can show which instance served the request.
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IMDS() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCE_ID=$(IMDS instance-id)
AVAILABILITY_ZONE=$(IMDS placement/availability-zone)

mkdir -p /opt/library
aws s3 cp "s3://${S3_BUCKET}/library-release.tar.gz" /tmp/release.tar.gz
tar -xzf /tmp/release.tar.gz -C /opt/library   # contains: app/, frontend/, wheelhouse/, requirements.txt

# Install dependencies offline from the bundled wheelhouse (no PyPI access needed).
python3 -m venv /opt/library/venv
/opt/library/venv/bin/pip install --quiet --no-index --find-links /opt/library/wheelhouse -r /opt/library/requirements.txt

cat > /etc/library.env <<ENV
DATABASE_URL=${DATABASE_URL}
FRONTEND_DIR=/opt/library/frontend
INSTANCE_ID=${INSTANCE_ID}
AVAILABILITY_ZONE=${AVAILABILITY_ZONE}
ENV
chmod 600 /etc/library.env

cat > /etc/systemd/system/library.service <<UNIT
[Unit]
Description=Library Management System (FastAPI)
After=network-online.target

[Service]
EnvironmentFile=/etc/library.env
WorkingDirectory=/opt/library
ExecStart=/opt/library/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now library
