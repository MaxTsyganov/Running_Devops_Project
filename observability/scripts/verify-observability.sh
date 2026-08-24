#!/bin/bash
# Verifies the observability stack is healthy. Read-only - never mutates
# cluster state. Deliberately doesn't `set -e`: it's meant to run every
# check and report a full pass/fail summary, not stop at the first failure.
# Same structure as jenkins/scripts/verify-jenkins.sh.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/output.sh"
ISSUES_FOUND=0

step "Namespace"
kubectl get namespace observability >/dev/null 2>&1 && ok "'observability' namespace exists" || bad "'observability' namespace missing"

step "Pods"
kubectl get pods -n observability -o wide
UNHEALTHY=$(kubectl get pods -n observability --no-headers 2>/dev/null | grep -vc "Running\|Completed")
[ "$UNHEALTHY" -eq 0 ] && ok "All Pods Running" || bad "$UNHEALTHY Pod(s) not Running"

step "Prometheus PVC"
kubectl get pvc -n observability
PVC_PHASE=$(kubectl get pvc -n observability -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
[ "$PVC_PHASE" = "Bound" ] && ok "Prometheus PVC is Bound" || bad "Prometheus PVC is not Bound"

step "Helm release"
helm list -n observability

step "Alert/recording rule groups (Assignment 5's own 6 alerts + SLO rules)"
PF_PID=""
if ! curl -sf -o /dev/null http://localhost:9090/-/healthy 2>/dev/null; then
    kubectl port-forward svc/observability-prometheus -n observability 9090:9090 >/tmp/verify-observability-pf.log 2>&1 &
    PF_PID=$!
    sleep 3
fi
for group in application.rules kubernetes.rules jenkins.rules monitoring.rules slo.rules; do
    FOUND=$(curl -s "http://localhost:9090/api/v1/rules" 2>/dev/null \
        | grep -o "\"name\":\"${group}\"")
    [ -n "$FOUND" ] && ok "Rule group '$group' loaded" || bad "Rule group '$group' not found"
done

step "Scrape targets"
TARGETS_JSON=$(curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null)
DOWN_COUNT=$(echo "$TARGETS_JSON" | grep -o '"health":"down"' | wc -l)
UP_COUNT=$(echo "$TARGETS_JSON" | grep -o '"health":"up"' | wc -l)
info "$UP_COUNT target(s) up, $DOWN_COUNT down"
[ "$DOWN_COUNT" -eq 0 ] && ok "No down scrape targets" || bad "$DOWN_COUNT scrape target(s) reporting down"
[ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1

step "Dashboards loaded"
kubectl get configmap -n observability -l grafana_dashboard=1 -o custom-columns='NAME:.metadata.name' --no-headers

echo ""
if [ "$ISSUES_FOUND" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}All checks passed.${RESET}"
else
    echo -e "${BOLD}${RED}One or more checks failed - see ✘ lines above.${RESET}"
    exit 1
fi
