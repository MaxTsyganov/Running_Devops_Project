#!/bin/bash
set -e

# Installs the observability stack (Prometheus/Grafana/Alertmanager via
# kube-prometheus-stack) onto the existing EKS cluster, additively - doesn't
# touch jenkins or devops-app. Everything comes from files in this repo
# (observability/values.yaml, rules/, dashboards/, networkpolicies.yaml),
# no manual UI steps.
#
# Idempotent: safe to re-run, same pattern as
# jenkins/scripts/install-jenkins.sh.
#
# Run helm/devops-app's next upgrade (or install-jenkins.sh, for its new
# ServiceMonitor) only AFTER this script - both reference the
# ServiceMonitor/PodMonitor/PrometheusRule CRDs this chart installs and
# fail outright if those CRDs don't exist yet.

CLUSTER_NAME="devops-cluster"
AWS_REGION="us-east-1"
# Pinned to a checked version, not "latest" - same reasoning as
# JENKINS_CHART_VERSION in install-jenkins.sh.
KPS_CHART_VERSION="88.5.4"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/output.sh"

step "[0/8] Pre-flight checks..."
for tool in kubectl helm openssl; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "'$tool' is not installed or not on your PATH. Install it and re-run this script."
done
kubectl cluster-info >/dev/null 2>&1 \
    || fail "kubectl isn't pointed at a live cluster. Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION"
success "Cluster reachable."

step "[1/8] Creating the observability namespace..."
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
success "Namespace 'observability' ready."

step "[2/8] Grafana admin credentials..."
if kubectl get secret grafana-admin-credentials -n observability >/dev/null 2>&1; then
    info "grafana-admin-credentials already exists, leaving it as-is."
else
    GRAFANA_PASSWORD=$(openssl rand -hex 20)
    kubectl create secret generic grafana-admin-credentials -n observability \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$GRAFANA_PASSWORD"
    # Not printed to console - same reasoning as Jenkins' own admin password
    # (jenkins/scripts/configure-jenkins.sh's [1/5] step).
    info "Generated a new admin password - not printed here. Retrieve it with:"
    info "  kubectl get secret grafana-admin-credentials -n observability -o jsonpath='{.data.admin-password}' | base64 -d"
fi
success "Grafana admin credentials ready."

step "[3/8] Alertmanager Slack webhook..."
# Unlike Jenkins' slack-webhook-url Secret (skipped entirely when unset),
# alertmanager.alertmanagerSpec.secrets always names this Secret, and
# Alertmanager's Pod fails to start if a Secret it mounts doesn't exist. So
# this always gets created, real value or a placeholder; a placeholder just
# means Slack delivery quietly fails until a real webhook URL is supplied.
if kubectl get secret slack-webhook-url -n observability >/dev/null 2>&1; then
    info "slack-webhook-url already exists, leaving it as-is."
elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    kubectl create secret generic slack-webhook-url -n observability \
        --from-literal=webhook-url="$SLACK_WEBHOOK_URL"
    info "Slack webhook configured from \$SLACK_WEBHOOK_URL."
else
    kubectl create secret generic slack-webhook-url -n observability \
        --from-literal=webhook-url="https://hooks.slack.com/services/PLACEHOLDER"
    info "\$SLACK_WEBHOOK_URL not set - created a placeholder. Alerts will fire in"
    info "Alertmanager but Slack delivery will silently fail until this is replaced:"
    info "  kubectl delete secret slack-webhook-url -n observability"
    info "  SLACK_WEBHOOK_URL=https://hooks.slack.com/... bash $0"
fi
success "Alertmanager Slack credential ready."

step "[4/8] Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install observability prometheus-community/kube-prometheus-stack \
    --namespace observability \
    --version "$KPS_CHART_VERSION" \
    -f observability/values.yaml \
    --wait --timeout 10m
success "Stack deployed and Ready."

step "[5/8] Applying alert + recording rules..."
kubectl apply -f observability/rules/
success "PrometheusRules applied."

step "[6/8] Loading dashboards..."
# Each dashboard is plain JSON in observability/dashboards/, wrapped into a
# ConfigMap at install time with the grafana_dashboard: "1" label the
# chart's sidecar watches for - never a manual Grafana UI import.
for f in observability/dashboards/*.json; do
    name="dashboard-$(basename "$f" .json)"
    kubectl create configmap "$name" -n observability \
        --from-file="$(basename "$f")=$f" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - grafana_dashboard=1 -o yaml \
        | kubectl apply -f -
done
success "Dashboards loaded."

step "[7/8] Applying NetworkPolicies..."
kubectl apply -f observability/networkpolicies.yaml
success "NetworkPolicies applied to the observability namespace."

step "[8/8] Access instructions"
info "Prometheus:   kubectl port-forward svc/observability-prometheus -n observability 9090:9090"
info "Grafana:      kubectl port-forward svc/observability-grafana -n observability 3000:80"
info "Alertmanager: kubectl port-forward svc/observability-alertmanager -n observability 9093:9093"
info "Grafana admin password: see step [2/8] above."
success "install-observability.sh complete."
