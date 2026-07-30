# DevOps on AWS — 3-Tier App on Kubernetes (Assignment 3)

This project runs a 3-tier application (frontend/nginx, backend API, background worker) inside
**Kubernetes**, connected to managed AWS services (**RDS PostgreSQL, S3, SNS**) that are still
provisioned with Terraform. It is the evolution of Assignments 1–2, where the same three services
ran directly on separate EC2 instances configured by Ansible.

> **Status note:** the `terraform/` (EC2 instances + VPC/NAT) and `ansible/` directories are kept
> for history/reference from Assignment 2. **They are no longer used to run the application.**
> Compute now happens entirely inside the Kubernetes cluster (`k8s/`). Terraform's remaining job
> for this assignment is provisioning the **managed AWS backing services** (RDS, S3, SNS, IAM).

---

## 1. Architecture

```
                         ┌───────────────────────────────────────────────────┐
                         │                 Kubernetes Cluster                 │
                         │              Namespace: devops-app                 │
                         │                                                     │
   Internet ──HTTP──▶  Service: frontend-service (LoadBalancer)               │
                         │        │                                            │
                         │        ▼                                            │
                         │  Deployment: frontend (nginx, 2 replicas)           │
                         │        │  ClusterIP only, egress → backend:5000     │
                         │        ▼                                            │
                         │  Service: backend-service (ClusterIP)               │
                         │        │                                            │
                         │        ▼                                            │
                         │  Deployment: backend (Flask/Gunicorn, 2 replicas)   │
                         │        │                                            │
                         │        ▼                                            │
                         │  Deployment: worker (background poller, 1 replica) │
                         │        (no Service — nothing talks to it, it only  │
                         │         polls the DB and calls out to AWS)         │
                         │                                                     │
                         │  ConfigMap: app-config   Secret: app-secrets        │
                         │  ServiceAccount: app-service-account (all 3 pods)  │
                         └───────────────────────────────────────────────────┘
                                      │                    │            │
                                      ▼                    ▼            ▼
                              RDS PostgreSQL             S3 bucket    SNS topic
                              (private subnet,          (file        (email
                               SG-restricted)            uploads)     alerts)
```

* **Frontend (`frontend-deployment` + `frontend-service`)** — nginx, serves the static UI and
  reverse-proxies `/api/*` to `backend-service`. The **only** component exposed outside the
  cluster (`type: LoadBalancer`).
* **Backend (`backend-deployment` + `backend-service`)** — Flask/Gunicorn API. Talks to RDS,
  uploads to S3, publishes to SNS. `ClusterIP` only — never reachable from the internet directly.
* **Worker (`worker-deployment`)** — polls the `items` table every `POLL_INTERVAL_SECONDS`,
  marks pending rows as done, and publishes an SNS summary. No Service object exists for it — it
  makes outbound calls only and accepts no inbound traffic (enforced by `NetworkPolicy`, see §7).

### What runs inside the cluster vs. outside it
| Inside Kubernetes | Outside the cluster (managed by Terraform) |
|---|---|
| frontend, backend, worker Pods | RDS PostgreSQL instance |
| ConfigMap / Secret / ServiceAccount | S3 bucket |
| NetworkPolicies, Services, LoadBalancer | SNS topic |
| | IAM policy for S3/SNS access |

We chose **RDS over an in-cluster PostgreSQL StatefulSet** (assignment option 1) because it
already existed from Assignment 2 and because a managed, backed-up, non-ephemeral database is the
realistic production choice — running Postgres as a pod is fine for learning purposes but loses
managed backups/HA/patching and ties data durability to cluster lifecycle, which is why the
assignment itself flags it as "practice only, not production-appropriate."

---

## 2. Building and Pushing Images

Each service has its own `Dockerfile` (`frontend/`, `backend/`, `worker/`):
* Base images are pinned (`python:3.11-slim`, `nginx:1.25-alpine`) — never `latest`.
* Each image runs as a **non-root user** (`appuser` for Python services, nginx's built-in
  non-root `nginx` user for the frontend, `runAsUser: 101`/`1000` enforced again at the pod level).
* `.dockerignore` excludes `.git`, `.env`, `venv/`, `__pycache__` from build context.
* Image tags pushed to ECR are pinned version tags (`v1.0.0`), never `latest`.

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

