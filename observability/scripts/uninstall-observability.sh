#!/bin/bash
set -e

# Removes the observability stack and everything install-observability.sh
# created, without touching jenkins or devops-app. Counterpart to that
# script. Idempotent - safe to re-run; every step no-ops cleanly if its
# target is already gone. Same structure as jenkins/scripts/uninstall-jenkins.sh.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/output.sh"

step "[1/3] Uninstalling the observability Helm release..."
if helm status observability -n observability >/dev/null 2>&1; then
    helm uninstall observability -n observability --wait --timeout=120s
    success "Observability stack removed."
else
    info "Observability release not found, nothing to uninstall."
fi

step "[2/3] Deleting the Prometheus PVC..."
# helm uninstall deliberately never deletes a PVC (protects data by default)
# - same reasoning as teardown.sh's own Jenkins/observability PVC steps.
# Left alone, the EBS volume outlives the release and keeps costing money.
kubectl delete pvc --all -n observability --timeout=120s 2>/dev/null \
    && success "Observability PVC deleted." \
    || info "No observability PVC found."

step "[3/3] Removing NetworkPolicies and the namespace..."
kubectl delete -f observability/networkpolicies.yaml --ignore-not-found=true
kubectl delete namespace observability --ignore-not-found=true --timeout=90s
success "uninstall-observability.sh complete - jenkins and devops-app are untouched."

echo ""
echo "Note: also remove jenkins/servicemonitor.yaml's target and"
echo "jenkins/networkpolicies.yaml's observability-namespace ingress rule"
echo "yourself if Jenkins metrics scraping is truly unwanted going forward -"
echo "left in place here since they're harmless with Prometheus gone (no"
echo "traffic ever arrives on rules with nothing left to match their source)."
