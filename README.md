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
   - Master username: `library`, password: choose one and **write it down**
   - Instance class: **db.t3.micro** (burstable)
   - Storage: gp3 / 20 GiB, disable storage autoscaling
   - Multi-AZ: **No** (Learner Lab may block it and it costs more)
   - Connectivity: VPC `library`, subnet group `library-db-subnets`, Public access **No**, security group `library-db-sg` (remove `default`)
   - **Additional configuration → Initial database name: `library`** (easy to miss; the app expects this database)
   - Disable enhanced monitoring and Performance Insights to avoid permission errors
3. Create the database and wait until the status is **Available** (about 5-10 minutes).
4. Open the database and copy the **Endpoint** (like `library-db.xxxx.us-east-1.rds.amazonaws.com`).

Your connection string is:
```
postgres://library:<password>@<endpoint>:5432/library
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
- Common causes: wrong `DATABASE_URL`, the database wasn't created with initial name `library`, `library-db-sg` not allowing `library-app-sg`, or no NAT route so `apt` / S3 download failed.

### 9. AWS Budgets

*Billing and Cost Management → Budgets → Create budget* → **Use a template (simplified)** → **Monthly cost budget**. Enter a budget amount (e.g. $10) and your email. Some Learner Lab accounts block Budgets; if so, take a screenshot of whatever the console shows and note the restriction in the report.

### 10. Run the load test

See [Load test](#load-test-auto-scaling) below. Take screenshots of the ASG **Activity** tab (scale-out and scale-in events) and the **Monitoring** tab CPU graph.

### 11. Clean up (saves lab credit)

Delete in this order: Auto Scaling group → load balancer → target group → RDS database (skip final snapshot) → **NAT gateway** (and release its Elastic IP) → VPC (this removes subnets, route tables, IGW and security groups). The NAT gateway and RDS are what use the most credit, so delete them first if you're short on time. Stopping the lab stops EC2 instances but doesn't delete these resources.

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
