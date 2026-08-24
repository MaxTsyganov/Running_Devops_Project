#!/bin/bash
set -e

# Installs Jenkins from scratch onto the existing EKS cluster (devops-cluster,
# built for Assignment 3/the app itself). Assumes the cluster and devops-app
# namespace already exist - doesn't create a cluster. Every permission,
# plugin, agent template, and job definition Jenkins ends up with comes from
# files in this repo - nothing here is a manual UI step.
#
# Idempotent: safe to re-run. kubectl apply/eksctl --override-existing-
# serviceaccounts/helm upgrade --install all no-op cleanly on an existing,
# unchanged install.

CLUSTER_NAME="devops-cluster"
AWS_REGION="us-east-1"
# Pinned against Artifact Hub at the time it was checked - not "latest",
# same reasoning as EKSCTL_VERSION in setup.sh. The Jenkins CORE version is
# pinned separately, in jenkins/values.yaml (controller.image.tag) - the
# chart version below only has to be new enough to support the
# JCasC/Kubernetes-cloud schema this project's values.yaml uses,
# independent of which controller image it deploys.
JENKINS_CHART_VERSION="5.9.54"
# App version 1.35.0 - matches this cluster's EKS/Kubernetes 1.34 control
# plane (Cluster Autoscaler's own compatibility guidance: match the minor
# version, or use the next release up).
CLUSTER_AUTOSCALER_CHART_VERSION="9.59.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/output.sh"

step "[0/10] Pre-flight checks..."
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
CI_COSIGN_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='DevOps-CI-Cosign-Sign-Policy'].Arn" --output text --region "$AWS_REGION")
[ -n "$CI_COSIGN_POLICY_ARN" ] \
    || fail "IAM policy 'DevOps-CI-Cosign-Sign-Policy' not found - run 'terraform apply' in terraform/ first (it defines ci-build-sa's KMS signing permissions)."
success "Cluster reachable, devops-app namespace exists, CI ECR and Cosign policies found."

step "[1/10] Creating the jenkins namespace..."
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
success "Namespace 'jenkins' ready (never running Jenkins in 'default', per the assignment's requirement)."

step "[2/10] Applying RBAC (controller + cd-deploy-sa)..."
# controller-rbac.yaml: Role/RoleBinding scoped to the jenkins namespace
# only - what the controller needs to launch/manage ephemeral agent Pods,
# nothing about devops-app.
# cd-deploy-rbac.yaml: creates cd-deploy-sa itself (a plain ServiceAccount,
# not IRSA - it only calls the in-cluster Kubernetes API via kubectl/helm,
# never an AWS API, so it needs no IAM role) plus the namespace-scoped
# Role/RoleBinding in devops-app and the one unavoidable narrow ClusterRole
# for reading the Namespace object itself (see that file's own header
# comment for why a namespace-scoped Role can never cover that).
kubectl apply -f jenkins/rbac/controller-rbac.yaml
kubectl apply -f jenkins/rbac/cd-deploy-rbac.yaml
success "controller and cd-deploy-sa RBAC applied."

step "[3/10] Creating ci-build-sa (IRSA, for pushing to ECR and signing with Cosign)..."
# Unlike cd-deploy-sa, ci-build-sa does need IRSA: Kaniko pushes images
# straight to ECR and Cosign signs them via AWS KMS, both real AWS API
# calls, so it needs the AWS IAM role behind it - not just Kubernetes RBAC.
# It needs no Kubernetes Role at all (it never calls the Kubernetes API -
# Kaniko/Trivy/Cosign are all pure container-filesystem-and-AWS-API work),
# which is why there's no ci-build-rbac.yaml alongside it.
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace jenkins --name ci-build-sa \
    --attach-policy-arn "$CI_ECR_POLICY_ARN" \
    --attach-policy-arn "$CI_COSIGN_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "ci-build-sa can now push to ECR and sign with Cosign via IRSA - no static credentials involved."

