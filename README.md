# DevOps on AWS - 3-Tier App on Kubernetes with Jenkins CI/CD (Assignments 3-4)

This project runs a 3-tier app (nginx frontend, Flask backend, a background worker) on
**Kubernetes (EKS)**, backed by managed AWS services (**RDS PostgreSQL, S3, SNS**) provisioned
with **Terraform**. Infra bring-up (`setup.sh`) is fully automated, the Kubernetes side is packaged
as a **Helm chart**, and - as of Assignment 4 - the chart is built, tested, and deployed by a
self-hosted **Jenkins** running inside the same cluster: a real Git-push-triggered CI pipeline
builds and pushes immutable-tagged images, and a separate CD pipeline deploys the exact image CI
built via `helm upgrade --install`. See [§14](#14-jenkins-cicd-assignment-4) for the whole CI/CD
setup, or [History](#history) for what changed since Assignment 3 (which used ArgoCD/GitOps
instead - since replaced, see [§4](#4-application-deployment-history)).

This is the fourth iteration of the project. Assignments 1-2 ran the same three services directly
on EC2 instances, configured with Ansible. That setup is gone now - `terraform/` only provisions
the managed AWS backing services (RDS, S3, SNS, ECR, IAM), and all compute happens inside the
cluster. See [History](#history) at the bottom for what changed and why.

Built solo, not in a pair.

---

## Contents

1. [Architecture](#1-architecture)
2. [Building and pushing images](#2-building-and-pushing-images)
3. [The Helm chart](#3-the-helm-chart)
4. [Application deployment: history](#4-application-deployment-history)
5. [Deploying: `make k8s-deploy`](#5-deploying-make-k8s-deploy)
6. [Verifying the system works](#6-verifying-the-system-works)
7. [Tearing it down: `make k8s-teardown`](#7-tearing-it-down-make-k8s-teardown)
8. [Security](#8-security)
9. [Reliability](#9-reliability)
10. [Logging](#10-logging)
11. [Trade-offs](#11-trade-offs)
12. [EKS and RDS network connectivity](#12-eks-and-rds-network-connectivity)
13. [Repository layout](#13-repository-layout)
14. [Jenkins CI/CD (Assignment 4)](#14-jenkins-cicd-assignment-4)
15. [History](#history)

---

## 1. Architecture

This diagram is written in [Mermaid](https://mermaid.js.org/) and renders directly in GitHub's
Markdown preview - no exported image to keep in sync with the code, it's just text that changes
in the same commit as the architecture it describes.

Colors group nodes by who owns them: AWS-orange for managed AWS services, Kubernetes-blue for
workloads defined in the Helm chart, purple for GitOps tooling, grey for anything outside our AWS
account.

```mermaid
flowchart TB
    Internet(("🌐 Internet"))
    GH["📦 GitHub repo<br/>helm/devops-app chart"]

    subgraph AWS["AWS Account, us-east-1"]
        subgraph VPC["VPC 10.0.0.0/16, 2 Availability Zones"]
            LB["⚖️ frontend-service<br/>LoadBalancer, public subnets"]
            NAT["🔀 NAT Gateway<br/>public subnets"]

            subgraph EKS["EKS: devops-cluster, 3x t3.medium nodes, private subnets"]
                subgraph NsJenkins["namespace: jenkins"]
                    CD["🔧 Jenkins CD<br/>helm upgrade --install"]
                end
                subgraph NsApp["namespace: devops-app"]
                    FE["frontend Deployment<br/>nginx, 2 pods"]
                    BE["backend Deployment<br/>Flask, 2 pods"]
                    WK["worker Deployment<br/>1 pod"]
                    CFG["ConfigMap / Secret / ServiceAccounts"]
                end
            end

            RDS[("🐘 RDS PostgreSQL<br/>private subnets")]
        end

        S3[("🪣 S3 bucket")]
        SNS(["📧 SNS topic"])
    end

    Internet -- HTTP/HTTPS --> LB
    LB --> FE
    FE -- "ClusterIP :5000" --> BE
    BE --> RDS
    BE --> S3
    BE --> SNS
    WK --> RDS
    WK --> SNS
    GH -. push triggers CI, CI triggers this .-> CD
    CD -. deploys the exact image CI built .-> NsApp

    classDef aws fill:#FF9900,stroke:#232F3E,color:#232F3E,stroke-width:1.5px
    classDef k8s fill:#326CE5,stroke:#16305e,color:#ffffff,stroke-width:1.5px
    classDef tooling fill:#6f42c1,stroke:#4c2d8a,color:#ffffff,stroke-width:1.5px
    classDef external fill:#e8e8e8,stroke:#666666,color:#232F3E,stroke-width:1.5px

    class RDS,S3,SNS,NAT aws
    class FE,BE,WK,CFG,LB k8s
    class CD tooling
    class Internet,GH external
```

Full Jenkins CI/CD architecture (controller, agents, RBAC, the webhook path) is its own diagram -
see [`jenkins/architecture.mmd`](jenkins/architecture.mmd) and
[`jenkins/pipeline-flow.mmd`](jenkins/pipeline-flow.mmd), covered in [§14](#14-jenkins-cicd-assignment-4).

The worker has no inbound arrow on purpose - it only makes outbound calls (to RDS and SNS) and
accepts no inbound traffic at all, which is also enforced at the NetworkPolicy level (§8). Only
`frontend-service` crosses the cluster boundary to the internet; everything else is `ClusterIP`
or has no Service object at all.

* **Frontend** (`frontend-deployment` / `frontend-service`) - nginx. Serves the static UI and
  reverse-proxies `/api/*` to the backend. The only component exposed outside the cluster
  (`type: LoadBalancer`, both HTTP and self-signed HTTPS).
* **Backend** (`backend-deployment` / `backend-service`) - Flask + Gunicorn. Reads/writes RDS,
  uploads to S3, publishes to SNS. `ClusterIP` only, never reachable directly from the internet.
* **Worker** (`worker-deployment`) - polls the `items` table every `POLL_INTERVAL_SECONDS`
  (30s by default), marks pending rows as done, and sends an SNS summary. No Service object: it
  only makes outbound calls and accepts no inbound traffic at all (enforced by NetworkPolicy).

| Inside the cluster | Outside the cluster (Terraform) |
|---|---|
| frontend, backend, worker pods | RDS PostgreSQL instance |
| Jenkins (own `jenkins` namespace, Assignment 4 - see §14) | S3 bucket |
| cert-manager (own `cert-manager` namespace) | SNS topic + email subscription |
| Fluent Bit (own `amazon-cloudwatch` namespace) | CloudWatch Logs log group |
| ConfigMap / Secret / ServiceAccounts | IAM policies for S3/SNS/CloudWatch access, ECR, VPC/subnets |
| NetworkPolicies, Services, HPA, PDB | |

We use **RDS** instead of running PostgreSQL as a pod because it already existed from the earlier
assignments, and because a managed database with real backups doesn't tie the data's lifetime to
the cluster's. Running Postgres in-cluster is fine to learn from, but isn't what you'd do for data
you actually care about.

---

## 2. Building and pushing images

Each service has its own `Dockerfile`:

* Base images are pinned (`python:3.11-slim`, `nginxinc/nginx-unprivileged:1.30.4-alpine`), never
  `latest`.
* Every container runs as a **non-root user**: `appuser` (backend/worker), `USER 101` (frontend).
  The frontend uses `nginxinc/nginx-unprivileged` specifically, not the standard `nginx` image
  with a Kubernetes-level `runAsUser` override - the unprivileged image is non-root and listens on
  unprivileged ports (`8080`/`8443`) unconditionally, so it behaves identically whether it's run
  under Kubernetes or with a bare `docker run`, instead of only being safe because of an EKS host
  kernel setting.
* `.dockerignore` keeps `.git`, `.env`, `venv/`, `__pycache__` out of the build context.
* Images are scanned with **Trivy** locally during `setup.sh` (`--severity HIGH,CRITICAL`,
  non-blocking, `--exit-code 0`) if it's installed, purely for visibility during development. CI
  runs the same report *and* a second, blocking scan that fails the build on fixable `CRITICAL`
  findings (`--ignore-unfixed`, with `.trivyignore` for any documented exceptions) - see
  [§13](#13-repository-layout).
* Pushed to ECR with a pinned tag (`v1.0.0`), never `latest`.

`setup.sh` handles build, scan, tag, and push for all three images as part of the full deploy
(step 10 of 11, see [§5](#5-deploying-make-k8s-deploy)). The EKS worker nodes pull from ECR using
the node's own IAM role, so no `imagePullSecrets` are needed.

---

## 3. The Helm chart

The Kubernetes side lives entirely under `helm/devops-app/` - one chart, one release, no raw
manifests applied by hand. Templates cover: `Namespace`, `ConfigMap`, `SecretStore`,
`ExternalSecret`, `Certificate`, `ServiceAccount`, `Deployment` x3, `Service` x2, `NetworkPolicy`
x3, `PodDisruptionBudget` x2, `HorizontalPodAutoscaler` x2.

`values.yaml` only holds non-sensitive defaults (replica counts, resource requests/limits, HPA
thresholds). Anything that's real infrastructure data - the RDS endpoint, the S3 bucket name, the
Secrets Manager secret *name* holding the DB password (never the password itself, see
[§8](#8-security)) - is left blank there and supplied at deploy time (as of Assignment 4, by
Jenkins CD reading a ConfigMap - see [§14.6](#146-cd-pipeline-jenkinscdjenkinsfile)).
`helm/values-dynamic.example.yaml` shows the shape of those values, for anyone who wants to
`helm upgrade` by hand instead of going through Jenkins CD. TLS isn't part of this at all -
cert-manager issues the frontend's certificate directly in-cluster (see §8).

A couple of deliberate choices worth calling out:

* **`frontend-sa` is a plain ServiceAccount, `backend-sa`/`worker-sa` are not templated at all.**
  They're created separately by `eksctl create iamserviceaccount` before the chart is installed,
  because IRSA needs to annotate them with an IAM role ARN that only exists once the cluster's
  OIDC provider is set up - something a chart template can't know in advance.
* **There's no `Secret` template at all.** `app-secrets` is created entirely by External Secrets
  Operator (`SecretStore` + `ExternalSecret`), which reads the real password directly from AWS
  Secrets Manager at sync time - the value never passes through this chart, Helm, or this repo at
  any point. See [§8](#8-security) for why this replaced an earlier, simpler approach.
* **There's no `Namespace` template either**, as of Assignment 4 - `setup.sh` creates `devops-app`
  directly (`kubectl create namespace`), before IRSA needs it to exist. An earlier version of the
  chart *did* template the Namespace, which worked fine under ArgoCD (broader permissions, its own
  `CreateNamespace=true`) but broke under Jenkins CD's deliberately narrow, namespace-scoped RBAC -
  see [§14.6](#146-cd-pipeline-jenkinscdjenkinsfile) for the exact failure.

---

## 4. Application deployment: history

**As of Assignment 4, the app is deployed by Jenkins CD** (`jenkins/cd/Jenkinsfile`), not ArgoCD -
see [§14.5](#145-cd-pipeline-jenkinscdjenkinsfile) for how that actually works. This section is
kept as a record of the Assignment 3 approach it replaced and why.

<details>
<summary>Assignment 3: GitOps with ArgoCD (superseded)</summary>

The app used to be deployed and kept in sync by **ArgoCD** watching this GitHub repository, not by
a direct `helm upgrade --install` call. `setup.sh` installed ArgoCD into its own `argocd` namespace
and created an `Application` resource pointing at `helm/devops-app` on the `main` branch, with
`syncPolicy.automated: { prune: true, selfHeal: true }` - drift correction and prune-on-delete for
free.

This was retired for Assignment 4 for one concrete reason: `selfHeal: true` means ArgoCD reverts
any change to the live cluster that doesn't match what's committed in git. Jenkins CD deploys by
calling `helm upgrade --install` directly with a specific image tag - from ArgoCD's point of view,
that's drift from whatever's last synced, and it would revert it right back. Running both would
mean every Jenkins CD deployment gets silently undone a few seconds later. Since Assignment 4's
whole point is that Jenkins owns build *and* deploy, ArgoCD had to go - not just to avoid the
conflict, but because keeping an idle GitOps controller around (server, repo-server,
application-controller, redis, dex, notifications-controller - about 6-7 Pods) would burn cluster
headroom for a controller with no actual job left to do.

</details>

---

---

## 5. Deploying: `make k8s-deploy`

```bash
make k8s-deploy      # runs setup.sh
```

`setup.sh` is fully automated end to end. Roughly what happens, in order:

1. **Pre-flight checks** - confirms `terraform`, `eksctl`, `kubectl`, `helm`, `aws`, and `docker`
   are installed (offering to auto-install the first four if missing; `aws`/`docker` are never
   auto-installed, since they're often managed separately - a venv, or Docker Desktop). Confirms
   the Docker daemon is running and AWS credentials are valid. Creates `terraform/terraform.tfvars`
   on first run, asking only for a non-sensitive S3 bucket prefix and an email address.
2. **Database password** - prompted once, with confirmation, kept in memory only. Never written
   to `terraform.tfvars` or any other file on disk. The same value flows to both RDS and its
   Secrets Manager copy (next step) from this one prompt.
3. **Terraform apply** - provisions RDS, S3, SNS, IAM, the DB password's Secrets Manager secret,
   and the VPC/subnets.
4. **EKS cluster** - created inside that same VPC (if it doesn't already exist), so RDS is
   reachable without VPC peering.
5. **VPC CNI NetworkPolicy enforcement** - enabled explicitly on the `vpc-cni` addon
   (`enableNetworkPolicy: true`). Off by default on EKS - without this, the chart's `NetworkPolicy`
   objects would exist as API objects but nothing in the cluster would actually enforce them.
6. **Firewall rule** - opens the RDS security group to the EKS cluster's security group on 5432.
7. **IRSA** - creates the `devops-app` namespace directly (so it exists before anything needs it),
   associates an OIDC provider with the cluster, then creates `backend-sa` and `worker-sa`, each
   bound to its own least-privilege IAM policy (backend: S3 + SNS; worker: SNS only - see
   [§8](#8-security)).
8. **External Secrets Operator** - creates `external-secrets-sa` (IRSA, scoped to `GetSecretValue`
   on exactly the one Secrets Manager secret from step 3) and installs ESO, which the chart's
   `SecretStore`/`ExternalSecret` templates depend on to populate `app-secrets`.
9. **cert-manager** - installs cert-manager if needed and creates a self-signed `ClusterIssuer`.
   The chart's `Certificate` resource uses this later to issue the frontend's TLS cert.
10. **Fluent Bit** - creates `fluent-bit-sa` (IRSA, scoped to just this project's CloudWatch log
    group) and installs Fluent Bit, which starts shipping container logs to CloudWatch immediately.
11. **Images** - builds, scans (Trivy, if available), tags, and pushes all three images to ECR
    (idempotent - skips a push if that exact immutable tag is already there).
12. **Publish infra config for CD** - publishes the `terraform-outputs` ConfigMap (RDS host, S3
    bucket, SNS topic ARN, the Secrets Manager secret name) in `devops-app`, then stops. **The app
    itself is not deployed by this script** - that's Jenkins CD's job (`cd-application`'s first
    run), once Jenkins is installed via [§14](#14-jenkins-cicd-assignment-4). This is a deliberate
    change from Assignment 3, where this same step installed ArgoCD and deployed the app itself -
    see [§4](#4-application-deployment-history) for why.

The whole run takes roughly 20-30 minutes on a first run, most of it waiting for the EKS cluster
to boot. Re-running it is safe: every step checks whether its target already exists before
creating anything.

---

## 6. Verifying the system works

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -n devops-app
kubectl get deployments -n devops-app
kubectl get services -n devops-app
kubectl get ingress -n devops-app
kubectl describe pod <pod-name> -n devops-app
kubectl logs <pod-name> -n devops-app
helm list -n devops-app
```

`kubectl get ingress` will correctly show no resources - this project exposes the app through a
`LoadBalancer` Service instead of a Kubernetes `Ingress` object (see §8), which is one of the
options this assignment allows, not a missing piece.

Functional checks:

1. **HTTP/HTTPS access** - open the URL `setup.sh` prints (or `kubectl get svc frontend-service
   -n devops-app`). The HTTPS cert is self-signed, so the browser will warn - that's expected.
2. **Frontend to backend** - creating an item in the UI calls `POST /api/items` through nginx's
   reverse proxy.
3. **App to RDS** - `GET /api/health` returns `{"db": "reachable"}`. New items start as `pending`
   and flip to `done` after the worker's next poll cycle.
4. **S3** - uploading a file returns an `s3_key`/`s3_url` in the response.
5. **SNS** - creating an item or uploading a file sends an email alert (once the SNS subscription
   is confirmed).
6. **Resilience** - `kubectl delete pod <backend-pod> -n devops-app`: the Deployment recreates it,
   the readiness probe gates traffic until `/api/health` succeeds again, and the frontend keeps
   serving throughout since it has 2 replicas.
7. **GitOps** - `kubectl get application devops-app -n argocd` should show `Synced`/`Healthy`. A
   manual `kubectl edit` to a Deployment gets reverted automatically within a few minutes (selfHeal).
8. **NetworkPolicy is actually enforced, not just defined** - with VPC CNI NetworkPolicy support
   enabled (step 4 of `setup.sh`), a pod without the `app: frontend` label should be refused when
   it tries to reach the backend directly:
   ```bash
   kubectl run netpol-test -n devops-app --rm -it --image=busybox --restart=Never -- \
     wget -qO- --timeout=5 http://backend-service:5000/api/health
   ```
   This should time out. The same request from a pod labeled `app: frontend` succeeds.

*(Screenshots and text captures of the commands above are in `Screenshots+txt_Files/01-Required-Commands/`
and `02-Functional-Checks/`.)*

---

## 7. Tearing it down: `make k8s-teardown`

```bash
make k8s-teardown     # runs teardown.sh
```

Run this when you're done, since the EKS control plane, the RDS instance, and any LoadBalancer
all bill hourly. This one script tears down both the app and Jenkins (Assignment 4) together -
`jenkins/scripts/uninstall-jenkins.sh` exists separately for removing just Jenkins while leaving
the app running (see [§14.10](#1410-cleanup)). Order matters here more than it looks:

1. Delete the `devops-app` namespace directly (cascades to the frontend's LoadBalancer Service and
   everything else in it). Also attempts `kubectl delete application devops-app -n argocd` first as
   a harmless no-op fallback, in case this cluster still has an Assignment-3-style ArgoCD
   Application from before the Jenkins CD switch ([§4](#4-application-deployment-history)).
2. Wait for the AWS load balancer to fully release. Deleting the Service only removes the
   Kubernetes object; the actual ELB is cleaned up asynchronously by a controller inside the
   cluster, and deleting the cluster too early orphans it.
3. Revoke the RDS security-group rule that references the EKS cluster's security group, so EKS
   can clean up its own security group properly.
4. Delete the Jenkins PVC (and confirm its underlying EBS volume actually finishes deleting) while
   the EBS CSI driver is still running - `helm uninstall`/`eksctl delete cluster` never delete a
   StatefulSet's PVC on their own, and the volume would otherwise silently outlive the cluster.
5. Delete the IRSA IAM roles for `backend-sa`/`worker-sa`/`fluent-bit-sa`/`external-secrets-sa`/
   `ci-build-sa` (each its own CloudFormation stack, separate from the cluster itself).
6. Delete the EKS cluster.
7. `terraform destroy` - removes RDS, S3, SNS, the now-Terraform-managed ECR repos
   ([§14.11](#1411-trade-offs-specific-to-assignment-4)), IAM, and the VPC.
8. Remove the local `terraform.tfvars` (recreated on the next `setup.sh` run).

`verify-teardown.sh` is a separate, read-only script that checks every category of resource that
either bills continuously or that `teardown.sh` has previously been found to miss - run it right
after every teardown, not just as an afterthought.

---

## 8. Security

**ServiceAccounts and IRSA.** `frontend-sa` is a plain ServiceAccount with no AWS access at all -
it never needs any. `backend-sa` and `worker-sa` each get their own IAM role via IRSA (IAM Roles
for Service Accounts): short-lived, auto-rotated tokens instead of long-lived access keys sitting
in a Kubernetes Secret. The two roles use **separate**, workload-scoped policies rather than one
shared policy - `backend-sa` gets `s3:PutObject`/`s3:ListBucket` on this project's one bucket plus
`sns:Publish` on its one topic; `worker-sa` gets `sns:Publish` only, since `worker.py` never
touches S3 at all. `fluent-bit-sa` (cluster infrastructure, not part of the app - see
[§10](#10-logging)) and `external-secrets-sa` (below) each get their own separate roles too, scoped
to exactly one thing each: writing to this project's one CloudWatch log group, and reading this
project's one Secrets Manager secret, respectively. No workload has any Kubernetes RBAC
permissions beyond the defaults; none of them call the Kubernetes API.

**Secrets.** The only thing in the Kubernetes `Secret` is `DB_PASSWORD`, and it's no longer
created directly at all - **External Secrets Operator** reads the real value straight from **AWS
Secrets Manager** and writes the `app-secrets` Secret itself. The chart's `SecretStore` (points ESO
at Secrets Manager, authenticating as the ESO controller's own IRSA-bound `external-secrets-sa` -
no per-store credential needed) and `ExternalSecret` (syncs one key, `DB_PASSWORD`, on a 1-hour
refresh interval) replace what used to be a plain `Secret` template fed a pre-base64-encoded value
through the ArgoCD `Application` spec.

That earlier approach had a real gap: the password was embedded in the `Application` object's
`spec.source.helm.valuesObject`, which persists as a live, readable cluster object - anyone with
permission to `kubectl get application devops-app -n argocd -o yaml` could read it directly,
base64 decoding being trivial. Now the `Application` object only ever holds a Secrets Manager
secret *name*, never a value; the actual password is fetched by ESO at sync time and never passes
through Helm, ArgoCD, or this repository at any point. `terraform/secrets.tf` provisions the
Secrets Manager secret from the same `db_password` Terraform variable already used for RDS - one
password prompt in `setup.sh`, flowing to both places.

AWS credentials never touch a Kubernetes Secret at all in this project, in either the old or new
approach - IRSA replaces them entirely, everywhere.

`helm/devops-app/secret.example.yaml` documents the resulting Secret's shape and where its value
actually comes from, since there's no `kubectl create secret` step to point at anymore - ESO
creates and refreshes it automatically once the `ExternalSecret` exists.

**Network policies.** Frontend accepts ingress from anywhere (it's the public entry point) but
egress only to the backend and DNS. Backend accepts ingress only from pods labeled `app: frontend`.
Worker denies all ingress - it only ever makes outbound calls. These are enforced, not just
defined: EKS ships the VPC CNI with `NetworkPolicy` enforcement **disabled** by default, so
`setup.sh` explicitly enables it on the `vpc-cni` addon (`enableNetworkPolicy: true`, step 4)
before anything else gets deployed. Without that, these three `NetworkPolicy` objects would exist
as API objects with no effect at all - see [§6](#6-verifying-the-system-works) for the negative
connectivity test proving enforcement is actually active. RDS isn't a Kubernetes object, so it's
protected at the AWS layer instead: its security group only allows inbound `5432` from the EKS
cluster's own security group, never `0.0.0.0/0`, and the instance itself is not publicly
accessible.

**Containers.** Every container sets `runAsNonRoot`, `allowPrivilegeEscalation: false`,
`readOnlyRootFilesystem: true`, and drops all Linux capabilities. Wherever a container needs to
write at runtime, it gets an explicit writable `emptyDir` instead of a writable root filesystem -
nginx's cache/pid directories, and a `/tmp` for the backend's upload spooling and the worker's
heartbeat file. The frontend's non-root behavior isn't only a Kubernetes-level override either:
its image is `nginxinc/nginx-unprivileged`, which is non-root and listens on unprivileged ports by
default, so the same guarantee holds under a bare `docker run` too (see [§2](#2-building-and-pushing-images)).

**Images.** Built from this repo's own Dockerfiles (nothing pulled pre-built from Docker Hub),
pinned base images and tags, scanned with Trivy before push - locally for visibility only, in CI
also as a blocking gate on fixable `CRITICAL` findings (see [§13](#13-repository-layout)).

**AWS resource security.** RDS storage and the SNS topic are both encrypted at rest with
AWS-managed KMS keys; the S3 bucket has SSE-S3 encryption and a full public access block (nothing
in this project ever needs a public S3 URL - the backend talks to it through IRSA). All of this,
plus the two public subnets' `map_public_ip_on_launch`, is checked automatically by `trivy config`
in CI - see [§13](#13-repository-layout). Customer-managed KMS keys would satisfy stricter
scanners too, but cost ~$1/month each for marginal benefit on data that isn't sensitive, so that
specific finding is suppressed with a documented reason rather than fixed (`terraform/data.tf`).

**Ingress/TLS.** Exposure is a plain `Service` of `type: LoadBalancer`, not a Kubernetes `Ingress`
resource - there's only one public route, so an ingress controller would be overhead without
benefit here. HTTPS is served with a certificate issued by **cert-manager**, from a `Certificate`
resource in the chart (`helm/devops-app/templates/certificate.yaml`) against a `selfSigned`
`ClusterIssuer`. Browsers still show a "not trusted" warning, since there's no real domain name
pointed at the load balancer to get a certificate from a real CA - but the cert itself is now
issued and auto-renewed declaratively by cert-manager instead of a one-off `openssl` command in a
bash script, which is the same mechanism a real ACME/Let's Encrypt setup would use, just pointed
at a self-signed issuer instead of a trusted one. There's no WAF or rate limiting in front of the
load balancer.

---

## 9. Reliability

* **Readiness/liveness probes** on all three Deployments, deliberately not identical between the
  two where it matters. Backend's *readiness* probe hits `/api/health`, which opens a real RDS
  connection - if RDS is briefly unreachable, the pod should stop receiving traffic. Its
  *liveness* probe hits a separate `/healthz` instead, which checks nothing but "is the Flask
  process still serving requests" - a transient RDS blip shouldn't get a perfectly healthy pod
  killed and restarted over a dependency outage that isn't its fault. The worker has no HTTP port,
  so it probes a heartbeat file it touches at startup and after every poll cycle; liveness fails if
  that file goes stale for more than 3x `POLL_INTERVAL_SECONDS` - read from the same environment
  variable `worker.py` itself uses, not a hardcoded number, so the threshold can't silently drift
  out of sync if the poll interval ever changes.
* **HorizontalPodAutoscaler** on frontend and backend (2-4 replicas, scaling on CPU utilization).
  The worker has no HPA - it's a single background poller by design, not something that needs to
  scale with request load.
* **PodDisruptionBudget** on frontend and backend (`minAvailable: 1`), so voluntary disruptions
  like node drains don't take both replicas down at once. The worker has no PDB: with only one
  replica, `minAvailable: 1` would forbid ever evicting it, blocking node drains instead of just
  slowing them down.
* **Jenkins CD's Verify stage** confirms every Pod is running the expected image tag on every
  deploy, and fails the build (with a printed rollback command) if rollout, verification, or the
  smoke test don't pass - see [§14.6](#146-cd-pipeline-jenkinscdjenkinsfile). (Assignment 3 used
  ArgoCD's `selfHeal`/`prune` for this instead - see [§4](#4-application-deployment-history).)

---

## 10. Logging

Container logs (all three services) are shipped to **CloudWatch Logs** by **Fluent Bit**, running
as a DaemonSet via AWS's own `aws-for-fluent-bit` chart. Like cert-manager, this is cluster
infrastructure installed directly by `setup.sh`, not part of `helm/devops-app` - it isn't
application logic, and none of the three services need to know it exists.

* **The log group is Terraform-managed** (`terraform/logging.tf`), not auto-created by Fluent Bit.
  That keeps its lifecycle tied to `terraform destroy` like every other piece of infrastructure in
  this project, rather than becoming a resource that only Fluent Bit knows how to clean up. A
  7-day retention period keeps CloudWatch storage cost bounded.
* **IRSA, same as everywhere else.** `fluent-bit-sa` gets its own IAM role, scoped to exactly
  `logs:CreateLogStream`, `logs:PutLogEvents`, and `logs:DescribeLogStreams` on this project's one
  log group - no `logs:CreateLogGroup`, since Fluent Bit never needs to create one itself.
* **Where to look:** the CloudWatch Logs console, log group `/devops-app/containers` (`setup.sh`
  prints a direct link at the end of a deploy), or `kubectl logs` for anything still running.

This is deliberately basic - one shared log group for all three services, not scoped per-namespace
or per-service, since that's what the assignment actually asks for. Splitting it further (per-app
log groups, structured JSON parsing, log-based metrics) would be the natural next step for
something closer to production.

---

## 11. Trade-offs

| Decision | Why | Cost |
|---|---|---|
| RDS instead of in-cluster Postgres | Reuse an existing managed DB with real backups | One more AWS resource to run and pay for |
| IRSA instead of static AWS keys in a Secret | Short-lived credentials, no manual rotation | Requires an OIDC provider and per-SA IAM roles |
| Helm chart instead of raw manifests | Single source of truth, reusable values | A little more indirection to read through |
| Jenkins CD (`helm upgrade --install`) instead of ArgoCD/GitOps | Assignment 4 requires a real CI/CD pipeline owning deploy directly - see [§4](#4-application-deployment-history) for why the two can't coexist | Deploy history lives in Helm release revisions, not a GitOps `Application`'s sync history |
| `LoadBalancer` Service instead of Ingress | Only one public route, no controller needed | No path-based routing |
| cert-manager with a self-signed issuer, not a real CA | No domain name to get a real cert for; cert-manager itself is still real | Browser warning on every visit |
| External Secrets Operator + AWS Secrets Manager, not a plain Kubernetes Secret | The password never has to pass through Helm or this repo at any point, and gets real encryption at rest | Another operator running in the cluster, another IAM role to manage |
| 3 nodes instead of 2 | Pod ceiling per node is set by network interface IP limits, not CPU/memory - kube-system + cert-manager + Jenkins + this app need more than 2 nodes' worth of slots | Small added hourly node cost |
| `t3.medium` nodes instead of `t3.small` (bumped for Assignment 4) | Adding Jenkins (a resident controller Pod, a resident webhook-relay Pod, and bursts of ephemeral CI/CD agent Pods) on top of an already-tight `t3.small` cluster (11 pods/node) risked agent Pods stuck `Pending` mid-build; `t3.medium` doubles memory per node and raises the ceiling to 17/node for the same node count | Roughly doubles hourly node cost |
| One shared CloudWatch log group, not per-service | This is basic logging, not a full observability stack | Harder to filter one service's logs out from the others |
| AWS-managed KMS keys, not customer-managed | S3/SNS encrypted at rest either way | Doesn't satisfy scanners requiring CMKs; ~$1/month each to fix |
| CI fails only on fixable `CRITICAL` image findings, not `HIGH` too | `HIGH` findings are still reported (non-blocking) for visibility; failing on every `HIGH` finding would block the pipeline on OS-level CVEs this project alone can't fix | A fixable `HIGH` vulnerability won't block a merge on its own |

---

## 12. EKS and RDS network connectivity

By default, `eksctl create cluster` builds its own new VPC, separate from the one Terraform
creates for RDS. Two things make them work together:

1. **Same VPC, 2 Availability Zones.** EKS requires its control plane to span at least 2 AZs.
   `terraform/network.tf` provisions 2 public and 2 private subnets across 2 AZs; `setup.sh` reads
   their IDs from Terraform's outputs and passes them straight to
   `eksctl create cluster --vpc-public-subnets=... --vpc-private-subnets=...`, so the cluster is
   built inside the exact same VPC RDS already lives in. No VPC peering needed.
2. **Firewall rule.** After the cluster exists, `setup.sh` looks up its security group and adds a
   rule to RDS's security group allowing inbound `5432` from it. This can't be done by Terraform
   alone, since the cluster (and its security group) doesn't exist yet at `terraform apply` time.
   `terraform/security.tf` marks that security group's `ingress`/`egress` as `ignore_changes`, so
   a later `terraform apply` doesn't wipe out the rule `setup.sh` added out of band.
3. **`--node-private-networking`.** Passing both subnet types to `eksctl` only tells it which
   subnets exist in the VPC - without this flag, the managed node group can still land in the
   public ones, and since `map_public_ip_on_launch` is `true` there, every node would get a real
   public IP. This flag forces the node group into the private subnets specifically, with no
   public IP at all; the NAT Gateway (already routed from the private route table) still gives
   them outbound internet access for pulling images and reaching the EKS API.

---

## 13. Repository layout

```
setup.sh, teardown.sh, verify-teardown.sh   Infra bring-up / full teardown / clean-teardown check
Makefile                   make k8s-deploy / make k8s-teardown / raw terraform targets
.github/workflows/ci.yml   terraform validate + helm lint + Trivy on every push/PR
.trivyignore               Accepted-risk CVE allowlist for image scanning (empty - nothing needed yet)
terraform/                 RDS, S3, SNS, ECR, Secrets Manager, CloudWatch log group, IAM policies,
                           VPC/subnets - no compute
helm/devops-app/           The Kubernetes side: one Helm chart, deployed by Jenkins CD (§14)
helm/values-dynamic.example.yaml   Template for deploying the chart by hand, bypassing Jenkins
frontend/                  nginx (unprivileged), static UI, reverse proxy to backend
backend/                   Flask + Gunicorn API (RDS, S3, SNS)
worker/                    Background poller (RDS, SNS)
jenkins/                   Assignment 4: Jenkins install/config scripts, CI+CD Jenkinsfiles,
                           JCasC values, RBAC, job configs, architecture diagrams (see §14)
Screenshots+txt_Files/     Evidence captures: required commands, functional checks,
                           resilience test, and bonus objectives (see §6)
```

**CI** (`.github/workflows/ci.yml`) runs `terraform fmt`/`validate`, `helm lint` plus a full
`helm template` render, builds + Trivy-scans all three images, and runs `trivy config` against
both `terraform/` and `helm/devops-app/` for misconfigurations - on every push and pull request to
`main`. It's validation only, deliberately - this repo is public, and wiring real AWS credentials
into Actions secrets so every push could deploy to live infrastructure is a different risk profile
than read-only checks. Actual deployment stays a manual `make k8s-deploy`.

The `trivy config` job, and now the image scan too, are both blocking. Image scanning runs twice:
once reporting `HIGH`+`CRITICAL` non-blocking (saved as a build artifact for each service, purely
for visibility - unfixable CVEs included), and once scoped to fixable `CRITICAL` findings only
(`--ignore-unfixed`) that fails the build if it finds one. Accepted-risk exceptions go in
`.trivyignore` with a documented reason, not a blanket `exit-code` override. Every misconfiguration
`trivy config` currently knows about in this repo has already been fixed or explicitly suppressed
with a documented reason in the code itself; a clean run should always pass.

---

## 14. Jenkins CI/CD (Assignment 4)

Jenkins runs *inside* the same EKS cluster as the app, as a Kubernetes-native controller with
ephemeral build agents - not a separate box, not a SaaS CI. This section covers everything
specific to Assignment 4: installing Jenkins from code, the CI and CD pipelines, how they connect,
security, and cleanup.

### 14.1 Architecture and environment choice

Jenkins runs in the same `devops-cluster` EKS cluster as the app (a separate cluster was the other
option the assignment allows, but would mean a second cluster's worth of cost and a cross-cluster
credential the CD pipeline would need to manage, for no real isolation benefit at this scale - the
`jenkins` and `devops-app` namespaces already provide the separation that matters: distinct RBAC,
distinct ServiceAccounts, no shared secrets).

```
jenkins namespace                          devops-app namespace
┌─────────────────────────────┐            ┌──────────────────────────┐
│ jenkins-0 (controller)       │            │ frontend/backend/worker  │
│  - never runs builds         │            │  deployments             │
│  - PVC: jenkins home (8Gi)   │            │                          │
│ webhook-relay                │  CD agent  │                          │
│                               │  deploys → │                          │
│ ci-agent Pod (ephemeral)  ────┼── pushes ─→│ ECR (958...:us-east-1)  │
│ cd-agent Pod (ephemeral)  ────┼───────────→│                          │
└─────────────────────────────┘            └──────────────────────────┘
```

**Security boundary**: the Jenkins UI has no public IP, Ingress, or LoadBalancer - it's a plain
`ClusterIP` Service, reachable only via `kubectl port-forward` (see [§14.7](#147-network-and-exposure)).
Inbound webhook traffic never reaches Jenkins directly either: GitHub POSTs to a public
[smee.io](https://smee.io) channel, and a `webhook-relay` Deployment inside the cluster holds an
*outbound* connection to that channel and forwards matching events to Jenkins' internal
`/github-webhook/` endpoint over the in-cluster network. Jenkins ends up with zero inbound ports
open to the internet, in either direction.

**How CD authenticates to the target cluster**: since Jenkins and the app share a cluster, the CD
agent Pod authenticates via its own `cd-deploy-sa` Kubernetes ServiceAccount token (automatically
mounted, in-cluster) - no kubeconfig, no static credential, nothing to rotate. If the target were a
different cluster, this would instead need a stored kubeconfig/token as a Jenkins Credential, scoped
as narrowly as `cd-deploy-sa` is now.

### 14.2 Prerequisites and versions

| Tool | Version | Where pinned |
|---|---|---|
| EKS cluster | Kubernetes 1.34 | `setup.sh` (`eksctl create cluster`) |
| Jenkins controller image | `jenkins/jenkins:2.541.3-lts-jdk17` | `jenkins/values.yaml` |
| Jenkins Helm chart | `5.9.54` (jenkinsci/jenkins) | `jenkins/scripts/install-jenkins.sh` |
| eksctl | `v0.229.0`/`0.230.0` | `setup.sh`, `jenkins/scripts/install-jenkins.sh` |
| Helm | `v3.21.4` | client-side, any recent 3.x |
| kubectl / aws-cli | any recent version | client-side |

Also requires: an EKS cluster and `devops-app` namespace already brought up via this repo's own
`setup.sh` (Jenkins is layered on top of Assignment 3's infra, it doesn't create a cluster itself),
and a GitHub repository with permission to add a webhook.

### 14.3 Installing Jenkins from code

Four scripts, each idempotent (safe to re-run) and each doing exactly one thing:

```bash
bash jenkins/scripts/install-jenkins.sh     # namespace, RBAC, ci-build-sa, EBS CSI driver +
                                             # StorageClass, the Jenkins Helm release + JCasC
bash jenkins/scripts/configure-jenkins.sh   # prints admin password, mints the smee.io channel,
                                             # deploys webhook-relay, creates the webhook secret
bash jenkins/jobs/create-jobs.sh            # creates/updates ci-application + cd-application
                                             # via Jenkins' REST API (needs a port-forward - see below)
bash jenkins/scripts/verify-jenkins.sh      # read-only health check against everything above
bash jenkins/scripts/uninstall-jenkins.sh   # removes Jenkins only - app and cluster untouched
```

`create-jobs.sh` needs Jenkins reachable at `http://localhost:8080`:

```bash
kubectl port-forward svc/jenkins -n jenkins 8080:8080 &
bash jenkins/jobs/create-jobs.sh
```

None of this is done through the Jenkins UI. `install-jenkins.sh` applies RBAC and IRSA from files
in this repo, then installs the official `jenkinsci/jenkins` Helm chart with
[JCasC](https://github.com/jenkinsci/configuration-as-code-plugin) (`jenkins/values.yaml`) driving
the plugin list, the Kubernetes cloud, and both agent pod templates - the controller comes up
already fully configured, no manual "click through setup wizard" step exists. `create-jobs.sh`
creates the two jobs from the `config.xml` files in `jenkins/jobs/` via Jenkins' own REST API - the
one alternative to a Job DSL seed job or a Multibranch Pipeline, and the one this project uses
because an earlier attempt at a JCasC-driven seed job crashed the controller's entire boot
sequence on a syntax slip (see `jenkins/values.yaml`'s own comment): a bug in job creation now
only fails `create-jobs.sh`, never brings the controller down.

**A note on Windows**: if running these scripts from Git Bash on Windows, `kubectl exec ... --
/bin/cat ...` needs `MSYS_NO_PATHCONV=1` set (already done inside the three scripts that need it) -
without it, MSYS rewrites the Unix path argument into a Windows path before it reaches the
container. No-op on Linux/Mac.

### 14.4 Jenkins Configuration as Code (JCasC)

Everything under `controller.JCasC.configScripts` in `jenkins/values.yaml` becomes live controller
configuration on boot - no manual System Config page was ever touched:

- **Kubernetes cloud** (`devops-agents`): where ephemeral agent Pods get scheduled from, pointed at
  the in-cluster API server, capped at 10 concurrent agent Pods, `podRetention: never` (agents are
  deleted immediately after their build, not kept around).
- **Agent templates**: `ci-agent` (two containers - `python` for lint/test, `kaniko` for the image
  build; `serviceAccount: ci-build-sa`) and `cd-agent` (one `deploy` container with `kubectl`+`helm`;
  `serviceAccount: cd-deploy-sa`). Both templates set explicit `resourceRequest*`/`resourceLimit*`
  on every container.
- **Plugin list**: `kubernetes`, `kubernetes-credentials-provider`, `workflow-aggregator`, `git`,
  `github`, `job-dsl`, `configuration-as-code`, `credentials-binding`, `timestamper`, `ws-cleanup` -
  named only, no individual version pins (an earlier attempt pinning each plugin's version hit a
  `ClassNotFoundException` from mutually-incompatible pinned versions; the installer resolves a
  compatible set for a given Jenkins core version far more reliably than hand-pinning each one).

### 14.5 CI Pipeline (`jenkins/ci/Jenkinsfile`)

Trigger: `triggers { githubPush() }`, wired to the job via `com.cloudbees.jenkins.GitHubPushTrigger`
in `jenkins/jobs/ci-application-config.xml` (the trigger has to be declared there too - `githubPush()`
alone inside the Jenkinsfile isn't enough for Jenkins to register it as a live trigger before a
first build has already run with it configured).

| Stage | What it does |
|---|---|
| Checkout | Pulls the repo, computes `IMAGE_TAG` = short (8-char) commit SHA |
| Validation | Confirms every service's `Dockerfile`/`.dockerignore` and the Helm chart exist |
| Static Analysis / Lint | `pyflakes` against `backend/app.py` and `worker/worker.py` |
| Tests | `pytest` against `backend/test_app.py`, results published via `junit` |
| Build | Kaniko builds and pushes all three images in one step (no Docker socket - see [§14.7](#147-container-security)) |
| Scan | Trivy scans each pushed image straight from ECR - HIGH+CRITICAL reported non-blocking (archived as a build artifact), fixable CRITICAL findings fail the build (`--ignore-unfixed`, `.trivyignore` for documented exceptions) |
| Publish Metadata | Archives `image-metadata.txt` (tag + digest per service) as a build artifact |

Runs on the `ci-agent` template as `ci-build-sa` (IRSA - pushes to/pulls from ECR via a real AWS IAM
role, no static registry credential anywhere in the pipeline). Images are tagged with the immutable
8-char commit SHA - never `latest` - and the three ECR repos are `IMAGE_TAG_MUTABILITY: IMMUTABLE`
(`terraform/ecr.tf`), so even a mistake can't silently overwrite a tag already in use. A failed
Test/Lint/Build/Scan stage fails the whole build (Declarative Pipeline's default) and never reaches
the `success` post-block that triggers CD - so a scan failure still guarantees nothing gets
deployed, even though (see [§14.11](#1411-trade-offs-specific-to-assignment-4)) Kaniko's build and
push happen as one atomic step, before the scan runs.

### 14.6 CD Pipeline (`jenkins/cd/Jenkinsfile`)

Never builds an image, never touches application source - checks out only to read the Helm chart.
Takes one parameter, `IMAGE_TAG`, and refuses to run without one or with `latest`.

| Stage | What it does |
|---|---|
| Checkout | Pulls the Helm chart only |
| Input Validation | Rejects a missing or `latest` `IMAGE_TAG` |
| Load infra config | Reads `dbHost`/`s3BucketName`/`snsTopicArn`/`dbPasswordSecretName` from the `terraform-outputs` ConfigMap `setup.sh` publishes in `devops-app` (these change every `terraform apply`, so they're read at deploy time, never hardcoded) |
| Manifest Validation | `helm lint --strict` + a full `helm template` render |
| Deploy | `helm upgrade --install devops-app ./helm/devops-app --set image.tag=$IMAGE_TAG ... --wait --timeout 10m` |
| Rollout | `kubectl rollout status` on all three Deployments |
| Verify | Confirms every Pod's image ends in `:$IMAGE_TAG` - fails the build if any doesn't |
| Smoke Test | Real HTTP request to the frontend LoadBalancer, retried for up to 2 minutes while its DNS propagates |

Runs on the `cd-agent` template as `cd-deploy-sa` - a plain (non-IRSA) ServiceAccount, since it only
ever calls the in-cluster Kubernetes API, never an AWS API directly.

**Traceability**: a CD build's console log shows exactly who triggered it
(`currentBuild.getBuildCauses()`), the image tag, target namespace/cluster, and - if triggered by
CI - the CI build that produced that tag is one click away (`ci-application`'s own build history,
keyed by the same commit SHA that *is* the image tag). `kubectl get pods -n devops-app -o
jsonpath='{..image}'` independently confirms the deployed tag matches.

**Rollback**: documented and tested via `helm rollback devops-app -n devops-app` (reverts to the
previous Helm release revision - a real command against a real Helm release history, not a
placeholder). The `post { failure { ... } }` block in `cd-Jenkinsfile` prints this exact command
plus `kubectl get events`/`describe pod` pointers whenever Rollout, Verify, or Smoke Test fails, so
the person looking at a failed build's console log has the fix in front of them immediately. Full
automated rollback-on-smoke-test-failure is listed as a bonus in the assignment brief and wasn't
implemented - a failed smoke test fails the build and leaves the previous, working revision live
underneath the (also live) failed one, rather than making an unattended decision to roll back
traffic on its own.

### 14.7 Jobs as code, and how CI connects to CD

Both jobs are created via `jenkins/jobs/create-jobs.sh` calling Jenkins' REST API with the
`config.xml` files in that same directory - `POST .../createItem` if the job doesn't exist yet,
`POST .../config.xml` (an update) if it does, so re-running after editing a Jenkinsfile or a
`config.xml` is a normal, safe operation. Creating either job by hand through the Jenkins UI is
explicitly out of scope for this assignment and isn't how these two ever get created here.

CI connects to CD via `build job: 'cd-application', parameters: [string(name: 'IMAGE_TAG', value:
env.IMAGE_TAG)], wait: false` in `ci-Jenkinsfile`'s `post { success { ... } }` block - CI hands CD
the exact tag it just pushed, `wait: false` so CI's own build finishes and frees its agent Pod
immediately rather than blocking on the entire CD run. Even though CD fires automatically, it still
exists as its own job with its own Jenkinsfile, satisfying the assignment's requirement that CI and
CD stay visibly separate pipelines.

### 14.8 Credentials and secrets

| Where a secret lives | How |
|---|---|
| ECR push (CI) | IRSA (`ci-build-sa` → `DevOps-CI-ECR-Push-Policy`) - no static credential exists |
| kubectl/helm access (CD) | `cd-deploy-sa`'s own ServiceAccount token, auto-mounted in-cluster |
| DB password | AWS Secrets Manager, read by External Secrets Operator - never touches Jenkins at all |
| GitHub webhook signature | Jenkins Credential `git-webhook-secret` (Secret text), created from a Kubernetes Secret labeled `jenkins.io/credentials-type: secretText` - picked up automatically by the Kubernetes Credentials Provider plugin, no JCasC edit or restart needed |

`jenkins/secrets/credentials.example.yaml` documents the one credential this project expects to
exist and what it's for - never a real value. `configure-jenkins.sh` generates the actual webhook
secret at runtime (`openssl rand -hex 20`), prints it once, and never writes it to git; the
credential is idempotent to re-run (an existing `git-webhook-secret` Secret is left alone rather
than rotated, so it never desyncs from what's actually configured on GitHub's side).

**To replace/revoke a credential**: delete the Kubernetes Secret it's backed by
(`kubectl delete secret git-webhook-secret -n jenkins`), re-run `configure-jenkins.sh` to mint a
new one, and update the webhook's secret on the GitHub side to match. No Jenkins restart needed -
the Credentials Provider plugin watches for the Secret to reappear.

Console log masking: Jenkins' `credentials-binding` plugin masks any credential value it injects
automatically. Nothing in either Jenkinsfile ever echoes a credential directly, and image tags/ECR
URLs/namespaces are all non-secret by design (see [§14.2](#142-prerequisites-and-versions) table),
so there's nothing sensitive to accidentally print in the first place.

### 14.9 Security

**RBAC**: no `cluster-admin` anywhere. `jenkins-controller` (Role, namespace-scoped to `jenkins`)
can only manage Pods/PVCs/events in its own namespace and read Secrets/ConfigMaps there - it never
gets `devops-app` access, since the controller itself never deploys anything. `cd-deploy-sa` (Role,
namespace-scoped to `devops-app`) can manage exactly the resource types Helm needs there
(Deployments, Services, ConfigMaps, Secrets, Ingresses, NetworkPolicies, HPAs, Certificates,
ExternalSecrets) - plus one unavoidable narrow `ClusterRole`, `get`-only and `resourceNames`-scoped
to exactly `devops-app`, since a namespace-scoped Role can never grant access to the (cluster-scoped)
Namespace object itself, which `helm upgrade --install` always checks for regardless of
`--create-namespace`. `ci-build-sa` needs no Kubernetes RBAC at all - Kaniko builds are pure
container-filesystem work, it never calls the Kubernetes API.

**Container/agent security**: no build ever runs on the controller (`numExecutors: 0` -
structurally impossible, not just discouraged). No agent mounts the node's Docker socket - CI
builds with Kaniko (daemonless OCI image builds), CD uses a prebuilt `kubectl`+`helm` image. Every
container in both agent templates sets explicit CPU/memory requests and limits. The webhook-relay
Pod runs as `runAsNonRoot`, `allowPrivilegeEscalation: false`, all capabilities dropped, read-only
root filesystem. Both the Jenkins controller image and agent container images are pinned to a fixed
tag, never `latest`.

**Network**: Jenkins UI is `ClusterIP` only - not exposed publicly, reachable only via
`kubectl port-forward svc/jenkins -n jenkins 8080:8080`. Inbound webhook traffic never reaches
Jenkins directly (see [§14.1](#141-architecture-and-environment-choice)'s relay explanation).
`NetworkPolicy` objects specifically for the `jenkins` namespace aren't implemented - the app side
already has them (`helm/devops-app`, see [§8](#8-security)), and Jenkins' own traffic pattern
(controller ↔ ephemeral agents ↔ Kubernetes/ECR/GitHub APIs) is broad enough by nature that a
meaningfully restrictive policy would need per-agent-template rules this project didn't get to -
documented here as a known gap rather than left silently unaddressed.

**Endpoints this setup actually talks to**: GitHub (`github.com`, checkout + webhook delivery via
smee.io), ECR (`*.dkr.ecr.us-east-1.amazonaws.com`, image push/pull), the in-cluster Kubernetes API
server (`kubernetes.default.svc`), and AWS Secrets Manager (via External Secrets Operator, not
Jenkins directly).

### 14.10 Cleanup

`jenkins/scripts/uninstall-jenkins.sh` removes Jenkins, its PVC, RBAC, the webhook relay, and
`ci-build-sa` - leaving `devops-app` and the cluster itself running. For tearing down everything
(cluster, RDS, Jenkins, all of it), `teardown.sh` already includes the Jenkins-specific steps this
assignment added (deleting the Jenkins PVC/EBS volume and `ci-build-sa`'s IRSA stack before the
cluster disappears - see `teardown.sh`'s own step comments for why order matters here).

### 14.11 Trade-offs specific to Assignment 4

| Decision | Why | Trade-off |
|---|---|---|
| Jenkins in the same cluster as the app | No second cluster's cost, no cross-cluster credential for CD to manage | Less blast-radius isolation than a fully separate Jenkins cluster |
| Job creation via REST API script, not Job DSL seed job or Multibranch Pipeline | A JCasC-driven seed job crashed the whole controller boot on a syntax slip - a bug here now only fails one script | An extra manual step (`create-jobs.sh`) instead of jobs appearing automatically on controller boot |
| No automated rollback on smoke-test failure | Rolling back traffic unattended is itself a risky automated decision; a failed build with a clear rollback command in the log is safer for a human to review first | Slightly slower recovery than full automation (a bonus item, not required) |
| Custom webhook relay instead of the official `smee-client` npm package | `smee-client` (all versions checked) has a real upstream bug reusing an incoming header value on its own outgoing request - reproduced only with real GitHub traffic, not synthetic test POSTs | ~100 lines of relay code to maintain instead of a dependency |
| `webhook_content_type: json` via a raw API request, not `gh api`'s `-f config[key]=value` flags | `gh api -f config[content_type]=json` silently failed to nest into GitHub's webhook config - GitHub defaulted to form-encoding instead, which broke the Jenkins GitHub plugin's payload parser (`GHEventPayload$Push.getRepository()` returned null) until this was caught via a captured raw payload and the hook was recreated with an explicit JSON body | One more thing to get right if this hook is ever recreated by hand |
| Trivy scans the image *after* Kaniko has already pushed it, not before | Kaniko builds and pushes as one atomic `--destination` step - there's no local, daemon-accessible image to scan first without a separate build-to-tarball-then-push flow | A build that fails the Scan stage still leaves that (immutable-tagged, never referenced by any deploy) image sitting in ECR; the actual safety property - nothing gets deployed - still holds, since CD only ever triggers from CI's `success` post-block |

---

## History

Assignments 1-2 ran the app on three EC2 instances in a strict 3-tier layout: a frontend server
(also acting as an SSH bastion), a private backend server, and a private worker server, all
configured by Ansible over SSH. Terraform provisioned the VPC, the instances, RDS/S3/SNS, and the
IAM instance profile; Ansible installed nginx and a TLS cert on the frontend, deployed the Python
services as systemd units, and ran post-deploy health checks.

None of that runs the app anymore. The EC2 instances and Ansible playbooks have been removed from
this repository entirely - `terraform/` now only provisions the managed AWS services this
Kubernetes deployment still depends on (RDS, S3, SNS, the IAM policy, and the networking). Compute
moved to EKS, and deployment moved from a hand-run Ansible playbook to a Helm chart kept in sync
by ArgoCD.

A later hardening pass, prompted by an external technical review of this same submission,
addressed: NetworkPolicy objects that existed but weren't actually enforced (VPC CNI policy
support is off by default on EKS); the DB password being readable from the ArgoCD `Application`
object (replaced with External Secrets Operator + AWS Secrets Manager); a shared IAM policy
between backend and worker (split by actual least-privilege need); the frontend image having no
non-root user of its own (switched to `nginxinc/nginx-unprivileged`); backend's liveness probe
failing on RDS outages instead of just its readiness probe; a non-blocking CI image scan; and a
few smaller code-quality fixes (a connection-leak pattern, a tuple-instead-of-scalar bug, pinned
`eksctl`/ArgoCD versions instead of `latest`/`stable`).

Assignment 4 added a self-hosted Jenkins running inside the same cluster, with real CI (build,
test, scan, push - triggered by an actual GitHub webhook) and CD (deploy the exact image CI built,
verify, smoke-test) pipelines, fully covered in [§14](#14-jenkins-cicd-assignment-4). ArgoCD was
retired as part of this - see [§4](#4-application-deployment-history) for why running both would
have meant ArgoCD reverting every Jenkins CD deployment. Rebuilding the infrastructure for this
assignment also surfaced (and fixed) several gaps left over from Assignment 3 that had never been
exercised by a from-scratch rebuild before: the ECR repositories turned out to have been created by
hand outside Terraform entirely ([§14.11](#1411-trade-offs-specific-to-assignment-4)), the EKS
cluster had no way to satisfy a `PersistentVolumeClaim` (never needed until Jenkins' own storage
requirement), and the app chart's own `Namespace` template silently depended on ArgoCD's broader
permissions to work at all.
