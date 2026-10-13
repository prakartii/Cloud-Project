#!/bin/bash
# Deletes everything ./deploy/aws-up.sh created, found by name tag (no state file needed).
#
# Run from anywhere:   ./deploy/aws-down.sh
# Env vars:  KEEP_BUCKET=1   keep the S3 bucket (default: delete it)
#            DELETE_BUDGET=1 also delete the budget (default: keep it, it is free)
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
P=library

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || exit 1
BUCKET=${BUCKET:-$P-lab-$ACCOUNT}
echo "== Deleting '$P' resources in account $ACCOUNT ($AWS_DEFAULT_REGION)"

none() { [ -z "$1" ] || [ "$1" = "None" ]; }
# retry <tries> <sleep> <command...>: retries while dependencies (e.g. ENIs) are still being released.
retry() { local n=$1 s=$2; shift 2; for _ in $(seq "$n"); do "$@" 2>/dev/null && return 0; sleep "$s"; done; "$@"; }

VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$P-vpc --query 'Vpcs[0].VpcId' --output text)

echo "-- Auto Scaling group"
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-asg --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text | grep -q "$P-asg"; then
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $P-asg --force-delete
fi
echo "-- Load balancer"
ALB=$(aws elbv2 describe-load-balancers --names $P-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
none "$ALB" || aws elbv2 delete-load-balancer --load-balancer-arn "$ALB"
echo "-- RDS"
if aws rds describe-db-instances --db-instance-identifier $P-db >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier $P-db --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
fi
echo "-- NAT gateway"
NATS=$(none "$VPC" || aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text)
for n in $NATS; do aws ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null; done
aws ec2 delete-launch-template --launch-template-name $P-lt >/dev/null 2>&1 && echo "-- launch template deleted"

echo "-- Waiting for the ASG instances, ALB, NAT gateway and RDS to finish deleting"
for _ in $(seq 90); do
  A=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-asg --query 'length(AutoScalingGroups)' --output text)
  I=0; none "$VPC" || I=$(aws ec2 describe-instances --filters Name=vpc-id,Values="$VPC" Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down --query 'length(Reservations[].Instances[])' --output text)
  L=$(aws elbv2 describe-load-balancers --names $P-alb --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)
  N=0; none "$VPC" || N=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" Name=state,Values=pending,available,deleting --query 'length(NatGateways)' --output text)
  R=$(aws rds describe-db-instances --db-instance-identifier $P-db --query 'length(DBInstances)' --output text 2>/dev/null || echo 0)
  echo "   asg=$A instances=$I alb=$L nat=$N rds=$R"
  [ "$A" = 0 ] && [ "$I" = 0 ] && [ "$L" = 0 ] && [ "$N" = 0 ] && [ "$R" = 0 ] && break
  sleep 20
done

echo "-- Target group, Elastic IP, DB subnet group"
TG=$(aws elbv2 describe-target-groups --names $P-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
none "$TG" || retry 10 15 aws elbv2 delete-target-group --target-group-arn "$TG"
for a in $(aws ec2 describe-addresses --filters Name=tag:Name,Values=$P-nat-eip --query 'Addresses[].AllocationId' --output text); do
  retry 10 10 aws ec2 release-address --allocation-id "$a"
done
aws rds delete-db-subnet-group --db-subnet-group-name $P-db-subnets 2>/dev/null

if none "$VPC"; then
  echo "-- no VPC named $P-vpc found, skipping network cleanup"
else
  echo "-- Security groups (db first: it references app, which references alb)"
  for name in $P-db-sg $P-app-sg $P-alb-sg; do
    SG=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=$name --query 'SecurityGroups[0].GroupId' --output text)
    none "$SG" || retry 20 15 aws ec2 delete-security-group --group-id "$SG"
  done
  echo "-- Subnets, route tables, internet gateway, VPC"
  for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text); do retry 20 15 aws ec2 delete-subnet --subnet-id "$s"; done
  for r in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --query 'RouteTables[?Associations[0].Main != `true`].RouteTableId' --output text); do aws ec2 delete-route-table --route-table-id "$r"; done
  for g in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$VPC" && aws ec2 delete-internet-gateway --internet-gateway-id "$g"
  done
  retry 10 10 aws ec2 delete-vpc --vpc-id "$VPC" && echo "   VPC deleted"
fi

if [ "${KEEP_BUCKET:-0}" != 1 ] && aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3 rb "s3://$BUCKET" --force >/dev/null && echo "-- bucket $BUCKET deleted"
fi
if [ "${DELETE_BUDGET:-0}" = 1 ]; then
  aws budgets delete-budget --account-id "$ACCOUNT" --budget-name $P-monthly-budget && echo "-- budget deleted"
fi

echo "== Remaining (all should be empty / 0)"
echo "VPC:       $(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$P-vpc --query 'length(Vpcs)' --output text)"
echo "ASG:       $(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-asg --query 'length(AutoScalingGroups)' --output text)"
echo "ALB:       $(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?LoadBalancerName=='$P-alb'])" --output text)"
echo "RDS:       $(aws rds describe-db-instances --query "length(DBInstances[?DBInstanceIdentifier=='$P-db'])" --output text)"
echo "NAT (live):$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=$P-nat Name=state,Values=pending,available,deleting --query 'length(NatGateways)' --output text)"
echo "EIPs:      $(aws ec2 describe-addresses --filters Name=tag:Name,Values=$P-nat-eip --query 'length(Addresses)' --output text)"
