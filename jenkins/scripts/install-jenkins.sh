#!/bin/bash
set -e

# Installs Jenkins from scratch onto the existing EKS cluster (devops-cluster).
# Assumes the cluster and devops-app namespace already exist. Every
# permission, plugin, agent template, and job definition comes from files in
# this repo - nothing here is a manual UI step.
#
# Idempotent: safe to re-run. kubectl apply/eksctl --override-existing-
# serviceaccounts/helm upgrade --install all no-op cleanly on an unchanged install.

CLUSTER_NAME="devops-cluster"
AWS_REGION="us-east-1"
# Pinned against Artifact Hub at the time it was checked, not "latest". The
# Jenkins CORE version is pinned separately in jenkins/values.yaml
# (controller.image.tag) - this chart version only needs to be new enough for
# the JCasC/Kubernetes-cloud schema values.yaml uses.
JENKINS_CHART_VERSION="5.9.54"
# App version 1.35.0 - matches this cluster's EKS/Kubernetes 1.34 control plane
# (Cluster Autoscaler's own compatibility guidance).
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
# controller-rbac.yaml: Role/RoleBinding scoped to the jenkins namespace only -
# what the controller needs to launch/manage agent Pods, nothing about devops-app.
# cd-deploy-rbac.yaml: creates cd-deploy-sa (a plain ServiceAccount, not IRSA -
# it only calls the in-cluster Kubernetes API, never an AWS API) plus the
# namespace-scoped Role/RoleBinding in devops-app and the one unavoidable
# narrow ClusterRole for reading the Namespace object (see that file's header).
kubectl apply -f jenkins/rbac/controller-rbac.yaml
kubectl apply -f jenkins/rbac/cd-deploy-rbac.yaml
success "controller and cd-deploy-sa RBAC applied."

step "[3/10] Creating ci-build-sa (IRSA, for pushing to ECR and signing with Cosign)..."
# Unlike cd-deploy-sa, ci-build-sa needs IRSA: Kaniko pushes to ECR and Cosign
# signs via AWS KMS, both real AWS API calls. It needs no Kubernetes Role at
# all (never calls the Kubernetes API), hence no ci-build-rbac.yaml.
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace jenkins --name ci-build-sa \
    --attach-policy-arn "$CI_ECR_POLICY_ARN" \
    --attach-policy-arn "$CI_COSIGN_POLICY_ARN" \
    --approve --override-existing-serviceaccounts
success "ci-build-sa can now push to ECR and sign with Cosign via IRSA - no static credentials involved."

step "[4/10] Installing the EBS CSI driver addon and ebs-gp3 StorageClass..."
# eksctl's default managed cluster only installs coredns/kube-proxy/vpc-cni -
# nothing that can satisfy a PersistentVolumeClaim. The app itself is fully
# stateless, so this was never needed until Jenkins needed a persistent home
# directory (jenkins/values.yaml: persistence.storageClass: ebs-gp3). Without
# this, the jenkins PVC sits Pending forever.
# --attach-policy-arn has eksctl create the IRSA role for the addon's own
# service account in one step, same pattern as the iamserviceaccount calls above.
if ! aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
    eksctl create addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
        --name aws-ebs-csi-driver \
        --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
        --force
    # `eksctl create addon` returns as soon as the API call is accepted - the
    # Deployment itself is created asynchronously afterward, so checking rollout
    # status immediately can race a Deployment that doesn't exist yet ("NotFound").
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
# Default-deny plus explicit per-workload allows (see jenkins/networkpolicies.yaml's
# header for the traffic model and its port-only-scoping limitation). Applied
# after the controller/agents exist so the label selectors can be checked
# against real running Pods.
kubectl apply -f jenkins/networkpolicies.yaml
success "NetworkPolicies applied to the jenkins namespace."

step "[8/10] Applying the ServiceMonitor (Assignment 5)..."
# Only meaningful once the observability namespace's CRDs exist - kubectl apply
# on a ServiceMonitor before that CRD is installed fails outright ("no matches
# for kind ServiceMonitor"), so this step is skipped (not fatal) if not there yet.
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    kubectl apply -f jenkins/servicemonitor.yaml
    success "ServiceMonitor applied - Prometheus can now discover /prometheus."
else
    info "ServiceMonitor CRD not installed yet (observability stack not deployed) - skipping."
    info "Re-run this script, or just 'kubectl apply -f jenkins/servicemonitor.yaml', after installing it."
fi

step "[9/10] Installing Cluster Autoscaler..."
# Added after a reproducible capacity problem: two CI matrix builds landing at
# once (a burst of up to 6 ephemeral ci-agent Pods) transiently starved the
# fixed 3-node baseline, leaving cells Pending/Insufficient cpu,memory for
# roughly a minute. The fix: let the node group scale itself between a fixed
# baseline (min) and a real ceiling (max).
CA_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='DevOps-ClusterAutoscaler-Policy'].Arn" --output text --region "$AWS_REGION")
[ -n "$CA_POLICY_ARN" ] \
    || fail "IAM policy 'DevOps-ClusterAutoscaler-Policy' not found - run 'terraform apply' in terraform/ first (it defines Cluster Autoscaler's IAM permissions)."

# eksctl doesn't tag the managed node group's underlying ASG for Cluster
# Autoscaler's auto-discovery by default - has to be done explicitly.
# create-or-update-tags is idempotent; re-running this script just re-asserts
# the same two tags.
NODEGROUP_ASG=$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
    --query "AutoScalingGroups[?Tags[?Key=='eks:cluster-name' && Value=='$CLUSTER_NAME']].AutoScalingGroupName" \
    --output text)
[ -n "$NODEGROUP_ASG" ] \
    || fail "Could not find the managed node group's Auto Scaling Group - is the cluster fully up?"
aws autoscaling create-or-update-tags --region "$AWS_REGION" --tags \
    "ResourceId=$NODEGROUP_ASG,ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=false" \
    "ResourceId=$NODEGROUP_ASG,ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/$CLUSTER_NAME,Value=owned,PropagateAtLaunch=false"
# Min stays 3 - the real floor this cluster needs to run kube-system/CoreDNS/
# cert-manager/Jenkins/the app (see setup.sh's --nodes 3 comment). Max 6 is a
# real ceiling, not unbounded.
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
# rbac.serviceAccount.create=false: cluster-autoscaler-sa already exists,
# created above with the IRSA role annotation. skip-nodes-with-local-storage=false:
# none of this project's Pods use hostPath (only emptyDir), so nothing blocks a
# scale-down. balance-similar-node-groups/expander=least-waste: irrelevant with
# a single node group today, set for when/if that changes.
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