for service in frontend backend worker; do
  docker build -t devops-$service ./$service
  docker tag devops-$service:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-$service:v1.0.0
  docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-$service:v1.0.0
done
```

`setup.sh` automates this (build → tag → push) as part of the full deploy flow (§5).

**Image pulls from ECR:** the EKS worker nodes pull images using the **node IAM role**
(`AmazonEC2ContainerRegistryReadOnly`, attached by `eksctl` by default when the cluster is
created) — no `imagePullSecrets` are needed as long as the cluster and ECR repo are in the same
AWS account/region.

---

## 3. Namespace, ConfigMap, and Secrets

**Namespace** — everything runs in the dedicated `devops-app` namespace (never `default`):

```bash
kubectl apply -f k8s/00-namespace.yaml
```

**ConfigMap (`k8s/01-configmap.yaml`)** — non-sensitive settings only: `AWS_REGION`, `DB_PORT`,
`DB_NAME`, `DB_USER`, `POLL_INTERVAL_SECONDS`.

**Secret (`k8s/02-secret.yaml`, real values — never committed)** — `DB_PASSWORD`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Only `k8s/02-secret.example.yaml` (placeholder
values) is tracked in Git; `k8s/02-secret.yaml` is excluded via `.gitignore`.

To create the real secret by hand:

```bash
cp k8s/02-secret.example.yaml k8s/02-secret.yaml
# edit k8s/02-secret.yaml and fill in real DB_PASSWORD / AWS keys
kubectl apply -f k8s/02-secret.yaml
```

**How `setup.sh` handles this instead:** it prompts once (with input hidden, and a
confirmation re-type) for the DB password and AWS keys, at the very start of the run. That one
value is then reused for *two* things — passed to Terraform as the `TF_VAR_db_password`
environment variable (so it can set the real RDS master password) and base64-encoded into
`k8s/02-secret.yaml` (so the app can connect to that same database). The password is **never
written to `terraform.tfvars` or any other file** — it only exists in the script's memory for the
run's duration. This also removes an earlier bug in this repo's own tooling: it used to ask for
the DB password twice, once implicitly via `terraform.tfvars` and again for the Kubernetes
Secret — two independent typed values that had to coincidentally match, or the app would fail to
connect to a database whose password Terraform had just silently changed. `teardown.sh` reverses
this: after tearing everything down, it deletes the generated `k8s/02-secret.yaml` (real
credentials for infrastructure that no longer exists), and passes a throwaway value for
`terraform destroy` since a real password isn't needed to delete a database.

---

## 4. Deploying (kubectl / setup.sh)

Manifests are applied in this explicit order so dependencies (namespace → config → workloads)
exist before anything references them:

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/00-serviceaccount.yaml
kubectl apply -f k8s/01-configmap.yaml
kubectl apply -f k8s/02-secret.yaml
kubectl apply -f k8s/03-deployments.yaml
kubectl apply -f k8s/04-services.yaml
kubectl apply -f k8s/05-network-policies.yaml
```

**Do not run `kubectl apply -f k8s/` on the whole directory.** `k8s/02-secret.example.yaml` and
`k8s/02-secret.yaml` both define a Secret named `app-secrets` — applying both is order-dependent,
and whichever one is applied last silently becomes the live Secret in its entirety (Kubernetes
doesn't merge them key-by-key). If the placeholder example ever wins that race, pods get a
`DB_HOST` of `your-rds-endpoint.amazonaws.com` and crash-loop trying to resolve it. Applying files
individually, skipping the `.example.` one entirely, avoids the race altogether.

or end-to-end (creates the EKS cluster if it doesn't exist, provisions/reads Terraform outputs,
builds & pushes images, creates the Secret, and applies all manifests):

```bash
make k8s-deploy      # runs setup.sh
```

`setup.sh` steps: (0) pre-flight checks — `terraform`/`eksctl`/`aws`/`kubectl`/`docker` installed,
Docker daemon actually running, AWS credentials valid, `terraform.tfvars` present (and stripped
of any leftover `db_password`), and the EC2 key pair Terraform needs already exists — each fails
fast with an actionable message rather than partway into a 20-minute step → (1) prompt once for
the DB password (with confirmation) and AWS keys → (2) `terraform apply` (RDS, S3, SNS, IAM,
VPC/subnets), plus a warning if the SNS email subscription is still unconfirmed → (3) create the
EKS cluster inside that same VPC if it doesn't exist yet, and point `kubectl` at it → (4) open the
RDS security group to the EKS cluster → (5) write the ConfigMap → (6) write the Secret (reusing
the credentials from step 1) → (7) build/tag/push all three images to ECR → (8) apply each
manifest individually in dependency order (see above — deliberately not `kubectl apply -f k8s/`
on the whole directory), wait for all three Deployments to roll out, then print the LoadBalancer
URL and a few handy verification commands.

The script prints colored `==>` step headers and `✔`/`✘` markers as it goes, and fails fast with a
clear message (missing CLI tool, unreachable AWS credentials, mismatched password confirmation,
etc.) rather than partway through a long-running step.

---

## 5. Verifying the System Works

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -n devops-app
kubectl get deployments -n devops-app
kubectl get services -n devops-app
kubectl describe pod <pod-name> -n devops-app
kubectl logs <pod-name> -n devops-app
```

Functional checks:
1. **HTTP access:** open `http://<frontend LoadBalancer hostname>` (printed by `setup.sh`, or via
   `kubectl get svc frontend-service -n devops-app`).
