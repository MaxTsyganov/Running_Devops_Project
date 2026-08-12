#!/bin/bash
set -e

# Installs Jenkins from scratch onto the existing EKS cluster (devops-cluster,
# built for Assignment 3/the app itself - this script assumes it and the
# devops-app namespace already exist, it doesn't create a cluster). Every
# permission, plugin, agent template, and job definition Jenkins ends up with
# comes from files in this repo - nothing here is a manual UI step.
#
# Idempotent: safe to re-run. kubectl apply/eksctl --override-existing-
# serviceaccounts/helm upgrade --install all no-op cleanly on an existing,
# unchanged install.

# output helpers - matches setup.sh's convention
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
step()    { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
info()    { echo "    $1"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }
fail()    { echo -e "${RED}✘ $1${RESET}"; exit 1; }

CLUSTER_NAME="devops-cluster"
AWS_REGION="us-east-1"
# Pinned against Artifact Hub at the time this was written - not "latest",
# same reasoning as EKSCTL_VERSION/ARGOCD_VERSION in setup.sh. The Jenkins
# CORE version is pinned separately, inside jenkins/values.yaml
# (controller.image.tag) - the chart version below only has to be new enough
# to support the JCasC/Kubernetes-cloud schema this project's values.yaml
# uses, independent of which controller image it deploys.
JENKINS_CHART_VERSION="5.9.54"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

step "[0/6] Pre-flight checks..."
for tool in aws kubectl eksctl helm; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "'$tool' is not installed or not on your PATH. Install it and re-run this script."
done
kubectl cluster-info >/dev/null 2>&1 \
    || fail "kubectl isn't pointed at a live cluster. Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION"
kubectl get namespace devops-app >/dev/null 2>&1 \
    || fail "Namespace 'devops-app' doesn't exist - this script installs Jenkins to build/deploy the app from Assignment 3, it doesn't stand up the app or the cluster itself. Run that project's own setup.sh first."
CI_ECR_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='DevOps-CI-ECR-Push-Policy'].Arn" --output text --region "$AWS_REGION")
[ -n "$CI_ECR_POLICY_ARN" ] \
    || fail "IAM policy 'DevOps-CI-ECR-Push-Policy' not found - run 'terraform apply' in terraform/ first (it defines ci-build-sa's ECR push permissions)."
success "Cluster reachable, devops-app namespace exists, CI ECR policy found."

step "[1/6] Creating the jenkins namespace..."
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
success "Namespace 'jenkins' ready (never running Jenkins in 'default', per the assignment's requirement)."

step "[2/6] Applying RBAC (controller + cd-deploy-sa)..."
# controller-rbac.yaml: Role/RoleBinding scoped to the jenkins namespace only
# - what the controller needs to launch/manage ephemeral agent Pods, nothing
#   about devops-app.
# cd-deploy-rbac.yaml: creates cd-deploy-sa itself (a plain ServiceAccount,
# not IRSA - it only ever calls the in-cluster Kubernetes API via kubectl/
# helm, never an AWS API, so it doesn't need an IAM role at all) plus the
# namespace-scoped Role/RoleBinding in devops-app and the one unavoidable
# narrow ClusterRole for reading the Namespace object itself (see that file's
# own header comment for why a namespace-scoped Role can never cover that).
kubectl apply -f jenkins/rbac/controller-rbac.yaml
kubectl apply -f jenkins/rbac/cd-deploy-rbac.yaml
success "controller and cd-deploy-sa RBAC applied."

step "[3/6] Creating ci-build-sa (IRSA, for pushing images to ECR)..."
# Unlike cd-deploy-sa, ci-build-sa DOES need IRSA: Kaniko pushes images
# straight to ECR, a real AWS API call, so it needs the AWS IAM role behind
# it - not just Kubernetes RBAC. It needs no Kubernetes Role at all (it never
# calls the Kubernetes API - Kaniko builds are pure container-filesystem
# work), which is why there's no ci-build-rbac.yaml alongside it.
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace jenkins --name ci-build-sa \
    --attach-policy-arn "$CI_ECR_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "ci-build-sa can now push to ECR via IRSA - no static registry credentials involved."

step "[4/6] Installing Jenkins (Helm chart + JCasC from jenkins/values.yaml)..."
helm repo add jenkinsci https://charts.jenkins.io >/dev/null
helm repo update jenkinsci >/dev/null
helm upgrade --install jenkins jenkinsci/jenkins \
    --namespace jenkins \
    --version "$JENKINS_CHART_VERSION" \
    -f jenkins/values.yaml \
    --wait --timeout 10m
success "Jenkins controller deployed and Ready (JCasC applied the Kubernetes cloud, agent templates, and plugin list automatically on boot)."

step "[5/6] Waiting for the controller Pod to fully settle..."
kubectl rollout status statefulset/jenkins -n jenkins --timeout=300s
success "Jenkins controller is up."

step "[6/6] Next steps"
info "Run jenkins/scripts/configure-jenkins.sh next - it wires up the webhook"
info "relay and prints the admin password + access instructions."
success "install-jenkins.sh complete."
