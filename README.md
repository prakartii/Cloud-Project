# Library Management System: 3-tier app on AWS

Project for my cloud architecture class. A deliberately small library management system (plain HTML/JS frontend, FastAPI backend, PostgreSQL) used to demonstrate a 3-tier AWS architecture: VPC, Security Groups, EC2, EBS, ALB, Auto Scaling, RDS and AWS Budgets.

## Architecture

```
Internet -> ALB (public subnets, 2 AZs)
              -> Auto Scaling group of EC2 running the FastAPI app (private subnets)
                    -> RDS PostgreSQL (private subnets)
```

| Component | Setup |
|---|---|
| VPC | 2 public subnets (ALB, NAT gateway), 2 private subnets (EC2, RDS), across 2 AZs |
| Security groups | ALB: 80 from anywhere. EC2: 8080 from ALB SG only. RDS: 5432 from EC2 SG only |
| EC2 + EBS | Launch template, Ubuntu Server 24.04 LTS, gp3 root volume, `deploy/user-data.sh` |
| Load balancer | Application Load Balancer, target group health check `GET /health` |
| Auto Scaling | min 2, max 4, target tracking on average CPU ~50% |
| RDS | PostgreSQL, db.t3.micro, private subnets |
| Budgets | Monthly cost budget with email alert |

## Application

- `frontend/`: static HTML/CSS/JS, served by the FastAPI server.
- `backend/`: FastAPI + psycopg 3. Creates and seeds its tables on startup.

| Endpoint | Purpose |
|---|---|
| `GET /health` | ALB health check (checks DB connectivity) |
| `GET /api/info` | Instance ID and AZ, shown in the UI header to demonstrate load balancing |
| `GET/POST /api/books` | List / add books |
| `GET/POST /api/members` | List / add members |
| `GET/POST /api/loans` | List / issue loans (`{"book_id": 1, "member_id": 1}`) |
| `POST /api/loans/{id}/return` | Return a book |
| `GET /api/stress?ms=200` | Burns CPU for up to 1000 ms, used to trigger Auto Scaling |

