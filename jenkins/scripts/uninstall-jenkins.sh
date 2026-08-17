#!/bin/bash
set -e

# Removes Jenkins and everything install-jenkins.sh/configure-jenkins.sh
# created, WITHOUT touching the app (devops-app namespace), the EKS cluster,
# or any Terraform-managed AWS infra - the counterpart to those two scripts,
# for when you want Jenkins gone but the app to keep running. For a full
# environment teardown (cluster, RDS, everything), use teardown.sh instead.
#
# Idempotent - safe to re-run; every step no-ops cleanly if its target is
# already gone.

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'
step()    { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
info()    { echo "    $1"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }

CLUSTER_NAME="devops-cluster"
AWS_REGION="us-east-1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

step "[1/4] Uninstalling the Jenkins Helm release..."
if kubectl get statefulset/jenkins -n jenkins >/dev/null 2>&1; then
    helm uninstall jenkins -n jenkins --wait --timeout=120s
    success "Jenkins controller removed."
else
    info "Jenkins release not found, nothing to uninstall."
fi

step "[2/4] Deleting the Jenkins home PVC..."
# helm uninstall deliberately never deletes a PVC (protects data by default)
# - same reasoning as teardown.sh's Jenkins PVC step. Left alone, the
# underlying EBS volume outlives Jenkins entirely and keeps costing money.
kubectl delete pvc --all -n jenkins --timeout=120s 2>/dev/null \
    && success "Jenkins home PVC deleted." \
    || info "No Jenkins PVC found."

step "[3/4] Removing the webhook relay, RBAC, and ci-build-sa..."
kubectl delete -f jenkins/webhook-relay.yaml --ignore-not-found=true
kubectl delete -f jenkins/rbac/cd-deploy-rbac.yaml --ignore-not-found=true
kubectl delete -f jenkins/rbac/controller-rbac.yaml --ignore-not-found=true
eksctl delete iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace jenkins --name ci-build-sa \
    --wait 2>/dev/null \
    || info "ci-build-sa IRSA stack already gone."
success "RBAC, webhook relay, and ci-build-sa removed."

step "[4/4] Deleting the jenkins namespace..."
kubectl delete namespace jenkins --ignore-not-found=true --timeout=90s
success "uninstall-jenkins.sh complete - devops-app and the cluster itself are untouched."

echo ""
echo "Note: the aws-ebs-csi-driver addon and ebs-gp3 StorageClass (install-jenkins.sh"
echo "step 4) are left in place - they're cluster-level infra, cheap to keep, and"
echo "harmless if nothing else in this project ever needed a PVC before Jenkins did."
echo "Remove them yourself if truly unwanted:"
echo "  eksctl delete addon --cluster $CLUSTER_NAME --region $AWS_REGION --name aws-ebs-csi-driver"
echo "  kubectl delete storageclass ebs-gp3"