2. **Frontend → backend:** creating an item in the UI calls `POST /api/items` on
   `backend-service:5000` through the nginx reverse-proxy config (`frontend/nginx.k8s.conf`).
3. **App → DB (RDS):** `GET /api/health` returns `{"db": "reachable"}`; new items appear with
   status `pending`, then flip to `done` after the worker's next poll cycle.
4. **S3:** uploading a file via the UI returns an `s3_key`/`s3_url` in the response.
5. **SNS:** creating an item or uploading a file triggers an email alert via the SNS topic.
6. **Resilience:** `kubectl delete pod <backend-pod> -n devops-app` — the Deployment recreates it,
   `readinessProbe` gates traffic until `/api/health` succeeds again, and the frontend keeps
   serving throughout (2 replicas).

*(Screenshots of the above commands/outputs are included in `Screenshots/`.)*

---

## 6. Deleting the Environment

```bash
make k8s-teardown     # runs teardown.sh
```

This deletes the Kubernetes workloads (`kubectl delete -f k8s/`), deletes the EKS cluster
(`eksctl delete cluster --name devops-cluster`), and destroys the Terraform-managed RDS/S3/SNS/IAM
resources (`terraform destroy`). Run this when you're done to avoid ongoing AWS charges (EKS
control plane, RDS instance, and any LoadBalancer all bill hourly).

---

## 7. Security

### Permission separation (ServiceAccounts)
All three Deployments currently share a single ServiceAccount, `app-service-account`, with **no
RoleBinding** attached — so by default it has no Kubernetes API permissions at all beyond the
implicit `system:authenticated` defaults (i.e., effectively none). No workload here calls the
Kubernetes API, so this is safe today, but it does mean Kubernetes-level RBAC currently provides
no *differentiation* between frontend/backend/worker — a compromised frontend pod's
ServiceAccount token is interchangeable with the backend's.
**Trade-off / known gap:** the assignment's bonus of one ServiceAccount per Deployment
(`frontend-sa`, `backend-sa`, `worker-sa`) was not implemented. It's the natural next step if this
project needed real RBAC (e.g., a controller reading Secrets or watching Pods) — separate SAs let
you scope a `Role`/`RoleBinding` per workload instead of one shared identity for all three.
**No workload is granted `cluster-admin` or any cluster-scoped role.**