Environment variables: `DATABASE_URL` (required), `FRONTEND_DIR`, `INSTANCE_ID`, `AVAILABILITY_ZONE`.
API docs are available at `/docs` (FastAPI's generated Swagger UI).

## Run locally

```bash
docker compose up -d                      # local Postgres
cd backend
uv venv .venv && uv pip install -r requirements.txt
DATABASE_URL=postgres://library:library@localhost:5432/library \
  .venv/bin/uvicorn app.main:app --port 8080
# open http://localhost:8080
```

## Deploy to AWS (Learner Lab, console guide)

The Learner Lab environment can't be saved, so you rebuild it each session. Do the steps in order. Use **us-east-1** (N. Virginia) throughout, and keep the same region in every console.

Names used below are suggestions; keep them consistent so you can find things.

### 0. Prepare

1. Start the lab in AWS Academy and click **AWS** to open the console. Check the region in the top-right.
2. Build the release package locally (needs Docker):
   ```bash
   ./deploy/build.sh        # -> dist/library-release.tar.gz
   ```
3. **S3**: *S3 → Create bucket*. Name it something globally unique (e.g. `library-<your-initials>-<random>`), keep **Block all public access** on, and create it. Open the bucket → **Upload** → add `dist/library-release.tar.gz`.

   The bucket and its contents persist between sessions as long as the account does, so you usually only do this once. If the bucket is gone, redo it.

### 1. VPC and subnets

1. *VPC → Create VPC → **VPC and more*** (the wizard builds most of it for you).
2. Settings:
   - Name tag prefix: `library`
   - IPv4 CIDR: `10.0.0.0/16`
   - Number of AZs: **2**
   - Public subnets: **2**, private subnets: **2**
   - NAT gateways: **In 1 AZ** (one is enough for a class project and costs less)
   - VPC endpoints: **None**
   - DNS options: leave both **enabled**
3. Click **Create VPC** and wait for it to finish (the NAT gateway takes a couple of minutes).

The wizard creates the internet gateway, route tables (public subnets route `0.0.0.0/0` to the IGW, private subnets to the NAT gateway) and the subnets. Note the VPC ID and the names of the four subnets.

### 2. Security groups

*VPC → Security groups → Create security group*. Create three, all in the `library` VPC. Create them in this order, because each references the previous one.

| Name | Inbound rule | Source |
|---|---|---|
| `library-alb-sg` | HTTP, TCP 80 | Anywhere-IPv4 `0.0.0.0/0` |
| `library-app-sg` | Custom TCP 8080 | `library-alb-sg` (select the security group, not an IP) |
| `library-db-sg` | PostgreSQL, TCP 5432 | `library-app-sg` |

Leave outbound as the default (all traffic).

### 3. RDS PostgreSQL

1. *RDS → Subnet groups → Create DB subnet group*:
   - Name: `library-db-subnets`, description anything
   - VPC: `library`
   - AZs: select both; Subnets: select the **two private** subnets (check the CIDRs or names)
2. *RDS → Databases → Create database*:
   - Method: **Standard create**, Engine: **PostgreSQL** (a recent 16.x is fine)
   - Templates: **Free tier** or **Dev/Test**. If Learner Lab complains about the template, choose Dev/Test and keep the settings below
   - DB instance identifier: `library-db`
   - Master username: `libadmin`, password: choose one and **write it down**
   - Instance class: **db.t3.micro** (burstable)
   - Storage: gp3 / 20 GiB, disable storage autoscaling
   - Multi-AZ: **No** (Learner Lab may block it and it costs more)
   - Connectivity: VPC `library`, subnet group `library-db-subnets`, Public access **No**, security group `library-db-sg` (remove `default`)
   - **Additional configuration → Initial database name: `librarydb`** (easy to miss; the app expects this database)
   - Disable enhanced monitoring and Performance Insights to avoid permission errors
3. Create the database and wait until the status is **Available** (about 5-10 minutes).
4. Open the database and copy the **Endpoint** (like `library-db.xxxx.us-east-1.rds.amazonaws.com`).

Your connection string is:
```
postgres://libadmin:<password>@<endpoint>:5432/librarydb
```
If the password has special characters (`@ : / ? #`), URL-encode them or choose a simpler password.

### 4. Edit the user-data script

Open `deploy/user-data.sh` and set:
- `S3_BUCKET` to your bucket name
- `DATABASE_URL` to the connection string from step 3

Don't commit the real password to GitHub. Keep the edited copy local, or edit it only inside the launch template.

### 5. Launch template

*EC2 → Launch templates → Create launch template*:
- Name: `library-lt`. Tick **Provide guidance for Auto Scaling**
- AMI: *Quick Start → **Ubuntu*** → **Ubuntu Server 24.04 LTS** (64-bit x86)
- Instance type: **t3.micro**
- Key pair: **Don't include** (not needed; use *Session Manager* or the EC2 console's *Connect* if you need a shell). Include `vockey` only if you want SSH
- Network settings: don't specify a subnet. Security groups: `library-app-sg`
- Storage: volume 1, **8 GiB, gp3**, delete on termination (this is your EBS volume)
- Advanced details:
  - **IAM instance profile**: `LabInstanceProfile`
  - **User data**: paste the full contents of the edited `user-data.sh`
- Create the template.

### 6. Target group and load balancer

1. *EC2 → Target groups → Create target group*:
   - Target type: **Instances**, name `library-tg`
   - Protocol HTTP, port **8080**, VPC `library`
   - Health checks: path **`/health`**; under advanced, healthy threshold 2, interval 15s
   - Don't register any targets; the Auto Scaling group will do it. Create.
2. *EC2 → Load balancers → Create load balancer → Application Load Balancer*:
   - Name: `library-alb`, scheme **Internet-facing**, IPv4
   - VPC `library`, mappings: both AZs, pick the **public** subnets
   - Security group: `library-alb-sg` (remove `default`)
   - Listener: HTTP:80 → forward to `library-tg`
   - Create, then copy the **DNS name** from its details page.