step "[4/10] Installing the EBS CSI driver addon and ebs-gp3 StorageClass..."
# eksctl's default managed cluster only installs coredns/kube-proxy/vpc-cni -
# nothing that can satisfy a PersistentVolumeClaim. Assignment 3's app is
# fully stateless (no PVC anywhere in helm/devops-app), so this was never
# needed until Jenkins showed up needing a persistent home directory
# (jenkins/values.yaml: persistence.storageClass: ebs-gp3). Without this,
# the jenkins PVC sits Pending forever with "storageclass ... not found".
# --attach-policy-arn has eksctl create the IRSA role for the addon's own
# service account (ebs-csi-controller-sa) in one step, same pattern as the
# iamserviceaccount calls above - the OIDC provider it depends on was
# already associated by setup.sh (step 6) before this script ever runs.
if ! aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
    eksctl create addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
        --name aws-ebs-csi-driver \
        --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
        --force
    # `eksctl create addon` returns as soon as the CreateAddon API call is
    # accepted - the ebs-csi-controller Deployment itself gets created
    # asynchronously afterward by EKS's own addon manager, so checking
    # rollout status right away can race a Deployment that doesn't exist yet
    # ("NotFound"). Wait for it to appear before waiting for it to roll out.
    for _ in $(seq 1 30); do
        kubectl get deployment/ebs-csi-controller -n kube-system >/dev/null 2>&1 && break
        sleep 5
    done
    kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=180s
else
    info "aws-ebs-csi-driver addon already installed, reusing it."
fi
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
success "EBS CSI driver ready; ebs-gp3 StorageClass created."

step "[5/10] Installing Jenkins (Helm chart + JCasC from jenkins/values.yaml)..."
helm repo add jenkinsci https://charts.jenkins.io >/dev/null
helm repo update jenkinsci >/dev/null
helm upgrade --install jenkins jenkinsci/jenkins \
    --namespace jenkins \
    --version "$JENKINS_CHART_VERSION" \
    -f jenkins/values.yaml \
    --wait --timeout 10m
success "Jenkins controller deployed and Ready (JCasC applied the Kubernetes cloud, agent templates, and plugin list automatically on boot)."

step "[6/10] Waiting for the controller Pod to fully settle..."
kubectl rollout status statefulset/jenkins -n jenkins --timeout=300s
success "Jenkins controller is up."

step "[7/10] Applying NetworkPolicies..."
# Default-deny plus explicit per-workload allows (jenkins/networkpolicies.yaml
# - see that file's own header for the exact traffic model and its one real
# limitation: plain NetworkPolicy can't scope internet-bound HTTPS by
# destination IP, only by port). Applied after the controller/agents are
# templated so the label selectors below can be checked against real running
# Pods, not just assumed from chart/plugin docs.
kubectl apply -f jenkins/networkpolicies.yaml
success "NetworkPolicies applied to the jenkins namespace."

step "[8/10] Applying the ServiceMonitor (Assignment 5)..."
# Only meaningful once the observability namespace's CRDs exist
# (observability/scripts/install-observability.sh) - kubectl apply on a
# ServiceMonitor before that CRD is installed fails outright ("no matches
# for kind ServiceMonitor"), so this step is skipped (not fatal) if it's
# not there yet, same as this project skips the Slack credential when unset.
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    kubectl apply -f jenkins/servicemonitor.yaml
    success "ServiceMonitor applied - Prometheus can now discover /prometheus."
else
    info "ServiceMonitor CRD not installed yet (observability stack not deployed) - skipping."
    info "Re-run this script, or just 'kubectl apply -f jenkins/servicemonitor.yaml', after installing it."
fi