### AWS permissions (no IRSA)
This cluster is a plain `eksctl`-created EKS cluster without an OIDC-based IRSA setup, so pods
authenticate to AWS using **static credentials** (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`)
injected via the Kubernetes `Secret`, scoped to an IAM user/policy limited to
`s3:PutObject`/`s3:ListBucket` on the one bucket and `sns:Publish` on the one topic (same
least-privilege policy defined in `terraform/iam.tf`).
**Drawbacks of this approach (vs. IRSA):**
- Credentials are long-lived and must be manually rotated; IRSA issues short-lived STS tokens per pod automatically.
- All pods that mount the Secret share one identity — no per-workload AWS permission boundary (frontend never needs AWS access at all, yet nothing technically prevents it from reading the same Secret if it were misconfigured to do so).
- A leaked Secret (e.g. from a misconfigured `kubectl describe` in a screen-share, or a compromised pod) is a leaked AWS credential until manually rotated, with no automatic expiry.
- **Mitigation path:** enabling IRSA (`eksctl utils associate-iam-oidc-provider` + an IAM role trust policy scoped to the `app-service-account`) would let pods assume the role via projected service-account tokens with zero static credentials in the cluster — the natural next step if this moved toward production.

### Secrets management
- Real secrets live only in a Kubernetes `Secret` (`app-secrets`), created from
  `k8s/02-secret.example.yaml` → `k8s/02-secret.yaml` (git-ignored) or interactively by
  `setup.sh`. No secret file with real values is ever committed.
- No external secret store (Sealed Secrets / External Secrets Operator / AWS Secrets Manager) is
  used — plain Kubernetes Secrets only. This is the simplest option but means secrets are only
  base64-encoded (not encrypted) at rest unless the cluster has envelope encryption enabled, and
  anyone with `get secret` RBAC access in the namespace can read them in plaintext.

### Network security
`k8s/05-network-policies.yaml` enforces:
- **frontend**: accepts ingress from anywhere (it's the public entry point); egress restricted to `backend-service:5000` + DNS (UDP/53).
- **backend**: accepts ingress **only** from pods labeled `app: frontend`; no egress restriction (needs to reach RDS/S3/SNS over the internet/VPC).
- **worker**: **denies all ingress** — nothing in or outside the cluster can initiate a connection to it; it only makes outbound calls (DB, SNS).
- **database (RDS)**: not a Kubernetes object, so protection happens at the AWS layer instead. `rds_sg` (`terraform/security.tf`) allows inbound `5432` only from the EKS cluster's shared node security group — not from `0.0.0.0/0`, and the RDS instance itself is `publicly_accessible = false`. `setup.sh` creates the EKS cluster inside the same VPC/subnets as RDS and adds this security-group rule automatically; see §9 for details.
- **Externally reachable**: only `frontend-service` (`type: LoadBalancer`). `backend-service` is `ClusterIP`; the worker has no Service object at all.

*Known gap:* backend/worker egress is currently unrestricted (any destination), which is
necessary today because they call AWS public endpoints (RDS, S3, SNS) rather than PrivateLink
endpoints. A tighter setup would add an egress allow-list (RDS CIDR + AWS service IP ranges only).

### Container security
Every container sets, at minimum:
```yaml
securityContext:
  runAsNonRoot: true          # pod-level, all three deployments
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```
Where a container needs to write at runtime, it gets an explicit writable `emptyDir` instead of a
writable root filesystem: nginx gets `/var/cache/nginx` + `/var/run`; backend gets `/tmp` (for
`werkzeug`'s temporary upload spooling); worker gets `/tmp` (for its liveness-probe heartbeat
file, since it has no HTTP port to probe).

### Image security
- All images are built from this repo's own `Dockerfile`s (not pulled pre-built from Docker Hub).
- Pinned base images (`python:3.11-slim`, `nginx:1.25-alpine`) and pinned application tags
  (`v1.0.0`) — `latest` is never used anywhere in the manifests.
- **Not yet done:** no vulnerability scanning (Trivy / Docker Scout / ECR scan-on-push) is wired
  in yet. This is the most valuable near-term improvement — ECR scan-on-push costs nothing extra
  and requires no pipeline changes.

### Ingress security
- Exposure is via a plain `Service` of `type: LoadBalancer` (AWS Classic/NLB), **not** a
  Kubernetes `Ingress` resource — chosen for simplicity over adding an ingress controller for a
  single public route.
- **No TLS/HTTPS today** — the LoadBalancer serves plain HTTP on port 80. Known trade-off, not a
  production-acceptable state.
- **No WAF / rate limiting / IP allow-listing** in front of the LoadBalancer.
- **Next step:** either add `cert-manager` + an ingress controller for path-based routing and
  automated TLS, or terminate TLS at an AWS NLB/ALB with an ACM certificate — both are listed as
  bonus items in the assignment and were consciously deferred to keep the base submission focused
  on the required Kubernetes primitives.

---

## 8. Trade-offs Summary

| Decision | Why | Cost |
|---|---|---|
| RDS instead of in-cluster Postgres | Reuse existing managed DB, real backups/HA | Extra AWS resource to manage/pay for |
| Static AWS creds in a Secret instead of IRSA | Simpler `eksctl` cluster, no OIDC setup | Long-lived credential, manual rotation |
| One shared ServiceAccount, no RBAC Roles | No workload calls the K8s API today | No identity separation if that changes |
| `LoadBalancer` Service instead of Ingress + TLS | One public route, avoids an ingress controller | No HTTPS, no path-based routing |
| Kubernetes Secrets only (no Sealed Secrets/ASM) | Simplicity for a course project | Secrets are only base64-encoded, not encrypted-at-rest by default |
| Raw manifests instead of Helm/Kustomize | Small, fixed set of resources | No templating/environments (dev/staging/prod) out of the box |

---

## 9. EKS ↔ RDS Network Connectivity

By default, `eksctl create cluster` builds its own brand-new VPC — separate from the VPC
Terraform created for RDS. Even in the same VPC, RDS's security group (`rds_sg`) originally only
allowed inbound `5432` from the old EC2 `backend_sg`/`worker_sg`, with no rule for EKS. Both are
now handled automatically by `setup.sh`:

1. **Same VPC, 2 Availability Zones:** EKS requires its control plane to span at least 2 AZs.
   The original VPC only had one "live" public subnet and one "live" private subnet (both in the
   same AZ) — `private_subnet_2` existed only to satisfy RDS's subnet-group requirement and had
   no internet route. `terraform/network.tf` now adds `public_subnet_2` (2nd AZ) and gives
   `private_subnet_2` a route through the NAT Gateway, so both AZs are usable for compute.
   `terraform/outputs.tf` exports `vpc_id`, `public_subnet_ids`, and `private_subnet_ids`
   (comma-separated pairs); `setup.sh` passes them straight to `eksctl create cluster
   --vpc-public-subnets=... --vpc-private-subnets=...`, so the cluster is built inside the
   *same* VPC/subnets RDS already lives in — no VPC peering needed.
2. **Firewall rule:** after the cluster exists, `setup.sh` looks up the EKS cluster's shared node
   security group (`aws eks describe-cluster ... clusterSecurityGroupId`) and adds a rule to
   `rds_sg` (via `aws ec2 authorize-security-group-ingress`) allowing inbound `5432` from that
   security group. The command is safe to re-run — if the rule already exists it's skipped rather
   than erroring.

**Fully automated:** `setup.sh` runs `terraform init`/`terraform apply -auto-approve` itself, then
reads every output it needs from that same apply — no manual `terraform apply` step required. It
also creates `terraform/terraform.tfvars` itself the first time you run it (prompting for
`bucket_name`/`my_email`, both non-sensitive) if the file doesn't already exist, and
`teardown.sh` deletes it again as its last step — so there's no manual file prep before your very
first run. `db_password` is deliberately **never** part of that file — see §3 for why.

---

## Legacy: Assignment 2 (EC2 + Terraform + Ansible)

Kept for reference — **not used to run the application anymore**.

<details>
<summary>Original EC2/Ansible architecture (click to expand)</summary>

The application originally ran on three separate Ubuntu servers in a strict 3-tier model:

1. **Frontend Server (Public Subnet):** Ran Nginx to serve the static website and act as a
   reverse proxy, routing API requests to the Backend server. Also acted as a Bastion Host for SSH
   tunneling.
2. **Backend Server (Private Subnet):** Ran a Python API (Flask + Gunicorn) that wrote data to the
   database, uploaded files to cloud storage, and triggered email alerts.
3. **Worker Server (Private Subnet):** Ran a Python script in the background that checked the
   database every 30 seconds for pending tasks.

**Terraform** provisioned: VPC, public/private subnets, Internet Gateway, NAT Gateway, dynamic
SSH security-group rules, least-privilege IAM instance profile, 3 EC2 instances, RDS, S3, SNS —
and generated the Ansible `inventory.ini`/`vars.yml` files.

**Ansible** installed Nginx + a self-signed TLS cert on the frontend, deployed the Python services
as systemd units on the backend/worker (tunneled through the frontend as a bastion), and ran
post-deploy HTTP health checks.

The `terraform/` directory in this repo still provisions RDS/S3/SNS/IAM (now consumed by the
Kubernetes workloads instead of EC2 instances); the EC2 instance resources and Ansible roles are
no longer part of the deploy path but are left in place as a record of the earlier architecture.

</details>