### 7. Auto Scaling group

*EC2 → Auto Scaling groups → Create Auto Scaling group*:
- Name: `library-asg`, launch template `library-lt` (latest version)
- Network: VPC `library`, subnets: the **two private** subnets
- Load balancing: **Attach to an existing load balancer** → choose target group `library-tg`
- Health checks: turn on **Elastic Load Balancing health checks**, grace period **300** seconds (the user-data installs packages on boot)
- Group size: desired **2**, minimum **2**, maximum **4**
- Scaling policy: **Target tracking scaling policy**, metric **Average CPU utilization**, target **50**, instance warm-up 120 seconds
- Skip notifications/tags, then create.

### 8. Verify

1. *EC2 → Instances*: two instances should start. Allow 3-5 minutes for user-data to finish.
2. *EC2 → Target groups → `library-tg` → Targets*: wait for both to be **healthy**.
3. Open `http://<alb-dns-name>` in a browser. You should see the book list, and the header shows the instance ID. Refresh a few times and it should alternate between the two instances. Place an order to confirm the database works.

**If targets are unhealthy**, in order:
- Open a shell on an instance: *EC2 → Instances →* select it *→ Connect → Session Manager* (the instances are private and use the NAT gateway for outbound access; if Session Manager isn't available in your lab, launch the template once with the `vockey` key pair and SSH from a temporary public instance). Then check `sudo tail -n 50 /var/log/cloud-init-output.log`
- `sudo systemctl status library` and `sudo journalctl -u library -n 50`
- Common causes: wrong `DATABASE_URL`, the database wasn't created with initial name `librarydb`, `library-db-sg` not allowing `library-app-sg`, or no NAT route so `apt` / S3 download failed.

### 9. AWS Budgets

*Billing and Cost Management → Budgets → Create budget* → **Use a template (simplified)** → **Monthly cost budget**. Enter a budget amount (e.g. $10) and your email. Budgets works in the Learner Lab. Afterwards, click *Send verification* on the budget and confirm the email, otherwise the alert stays inactive.

### 10. Run the load test

See [Load test](#load-test-auto-scaling) below. Take screenshots of the ASG **Activity** tab (scale-out and scale-in events) and the **Monitoring** tab CPU graph.

### 11. Clean up (saves lab credit)

Delete in this order: Auto Scaling group → load balancer → target group → RDS database (skip final snapshot) → **NAT gateway** (and release its Elastic IP) → VPC (this removes subnets, route tables, IGW and security groups). The NAT gateway and RDS are what use the most credit, so delete them first if you're short on time. Stopping the lab stops EC2 instances but doesn't delete these resources.

## Redeploy with the AWS CLI (what was actually run)

### One-command redeploy

```bash
# 1. Start the Learner Lab, save the credentials block to /dev/shm/aws-lab-creds (see below), then:
export AWS_SHARED_CREDENTIALS_FILE=/dev/shm/aws-lab-creds AWS_DEFAULT_REGION=us-east-1
BUDGET_EMAIL=<your-email> ./deploy/aws-up.sh     # builds the package if needed, creates everything (~12 minutes), prints the URL
# ... take screenshots, run the load test ...
./deploy/aws-down.sh                              # deletes everything it created (found by name tag), keeps the budget
```

- `aws-up.sh` is the whole environment from the sections below as one script. It refuses to run if a `library-vpc` already exists, and it prints the generated database password once. `BUDGET_EMAIL` is optional (it also creates the $10 monthly budget); verify that email in the console afterwards.
- `aws-down.sh` needs no state file. It finds resources by their `library-*` names, waits for dependencies (ASG instances, ALB, NAT gateway, RDS) before deleting the target group, security groups, subnets and VPC, and prints a "remaining" summary at the end that should show all zeros. `KEEP_BUCKET=1` keeps the S3 bucket and `DELETE_BUDGET=1` also removes the budget.
- The bucket is named `library-lab-<account id>`, so it is unique per account and the scripts can find it again.
- The commands below are the same steps written out one by one, for reference or for running a stage at a time.

The console guide above is the manual route. This section records the CLI commands used to build the same environment, so it can be recreated quickly after a Learner Lab reset. Replace the `<...>` placeholders. Nothing here contains credentials or secrets.

### Learner Lab facts that affect redeploying
- A session lasts about 4 hours. When it ends, credentials stop working (`voc-cancel-cred` explicit deny on EC2 calls) and EC2 instances are stopped. **Other resources are not deleted**: the VPC, NAT gateway, ALB, RDS and Elastic IPs survive and keep billing (roughly $0.11-0.12/hour for this stack even with the instances stopped, about $19/week). Delete everything when finished (see Cleanup).
- Start the lab again, then save fresh credentials from *AWS Details -> AWS CLI: Show* into a RAM-backed file so they never touch disk:
  ```bash
  (umask 077; stty -echo; echo "Paste the AWS block, press Enter, then Ctrl+D:"; cat > /dev/shm/aws-lab-creds; stty echo; echo saved)
  export AWS_SHARED_CREDENTIALS_FILE=/dev/shm/aws-lab-creds AWS_DEFAULT_REGION=us-east-1
  aws sts get-caller-identity          # confirm the right account
  shred -u /dev/shm/aws-lab-creds      # when finished
  ```
- Not available in the Learner Lab: the Pricing Calculator and the Price List API (`pricing:GetProducts` is denied). The cost table in the report uses published on-demand prices.
- The IAM role `LabInstanceProfile` already exists and can read S3, so no IAM setup is needed.

### Gotchas found while deploying
- **`library` is a reserved word in RDS PostgreSQL**, both as the database name and as the master username. That is why the stack uses the database `librarydb` and the user `libadmin` (everything else is named `library-*`).
- **Python dependencies are bundled as an offline wheelhouse.** `deploy/build.sh` runs `pip wheel` inside `python:3.12-slim` (Ubuntu 24.04 ships Python 3.12), and user-data installs with `pip install --no-index`, so instances never depend on PyPI at boot.
- **The user-data `sed` must match only the first `DATABASE_URL` line.** Anchoring on `^DATABASE_URL="postgres://` avoids also rewriting the `DATABASE_URL=${DATABASE_URL}` line inside the env-file heredoc.
- **AWS Budgets email alerts need verification.** After creating a budget, open it in the console and click *Send verification*, then confirm the link in the email. Until then the alert is "Inactive" and nothing is sent.
- **Timing.** VPC + NAT gateway: ~2 minutes. RDS: ~5-8 minutes. Instances become healthy ~2-3 minutes after the ASG creates them. During a load test the group scaled out about 4-7 minutes after the load started, and scaled back in about 15-20 minutes after it ended. Take the Auto Scaling screenshots in that window.
- Deleting the target group, subnets and VPC fails while the ASG, ALB, NAT gateway or RDS are still being deleted. Wait for them to finish first.

### 1. Package and upload
```bash
./deploy/build.sh                               # -> dist/library-release.tar.gz (needs Docker)
BUCKET=library-<initials>-$(openssl rand -hex 4)
aws s3api create-bucket --bucket $BUCKET
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3 cp dist/library-release.tar.gz s3://$BUCKET/
```

### 2. Network, security groups, database, load balancer, Auto Scaling
```bash
P=library
ROLE_PROFILE=LabInstanceProfile
tg(){ echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }

# --- VPC, subnets, gateways, route tables ---
VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tg vpc $P-vpc)" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames
mk(){ aws ec2 create-subnet --vpc-id $VPC --cidr-block $1 --availability-zone $2 --tag-specifications "$(tg subnet $P-subnet-$3-$2)" --query Subnet.SubnetId --output text; }
PUB1=$(mk 10.0.0.0/20   us-east-1a public1);  PUB2=$(mk 10.0.16.0/20  us-east-1b public2)
PRV1=$(mk 10.0.128.0/20 us-east-1a private1); PRV2=$(mk 10.0.144.0/20 us-east-1b private2)
IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tg internet-gateway $P-igw)" --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
EIP=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tg elastic-ip $P-nat-eip)" --query AllocationId --output text)
NAT=$(aws ec2 create-nat-gateway --subnet-id $PUB1 --allocation-id $EIP --tag-specifications "$(tg natgateway $P-nat)" --query NatGateway.NatGatewayId --output text)
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tg route-table $P-rtb-public)" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB1
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB2
RT_P1=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tg route-table $P-rtb-private1-us-east-1a)" --query RouteTable.RouteTableId --output text)
RT_P2=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tg route-table $P-rtb-private2-us-east-1b)" --query RouteTable.RouteTableId --output text)
aws ec2 associate-route-table --route-table-id $RT_P1 --subnet-id $PRV1
aws ec2 associate-route-table --route-table-id $RT_P2 --subnet-id $PRV2
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT
aws ec2 create-route --route-table-id $RT_P1 --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT
aws ec2 create-route --route-table-id $RT_P2 --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT

# --- Security groups (each references the previous one) ---
SG_ALB=$(aws ec2 create-security-group --group-name $P-alb-sg --description "Allow HTTP from internet to ALB" --vpc-id $VPC --tag-specifications "$(tg security-group $P-alb-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 80 --cidr 0.0.0.0/0
SG_APP=$(aws ec2 create-security-group --group-name $P-app-sg --description "Allow 8080 from ALB only" --vpc-id $VPC --tag-specifications "$(tg security-group $P-app-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 8080 --source-group $SG_ALB
SG_DB=$(aws ec2 create-security-group --group-name $P-db-sg --description "Allow Postgres from app tier only" --vpc-id $VPC --tag-specifications "$(tg security-group $P-db-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_DB --protocol tcp --port 5432 --source-group $SG_APP

# --- RDS (private subnets, not public) ---
aws rds create-db-subnet-group --db-subnet-group-name $P-db-subnets --db-subnet-group-description "Private subnets for $P DB" --subnet-ids $PRV1 $PRV2
DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)   # note it down, don't commit it
aws rds create-db-instance --db-instance-identifier $P-db --engine postgres --engine-version 16.15 \
  --db-instance-class db.t3.micro --allocated-storage 20 --storage-type gp3 \
  --master-username libadmin --master-user-password "$DB_PASSWORD" --db-name librarydb \
  --db-subnet-group-name $P-db-subnets --vpc-security-group-ids $SG_DB \
  --no-publicly-accessible --no-multi-az --backup-retention-period 0 --no-enable-performance-insights --no-deletion-protection
# (5-8 minutes)
aws rds wait db-instance-available --db-instance-identifier $P-db
DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $P-db --query 'DBInstances[0].Endpoint.Address' --output text)

# --- Target group + ALB ---
TG=$(aws elbv2 create-target-group --name $P-tg --protocol HTTP --port 8080 --vpc-id $VPC --target-type instance \
  --health-check-path /health --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB=$(aws elbv2 create-load-balancer --name $P-alb --type application --scheme internet-facing \
  --subnets $PUB1 $PUB2 --security-groups $SG_ALB --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 create-listener --load-balancer-arn $ALB --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB --query 'LoadBalancers[0].DNSName' --output text)

# --- Launch template: render user-data with the bucket and database URL, then base64 it ---
AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
sed -e "s|^S3_BUCKET=.*|S3_BUCKET=\"$BUCKET\"|" \
    -e "s|^DATABASE_URL=\"postgres://.*\"|DATABASE_URL=\"postgres://libadmin:$DB_PASSWORD@$DB_ENDPOINT:5432/librarydb\"|" \
    deploy/user-data.sh > /tmp/user-data.rendered.sh      # delete this file afterwards: it contains the password
UD=$(base64 -w0 /tmp/user-data.rendered.sh)
aws ec2 create-launch-template --launch-template-name $P-lt --version-description v1 --launch-template-data "{
  \"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\",\"IamInstanceProfile\":{\"Name\":\"$ROLE_PROFILE\"},
  \"SecurityGroupIds\":[\"$SG_APP\"],
  \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}],
  \"UserData\":\"$UD\"}"
rm -f /tmp/user-data.rendered.sh

# --- Auto Scaling group + CPU target tracking ---
aws autoscaling create-auto-scaling-group --auto-scaling-group-name $P-asg \
  --launch-template LaunchTemplateName=$P-lt,Version='$Latest' --min-size 2 --max-size 4 --desired-capacity 2 \
  --vpc-zone-identifier "$PRV1,$PRV2" --target-group-arns "$TG" \
  --health-check-type ELB --health-check-grace-period 300 --default-instance-warmup 120
aws autoscaling put-scaling-policy --auto-scaling-group-name $P-asg --policy-name cpu-50 --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":50.0}'
```

Wait until both targets are healthy, then test:
```bash
aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
curl http://$ALB_DNS/api/info      # repeat: the instance ID should alternate between the two AZs
```

### 3. Budget
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws budgets create-budget --account-id $ACCOUNT \
  --budget '{"BudgetName":"library-monthly-budget","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"<your-email>"}]}]'
```
Then verify the email address in the console (see gotchas).

### 4. Load test
```bash
uvx locust -f loadtest/locustfile.py --host http://$ALB_DNS --headless -u 100 -r 5 -t 10m --html loadtest/report.html
```
In the test run, 77,870 requests at 100 simulated users produced 11 failures (0.01%, all HTTP 502 from the ALB), and the group scaled from 2 to 4 instances about 7 minutes in.

### 5. Cleanup (when finished or before the lab ends)
IDs are lost when the shell closes. Look them up by Name tag, e.g. `aws ec2 describe-vpcs --filters Name=tag:Name,Values=library-vpc --query 'Vpcs[0].VpcId' --output text`.
```bash
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name library-asg --force-delete
aws elbv2 delete-load-balancer --load-balancer-arn $ALB
aws rds delete-db-instance --db-instance-identifier library-db --skip-final-snapshot --delete-automated-backups
aws ec2 delete-nat-gateway --nat-gateway-id $NAT
aws ec2 delete-launch-template --launch-template-name library-lt
# wait until the ASG, its instances, the ALB, the NAT gateway and the RDS instance are all gone, then:
aws elbv2 delete-target-group --target-group-arn $TG
aws ec2 release-address --allocation-id $EIP
aws rds delete-db-subnet-group --db-subnet-group-name library-db-subnets
aws ec2 delete-security-group --group-id $SG_DB; aws ec2 delete-security-group --group-id $SG_APP; aws ec2 delete-security-group --group-id $SG_ALB
for s in $PRV1 $PRV2 $PUB1 $PUB2; do aws ec2 delete-subnet --subnet-id $s; done
for r in $RT_P1 $RT_P2 $RT_PUB; do aws ec2 delete-route-table --route-table-id $r; done
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC && aws ec2 delete-internet-gateway --internet-gateway-id $IGW
aws ec2 delete-vpc --vpc-id $VPC
```
The S3 bucket and the budget are cheap and can be left, or removed with `aws s3 rb s3://$BUCKET --force` and `aws budgets delete-budget`.

## Load test (Auto Scaling)

Use Locust (Python) to ramp up traffic against the load balancer:

```bash
# Web UI with live charts (open http://localhost:8089)
uvx locust -f loadtest/locustfile.py --host http://<alb-dns-name>

# Or headless, writing an HTML report with charts
uvx locust -f loadtest/locustfile.py --host http://<alb-dns-name> --headless -u 100 -r 2 -t 10m --html loadtest/report.html
```

No tools installed? `./loadtest/curl-load.sh http://<alb-dns-name> 40 600` sends the same CPU-heavy requests using only `curl`.

About 30% of the requests hit `/api/stress`, which is what pushes CPU over the scaling target. Watch the ASG activity history and the CloudWatch CPU graph for the scale-out and scale-in events.