step "[9/10] Installing Cluster Autoscaler..."
# Added after a real, reproducible capacity-contention problem: two full
# Jenkins CI matrix builds landing at once (a burst of up to 6 ephemeral
# ci-agent Pods) transiently starved the cluster's fixed 3-node baseline
# (confirmed live - matrix cells sat genuinely Pending/Insufficient
# cpu,memory for roughly a minute). This isn't a workaround for that one
# scenario specifically - it's the actual fix: let the node group scale
# itself between the fixed baseline (min) and a real ceiling (max), instead
# of relying on earlier stages finishing in time to free capacity.
CA_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='DevOps-ClusterAutoscaler-Policy'].Arn" --output text --region "$AWS_REGION")
[ -n "$CA_POLICY_ARN" ] \
    || fail "IAM policy 'DevOps-ClusterAutoscaler-Policy' not found - run 'terraform apply' in terraform/ first (it defines Cluster Autoscaler's IAM permissions)."

# eksctl doesn't tag the managed node group's underlying ASG for Cluster
# Autoscaler's own auto-discovery by default - has to be done explicitly,
# same lesson as the RDS security-group rule and IRSA IAM roles elsewhere in
# this project (things eksctl creates that still need a manual follow-up
# step). create-or-update-tags is idempotent on its own; re-running this
# script just re-asserts the same two tags.
NODEGROUP_ASG=$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
    --query "AutoScalingGroups[?Tags[?Key=='eks:cluster-name' && Value=='$CLUSTER_NAME']].AutoScalingGroupName" \
    --output text)
[ -n "$NODEGROUP_ASG" ] \
    || fail "Could not find the managed node group's Auto Scaling Group - is the cluster fully up?"
aws autoscaling create-or-update-tags --region "$AWS_REGION" --tags \
    "ResourceId=$NODEGROUP_ASG,ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=false" \
    "ResourceId=$NODEGROUP_ASG,ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/$CLUSTER_NAME,Value=owned,PropagateAtLaunch=false"
# Min stays 3 - that's the real floor this cluster needs just to run
# kube-system/CoreDNS/cert-manager/Jenkins/the app (see setup.sh's own
# --nodes 3 comment) - Cluster Autoscaler should never scale below what's
# already the documented baseline. Max 6 (double) mirrors the same
# "roughly doubles" cost-scaling reasoning as the t3.medium node-size
# decision - a real ceiling, not unbounded.
aws autoscaling update-auto-scaling-group --region "$AWS_REGION" \
    --auto-scaling-group-name "$NODEGROUP_ASG" --min-size 3 --max-size 6
success "Node group ASG tagged for auto-discovery, sized min=3/max=6."

eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace kube-system --name cluster-autoscaler-sa \
    --attach-policy-arn "$CA_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "cluster-autoscaler-sa can now manage the node group's ASG via IRSA - no static credentials involved."

helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo update autoscaler >/dev/null
# rbac.serviceAccount.create=false: cluster-autoscaler-sa already exists
# (created above, with the IRSA role annotation) - same reasoning as
# Fluent Bit's serviceAccount.create=false in setup.sh. skip-nodes-with-
# local-storage=false: none of this project's Pods use hostPath (only
# emptyDir, which Cluster Autoscaler doesn't count as "local storage" in
# the sense this flag guards against), so there's nothing here that should
# block a scale-down. balance-similar-node-groups/expander=least-waste:
# irrelevant with a single node group today, set for when/if that changes.
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
    --namespace kube-system \
    --version "$CLUSTER_AUTOSCALER_CHART_VERSION" \
    --set autoDiscovery.clusterName="$CLUSTER_NAME" \
    --set awsRegion="$AWS_REGION" \
    --set rbac.serviceAccount.create=false \
    --set rbac.serviceAccount.name=cluster-autoscaler-sa \
    --set extraArgs.skip-nodes-with-local-storage=false \
    --set extraArgs.balance-similar-node-groups=true \
    --set extraArgs.expander=least-waste \
    --wait --timeout 180s
success "Cluster Autoscaler installed - the node group now scales itself between 3 and 6 nodes under real load."

step "[10/10] Next steps"
info "Run jenkins/scripts/configure-jenkins.sh next - it wires up the webhook"
info "relay and prints the admin password + access instructions."
success "install-jenkins.sh complete."
