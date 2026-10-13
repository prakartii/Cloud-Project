#!/bin/bash
# Creates the whole AWS environment for this project in an AWS Academy Learner Lab account:
# S3 bucket, VPC (2 public + 2 private subnets), NAT, security groups, RDS PostgreSQL, ALB,
# launch template, Auto Scaling group with CPU target tracking, and (optionally) a budget.
#
# Run from anywhere:   ./deploy/aws-up.sh
# Needs: AWS credentials in the environment (see README), Docker (to build the package), curl.
# Optional env vars:   BUDGET_EMAIL=you@example.com   (also creates a $10/month budget)
#                      BUCKET=custom-bucket-name      (default: library-lab-<account id>)
# Tear everything down with ./deploy/aws-down.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

P=library
DB_USER=libadmin
DB_NAME=librarydb
TARBALL=library-release.tar.gz
ROLE_PROFILE=LabInstanceProfile
AZ1=${AWS_DEFAULT_REGION}a
AZ2=${AWS_DEFAULT_REGION}b

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${BUCKET:-$P-lab-$ACCOUNT}
echo "== Deploying '$P' in account $ACCOUNT ($AWS_DEFAULT_REGION)"

EXISTING=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$P-vpc --query 'Vpcs[0].VpcId' --output text)
if [ "$EXISTING" != "None" ]; then
  echo "A VPC named $P-vpc already exists ($EXISTING). Run ./deploy/aws-down.sh first." >&2
  exit 1
fi

tg() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }

echo "== Package + S3"
[ -f "dist/$TARBALL" ] || ./deploy/build.sh
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || {
  aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}
aws s3 cp "dist/$TARBALL" "s3://$BUCKET/" --only-show-errors

echo "== VPC, subnets, gateways, route tables"
VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tg vpc $P-vpc)" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames
mk() { aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$1" --availability-zone "$2" \
         --tag-specifications "$(tg subnet $P-subnet-$3-$2)" --query Subnet.SubnetId --output text; }
PUB1=$(mk 10.0.0.0/20 $AZ1 public1);    PUB2=$(mk 10.0.16.0/20 $AZ2 public2)
PRV1=$(mk 10.0.128.0/20 $AZ1 private1); PRV2=$(mk 10.0.144.0/20 $AZ2 private2)
IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tg internet-gateway $P-igw)" --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
EIP=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tg elastic-ip $P-nat-eip)" --query AllocationId --output text)
NAT=$(aws ec2 create-nat-gateway --subnet-id "$PUB1" --allocation-id "$EIP" --tag-specifications "$(tg natgateway $P-nat)" --query NatGateway.NatGatewayId --output text)
RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tg route-table $P-rtb-public)" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB1" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB2" >/dev/null
RT_P1=$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tg route-table $P-rtb-private1-$AZ1)" --query RouteTable.RouteTableId --output text)
RT_P2=$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tg route-table $P-rtb-private2-$AZ2)" --query RouteTable.RouteTableId --output text)
aws ec2 associate-route-table --route-table-id "$RT_P1" --subnet-id "$PRV1" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_P2" --subnet-id "$PRV2" >/dev/null

