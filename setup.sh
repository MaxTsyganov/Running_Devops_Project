#!/bin/bash
set -e

# output helpers
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
step()    { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
info()    { echo "    $1"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }
fail()    { echo -e "${RED}✘ $1${RESET}"; exit 1; }

# Pinned eksctl version, installed straight from GitHub releases (not a
# package manager) - bumped deliberately instead of always pulling whatever
# "latest" resolves to on a given run.
EKSCTL_VERSION="v0.229.0"

echo -e "${BOLD}=================================================================="
echo "  DevOps App - Infra Bring-Up"
echo "  This will: apply Terraform (RDS/S3/SNS/ECR), create or reuse an EKS"
echo "  cluster, install cert-manager and Fluent Bit, build & push images to"
echo "  ECR, then prepare the devops-app namespace for Jenkins CD - it does"
echo "  NOT deploy the app itself. That's the cd-application Jenkins job's"
echo "  first run (see jenkins/scripts/)."
echo "  Total time: ~20-30 minutes on a first run (mostly EKS cluster boot)."
echo "  You'll be asked for: an S3 bucket name prefix and an alert email (first"
echo "  run only), and a database password (every run, kept in memory only)."
echo "  This brings up real billable AWS resources (EKS + 3 nodes, RDS, a NAT"
echo "  gateway) - tear down with 'make k8s-teardown' when you're done."
echo -e "==================================================================${RESET}"

step "[0/11] Running pre-flight checks..."

info "Checking required CLI tools..."

# aws and docker are never auto-installed: aws-cli is often managed inside
# a venv (pip install awscli), and docker is usually Docker Desktop - a GUI
# installer this script can't drive.
for tool in aws docker; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "'$tool' is not installed or not on your PATH. Install it yourself and re-run this script."
done

install_terraform() {
    wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y terraform
}
install_kubectl() {
    local ver; ver=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
}
install_eksctl() {
    curl -fsSL -o /tmp/eksctl.tar.gz "https://github.com/eksctl-io/eksctl/releases/download/${EKSCTL_VERSION}/eksctl_$(uname -s)_amd64.tar.gz"
    tar -xzf /tmp/eksctl.tar.gz -C /tmp && rm -f /tmp/eksctl.tar.gz
    sudo mv /tmp/eksctl /usr/local/bin/eksctl
}
install_helm() {
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

# terraform/eksctl/kubectl/helm are plain binaries with no venv-conflict
# risk, so offering to install them is safe - but still asked one at a time,
# never silently, since each install runs real sudo commands.
for tool in terraform eksctl kubectl helm; do
    command -v "$tool" >/dev/null 2>&1 && continue
    echo -e "${YELLOW}    '$tool' is not installed.${RESET}"
    set +e
    read -r -p "    Install it now automatically? [y/N]: " REPLY
    set -e
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        info "Installing $tool..."
        "install_$tool"
        command -v "$tool" >/dev/null 2>&1 || fail "Automatic install of '$tool' did not succeed - install it manually and re-run."
        success "$tool installed."
    else
        fail "'$tool' is required. Install it manually and re-run this script."
    fi
done
success "terraform, eksctl, aws, kubectl, helm, docker all found."

info "Checking Docker is actually running..."
docker info >/dev/null 2>&1 \
    || fail "Docker is installed but the daemon isn't running. Start Docker Desktop (or the docker service) and try again."
success "Docker daemon is reachable."

info "Checking AWS credentials..."
# Most aws-cli calls below capture output into a variable, which never
# triggers a pager - but a few (like the security-group rule further down)
# print straight to the terminal, and aws-cli pipes that through `less` by
# default, silently blocking the script on a keypress. Disabling the pager
# globally avoids that for every call, not just the ones caught so far.
export AWS_PAGER=""
export AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || fail "Could not reach AWS. Run 'aws configure' first and make sure your credentials are valid."
export AWS_ACCOUNT_ID
CLUSTER_NAME="devops-cluster"
success "Authenticated to AWS account $AWS_ACCOUNT_ID."

info "Checking terraform.tfvars..."
if [ ! -f terraform/terraform.tfvars ]; then
    info "Not found - creating it now (asked once; only non-sensitive values are stored here)."
    set +e
    while true; do
        read -r -p "    S3 bucket name prefix (lowercase letters/numbers/hyphens, 3-63 chars): " BUCKET_NAME
        [[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] && break
        echo -e "${RED}    Invalid - lowercase letters, numbers, hyphens only, 3-63 characters.${RESET}"
    done
    read -r -p "    Email address for SNS alerts: " MY_EMAIL
    set -e
    cat <<EOF > terraform/terraform.tfvars
# Auto-generated by setup.sh - non-sensitive values only.
# db_password is handled separately and is NEVER written to this file.
# teardown.sh deletes this file automatically; setup.sh recreates it on the next run.
bucket_name = "${BUCKET_NAME}"
my_email    = "${MY_EMAIL}"
EOF
    success "terraform/terraform.tfvars created."
else
    success "terraform.tfvars already exists, reusing it."
fi
# db_password must never be persisted to disk - if an older tfvars file still has
# it (e.g. hand-edited), strip it so the fresh prompt below (via TF_VAR_db_password)
# is what actually gets used.
if grep -q '^db_password' terraform/terraform.tfvars 2>/dev/null; then
    sed -i '/^db_password/d' terraform/terraform.tfvars
    info "Removed db_password from terraform.tfvars - it's supplied securely below instead, never stored on disk."
fi

step "[1/11] Enter the database password for this run (kept in memory only, never written to disk)"
# No AWS Access Key / Secret prompt anymore - backend-sa and worker-sa get AWS
# permissions via IRSA (step 6) instead of long-lived static credentials.
set +e
while true; do
    read -rs -p "    Database password (min 8 characters): " DB_PASSWORD; echo
    read -rs -p "    Confirm database password: " DB_PASSWORD_CONFIRM; echo
    [ "$DB_PASSWORD" = "$DB_PASSWORD_CONFIRM" ] || { echo -e "${RED}    Passwords did not match, try again.${RESET}"; continue; }
    [ ${#DB_PASSWORD} -ge 8 ] || { echo -e "${RED}    Must be at least 8 characters (RDS requirement), try again.${RESET}"; continue; }
    break
done
set -e
export TF_VAR_db_password="$DB_PASSWORD"
success "Database password captured for this run."

step "[2/11] Applying Terraform (RDS, S3, SNS, IAM, networking)..."
cd terraform
terraform init -input=false
# -auto-approve: this script already stops (set -e) on any Terraform error,
# and re-running apply on unchanged infra is a safe no-op, so the
# interactive "yes" prompt is skipped to keep the deploy hands-off.
# -input=false, same reason: a missing variable should fail loudly, not
# block on a prompt with nobody watching for it.
terraform apply -auto-approve -input=false
VPC_ID=$(terraform output -raw vpc_id)
PUBLIC_SUBNET_IDS=$(terraform output -raw public_subnet_ids)
PRIVATE_SUBNET_IDS=$(terraform output -raw private_subnet_ids)
RDS_SG_ID=$(terraform output -raw rds_security_group_id)
RDS_ENDPOINT_FULL=$(terraform output -raw rds_endpoint)
DB_HOST=$(echo "$RDS_ENDPOINT_FULL" | cut -d':' -f1)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
SNS_TOPIC=$(terraform output -raw sns_topic_arn)
CLOUDWATCH_LOG_GROUP=$(terraform output -raw cloudwatch_log_group_name)
DB_PASSWORD_SECRET_NAME=$(terraform output -raw db_password_secret_name)
cd ..
success "AWS infrastructure ready (RDS: $DB_HOST)."

PENDING_EMAIL=$(aws sns list-subscriptions-by-topic --topic-arn "$SNS_TOPIC" --region "$AWS_REGION" \
    --query "Subscriptions[?SubscriptionArn=='PendingConfirmation'].Endpoint" --output text 2>/dev/null || true)
if [ -n "$PENDING_EMAIL" ]; then
    echo -e "${YELLOW}    ⚠ SNS email ($PENDING_EMAIL) hasn't been confirmed yet.${RESET}"
    echo "      Check that inbox and click the confirmation link, or alert emails won't arrive"
    echo "      (the app will still work and report success either way)."
fi

step "[3/11] Ensuring EKS cluster '$CLUSTER_NAME' exists inside VPC $VPC_ID..."
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    info "Cluster already exists, reusing it."
else
    info "Creating cluster inside the existing VPC/subnets (this takes 15-20 minutes)..."
    # 3 nodes, not 2: pod ceiling per node is set by ENI IP capacity
    # (EKS/VPC CNI), not CPU/memory. With kube-system, CoreDNS, cert-manager,
    # Jenkins, and this app all scheduled, 2 nodes isn't enough headroom; 3
    # is, for a small added cost.
    # t3.medium, not t3.small: Assignment 4 adds a resident Jenkins
    # controller Pod, a resident webhook-relay Pod, and bursts of ephemeral
    # CI/CD agent Pods on top of everything already competing for the same 3
    # nodes. t3.small's pod ceiling (11/node, 33 total) was already tight
    # before Jenkins; t3.medium doubles the memory per node, raising the
    # ceiling to 17/node (51 total) for the same node count - cheap
    # insurance against CI agent Pods stuck Pending mid-build.
    # --node-private-networking: passing both public and private subnets only
    # tells eksctl which subnets exist - without this flag it can still put
    # the managed node group in the public ones, which (since
    # map_public_ip_on_launch is true there) gives every node a real public
    # IP. This forces the node group into private subnets only, with no
    # public IP.
    eksctl create cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --vpc-public-subnets="$PUBLIC_SUBNET_IDS" \
        --vpc-private-subnets="$PRIVATE_SUBNET_IDS" \
        --node-private-networking \
        --nodes 3 \
        --node-type t3.medium \
        --managed
fi
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
success "kubectl is now pointed at '$CLUSTER_NAME'."

step "[4/11] Enabling VPC CNI NetworkPolicy enforcement..."
# Off by default on EKS - AWS ships the VPC CNI with policy enforcement
# disabled unless explicitly turned on. Without this, the NetworkPolicy
# objects the Helm chart creates are inert: they exist as API objects but
# nothing in the cluster enforces them.
aws eks update-addon \
    --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --addon-name vpc-cni \
    --configuration-values '{"enableNetworkPolicy":"true"}' \
    --resolve-conflicts OVERWRITE >/dev/null
aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --addon-name vpc-cni
kubectl rollout status daemonset/aws-node -n kube-system --timeout=180s
success "VPC CNI NetworkPolicy enforcement enabled - NetworkPolicy objects are now actually enforced."

step "[5/11] Allowing the EKS cluster to reach RDS on port 5432..."
EKS_SG_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG_ID" \
    --protocol tcp --port 5432 \
    --source-group "$EKS_SG_ID" \
    --region "$AWS_REGION" 2>/dev/null && success "Firewall rule added." \
    || info "Rule already exists, skipping."

step "[6/11] Setting up IRSA so backend/worker get AWS access without static keys..."
# IRSA lets a pod assume an IAM role via a short-lived token instead of a
# long-lived access key in a Secret. Needs an OIDC provider on the cluster
# plus a role per ServiceAccount, trusted only by that SA, using the same
# least-privilege policies from terraform/iam.tf. frontend-sa gets no role -
# it never talks to AWS.
#
# Namespace is created directly here, NOT as a chart template. cd-deploy-sa's
# RBAC (jenkins/rbac/cd-deploy-rbac.yaml) is deliberately read-only,
# resourceName-scoped to exactly "devops-app" on Namespace - it can check
# the namespace exists but can never create or own one (Namespace is
# cluster-scoped, so this is the one unavoidable exception to this project's
# namespace-scoped RBAC). A chart-templated Namespace would make `helm
# upgrade --install` (which CD runs as cd-deploy-sa) try to adopt it as part
# of the release - confirmed failing two ways: "invalid ownership metadata"
# on first install (the namespace wasn't created by Helm), and it would
# need write permissions CD deliberately doesn't have even if that were
# fixed. The namespace has to exist now anyway: eksctl needs somewhere to
# put backend-sa/worker-sa.
kubectl create namespace devops-app --dry-run=client -o yaml | kubectl apply -f -

eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
success "Cluster has an OIDC provider (required for IRSA)."

# Separate policies per workload: backend needs S3 + SNS, worker only ever
# calls SNS Publish (worker.py never touches S3) - see terraform/iam.tf.
BACKEND_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/DevOps-Backend-Least-Privilege-Policy"
WORKER_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/DevOps-Worker-Least-Privilege-Policy"

eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace devops-app --name backend-sa \
    --attach-policy-arn "$BACKEND_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "backend-sa can now reach S3/SNS via IRSA - no AWS keys involved."

eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace devops-app --name worker-sa \
    --attach-policy-arn "$WORKER_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "worker-sa can now reach SNS via IRSA - no AWS keys involved."

step "[7/11] Installing External Secrets Operator to sync the DB password from Secrets Manager..."
# Replaces passing the password through the ArgoCD Application's
# valuesObject, which persisted it, base64-only, as a readable live cluster
# object. The chart's SecretStore/ExternalSecret templates read the real
# value directly from AWS at sync time instead; only the ESO controller's
# own IRSA-bound ServiceAccount can read it, scoped to exactly this one
# secret (terraform/iam.tf).
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f - >/dev/null

ESO_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/DevOps-ExternalSecrets-Policy"
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace external-secrets --name external-secrets-sa \
    --attach-policy-arn "$ESO_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "external-secrets-sa can now read the DB password from Secrets Manager via IRSA."

helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo update >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --set installCRDs=true \
    --set serviceAccount.create=false \
    --set serviceAccount.name=external-secrets-sa \
    --wait --timeout 180s
success "External Secrets Operator installed."

step "[8/11] Installing cert-manager and creating a self-signed TLS issuer..."
# cert-manager issues and auto-renews the frontend's cert instead of a
# one-off openssl script. Still self-signed - there's no domain pointed at
# the load balancer to get a real CA-trusted cert from - but issued and
# rotated the same way a production cert-manager + Let's Encrypt setup
# would, just with a SelfSigned issuer instead of an ACME one.
if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
    info "Installing cert-manager (first run only)..."
    # --server-side: cert-manager's CRDs are too large for client-side
    # apply's last-applied-configuration annotation.
    kubectl apply --server-side --force-conflicts \
        -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml >/dev/null
else
    info "cert-manager already installed, reusing it."
fi
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s
success "cert-manager is ready."

# The webhook can take a few seconds to finish its own TLS bootstrap after its
# Deployment reports ready, so this is retried instead of failing the whole
# deploy over a transient timing issue.
CLUSTERISSUER=$(mktemp)
cat <<EOF > "$CLUSTERISSUER"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
ISSUER_READY=false
for _ in 1 2 3 4 5; do
    kubectl apply -f "$CLUSTERISSUER" >/dev/null 2>&1 && { ISSUER_READY=true; break; }
    sleep 5
done
rm -f "$CLUSTERISSUER"
[ "$ISSUER_READY" = true ] || fail "Could not create the ClusterIssuer after 5 attempts - check 'kubectl get pods -n cert-manager'."
success "Self-signed ClusterIssuer ready."

step "[9/11] Installing Fluent Bit to ship container logs to CloudWatch..."
# Fluent Bit is cluster infrastructure, not part of the app - same category
# as cert-manager, so it's installed directly here instead of folded into
# helm/devops-app. The log group is Terraform-managed (logging.tf), not
# auto-created by Fluent Bit, so IRSA only grants permission to write into
# that one existing group - never to create new ones.
kubectl create namespace amazon-cloudwatch --dry-run=client -o yaml | kubectl apply -f - >/dev/null

FLUENTBIT_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/DevOps-FluentBit-Logging-Policy"
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace amazon-cloudwatch --name fluent-bit-sa \
    --attach-policy-arn "$FLUENTBIT_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "fluent-bit-sa can now write to CloudWatch Logs via IRSA - no AWS keys involved."

helm repo add eks-charts https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks-charts >/dev/null
# serviceAccount.create=false: fluent-bit-sa already exists (created above,
# with the IRSA role annotation) - letting the chart create its own would
# mean a plain ServiceAccount with no AWS permissions at all.
# MSYS_NO_PATHCONV=1: on Windows Git Bash, MSYS rewrites any argument that
# looks like a Unix absolute path - and $CLOUDWATCH_LOG_GROUP (/devops-app/
# containers) is exactly that - into a literal Windows path before helm ever
# sees it. Confirmed live: Fluent Bit was stuck in CrashLoopBackOff trying
# to CreateLogStream in a log group literally named "C:/Program Files/Git/
# devops-app/containers", not the real one Terraform created - a silent
# failure nothing in this script's own checks caught, since `--wait` only
# confirms the Deployment rolled out, not that the container stayed healthy
# afterward. No-op everywhere else (Linux/Mac), same as the other scripts
# that already needed this.
MSYS_NO_PATHCONV=1 helm upgrade --install aws-for-fluent-bit eks-charts/aws-for-fluent-bit --version 0.2.0 \
    --namespace amazon-cloudwatch \
    --set serviceAccount.create=false \
    --set serviceAccount.name=fluent-bit-sa \
    --set cloudWatchLogs.region="$AWS_REGION" \
    --set cloudWatchLogs.logGroupName="$CLOUDWATCH_LOG_GROUP" \
    --set cloudWatchLogs.autoCreateGroup=false \
    --wait --timeout=180s
success "Fluent Bit is shipping container logs to CloudWatch Logs ($CLOUDWATCH_LOG_GROUP)."

step "[10/11] Building, scanning, tagging, and pushing Docker images to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com" >/dev/null

# Trivy is optional (bonus, not one of the hard-required tools from step 0) -
# scan if it's available, skip quietly if not.
HAVE_TRIVY=false
if command -v trivy >/dev/null 2>&1; then
    HAVE_TRIVY=true
else
    info "trivy not installed - skipping image vulnerability scanning (optional)."
    info "Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
fi

for service in frontend backend worker; do
    info "Processing $service..."
    docker build -q -t devops-$service ./$service

    if [ "$HAVE_TRIVY" = true ]; then
        info "Scanning devops-$service for HIGH/CRITICAL vulnerabilities..."
        # --exit-code 0: report findings but never fail the deploy over them -
        # base images like python:3.11-slim will always have some OS-level CVEs
        # that aren't practically fixable from this project alone.
        trivy image --severity HIGH,CRITICAL --quiet --exit-code 0 --table-mode summary devops-$service:latest
    fi

    docker tag devops-$service:latest "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-$service:v1.0.0"
    # ECR repos are IMMUTABLE (terraform/ecr.tf) - re-pushing an existing tag
    # errors instead of silently overwriting it, which is exactly what that
    # policy is for. v1.0.0 is a fixed baseline tag (unlike Jenkins CI's
    # per-commit-SHA tags), so re-running this script on an unchanged
    # Dockerfile/app needs to treat "tag already exists" as a no-op, not a
    # failure - the content is identical either way.
    if aws ecr describe-images --region "$AWS_REGION" --repository-name "devops-$service" \
        --image-ids imageTag=v1.0.0 >/dev/null 2>&1; then
        info "devops-$service:v1.0.0 already in ECR, skipping push."
    else
        docker push -q "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-$service:v1.0.0" >/dev/null
    fi
done
success "All 3 images built, scanned, and pushed as :v1.0.0."

step "[11/11] Publishing the terraform-outputs ConfigMap for Jenkins CD..."
# Assignment 3 deployed via ArgoCD (Application valuesObject + selfHeal).
# Assignment 4 replaced that with Jenkins CD deploying straight via `helm
# upgrade --install` (jenkins/cd/Jenkinsfile) - running both would mean
# ArgoCD's selfHeal reverts every Jenkins CD deploy back to whatever's last
# synced from git, fighting the pipeline this assignment is about.
# So infra bring-up stops here: it prepares the namespace and the one thing
# CD can't get any other way - the non-secret Terraform outputs (RDS host,
# S3 bucket, SNS topic ARN, the Secrets Manager secret name) that change on
# every `terraform apply` and so can't be hardcoded into the Jenkinsfile.
# CD's own Jenkinsfile deliberately never creates this namespace itself (see
# its "Deploy" stage) - first deploy is Jenkins CD's job, not this script's.
# The namespace already exists from step [6/11], so only the ConfigMap is
# new here.
kubectl create configmap terraform-outputs -n devops-app \
    --from-literal=dbHost="${DB_HOST}" \
    --from-literal=s3BucketName="${S3_BUCKET}" \
    --from-literal=snsTopicArn="${SNS_TOPIC}" \
    --from-literal=dbPasswordSecretName="${DB_PASSWORD_SECRET_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
success "terraform-outputs ConfigMap published in devops-app for Jenkins CD to read."

echo -e "\n${GREEN}${BOLD}=================================================================="
echo "  INFRA READY - IMAGES PUSHED - NO APP DEPLOYED YET"
echo -e "==================================================================${RESET}"
echo "  Cluster:    $CLUSTER_NAME (region $AWS_REGION)"
echo "  RDS host:   $DB_HOST"
echo "  S3 bucket:  $S3_BUCKET"
echo "  SNS topic:  $SNS_TOPIC"
echo "  Images:     ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/{devops-frontend,devops-backend,devops-worker}:v1.0.0"
echo ""
echo "  Next: install Jenkins (jenkins/scripts/install-jenkins.sh, configure-jenkins.sh,"
echo "  create-jobs.sh) - the app's first deployment happens via the cd-application"
echo "  Jenkins job, not this script."
echo ""
echo "  Check namespace/configmap: kubectl get configmap terraform-outputs -n devops-app -o yaml"
echo ""
echo "  Container logs (CloudWatch Logs console):"
echo "    https://$AWS_REGION.console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#logsV2:log-groups/log-group/\$252Fdevops-app\$252Fcontainers"
echo ""
echo "  Billing resources are now running - tear everything down when you're"
echo "  done: make k8s-teardown, then bash verify-teardown.sh to confirm."
echo -e "${GREEN}${BOLD}==================================================================${RESET}"