echo "== Security groups"
SG_ALB=$(aws ec2 create-security-group --group-name $P-alb-sg --description "Allow HTTP from internet to ALB" --vpc-id "$VPC" --tag-specifications "$(tg security-group $P-alb-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
SG_APP=$(aws ec2 create-security-group --group-name $P-app-sg --description "Allow 8080 from ALB only" --vpc-id "$VPC" --tag-specifications "$(tg security-group $P-app-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 8080 --source-group "$SG_ALB" >/dev/null
SG_DB=$(aws ec2 create-security-group --group-name $P-db-sg --description "Allow Postgres from app tier only" --vpc-id "$VPC" --tag-specifications "$(tg security-group $P-db-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" --protocol tcp --port 5432 --source-group "$SG_APP" >/dev/null

echo "== RDS PostgreSQL (takes 5-8 minutes)"
aws rds create-db-subnet-group --db-subnet-group-name $P-db-subnets --db-subnet-group-description "Private subnets for $P DB" --subnet-ids "$PRV1" "$PRV2" >/dev/null
DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
aws rds create-db-instance --db-instance-identifier $P-db --engine postgres --engine-version 16.15 \
  --db-instance-class db.t3.micro --allocated-storage 20 --storage-type gp3 \
  --master-username "$DB_USER" --master-user-password "$DB_PASSWORD" --db-name "$DB_NAME" \
  --db-subnet-group-name $P-db-subnets --vpc-security-group-ids "$SG_DB" \
  --no-publicly-accessible --no-multi-az --backup-retention-period 0 --no-enable-performance-insights --no-deletion-protection >/dev/null

echo "== Target group + ALB"
TG=$(aws elbv2 create-target-group --name $P-tg --protocol HTTP --port 8080 --vpc-id "$VPC" --target-type instance \
  --health-check-path /health --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB=$(aws elbv2 create-load-balancer --name $P-alb --type application --scheme internet-facing \
  --subnets "$PUB1" "$PUB2" --security-groups "$SG_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="$TG" >/dev/null
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" --query 'LoadBalancers[0].DNSName' --output text)

echo "== NAT gateway + private routes"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"
aws ec2 create-route --route-table-id "$RT_P1" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT" >/dev/null
aws ec2 create-route --route-table-id "$RT_P2" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT" >/dev/null

echo "== Waiting for RDS"
aws rds wait db-instance-available --db-instance-identifier $P-db
DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $P-db --query 'DBInstances[0].Endpoint.Address' --output text)

echo "== Launch template + Auto Scaling group"
AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
UD=$(sed -e "s|^S3_BUCKET=.*|S3_BUCKET=\"$BUCKET\"|" \
         -e "s|^DATABASE_URL=\"postgres://.*\"|DATABASE_URL=\"postgres://$DB_USER:$DB_PASSWORD@$DB_ENDPOINT:5432/$DB_NAME\"|" \
         deploy/user-data.sh | base64 -w0)
aws ec2 create-launch-template --launch-template-name $P-lt --version-description v1 --launch-template-data "{
  \"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\",\"IamInstanceProfile\":{\"Name\":\"$ROLE_PROFILE\"},
  \"SecurityGroupIds\":[\"$SG_APP\"],
  \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}],
  \"UserData\":\"$UD\"}" >/dev/null
aws autoscaling create-auto-scaling-group --auto-scaling-group-name $P-asg \
  --launch-template LaunchTemplateName=$P-lt,Version='$Latest' --min-size 2 --max-size 4 --desired-capacity 2 \
  --vpc-zone-identifier "$PRV1,$PRV2" --target-group-arns "$TG" \
  --health-check-type ELB --health-check-grace-period 300 --default-instance-warmup 120
aws autoscaling put-scaling-policy --auto-scaling-group-name $P-asg --policy-name cpu-50 --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":50.0}' >/dev/null

if [ -n "${BUDGET_EMAIL:-}" ]; then
  echo "== Budget"
  aws budgets create-budget --account-id "$ACCOUNT" \
    --budget "{\"BudgetName\":\"$P-monthly-budget\",\"BudgetLimit\":{\"Amount\":\"10\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
    --notifications-with-subscribers "[{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$BUDGET_EMAIL\"}]}]" \
    || echo "(budget creation failed or it already exists; continuing)"
  echo "   Remember to click 'Send verification' on the budget in the console and confirm the email."
fi

echo "== Waiting for both instances to become healthy (up to 10 minutes)"
for _ in $(seq 40); do
  STATES=$(aws elbv2 describe-target-health --target-group-arn "$TG" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  [ "$(echo "$STATES" | tr '\t' '\n' | grep -c '^healthy$')" -ge 2 ] && break
  sleep 15
done
echo "   target states: $STATES"

echo
echo "URL:          http://$ALB_DNS"
echo "DB password:  $DB_PASSWORD   (shown once; also stored in the launch template user data)"
echo "Bucket:       $BUCKET"
