#!/bin/bash
# Verifies the Jenkins install is healthy and matches what the assignment's
# evidence checklist asks for. Read-only - never mutates cluster state.
# Deliberately doesn't `set -e`: it's meant to run every check and report a
# full pass/fail summary, not stop at the first failure.

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
step() { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
ok()   { echo -e "${GREEN}✔ $1${RESET}"; }
bad()  { echo -e "${RED}✘ $1${RESET}"; FAILED=1; }
FAILED=0

step "Namespaces"
kubectl get namespaces
kubectl get namespace jenkins >/dev/null 2>&1 && ok "'jenkins' namespace exists" || bad "'jenkins' namespace missing"
kubectl get namespace devops-app >/dev/null 2>&1 && ok "'devops-app' namespace exists" || bad "'devops-app' namespace missing"

step "Jenkins controller"
kubectl get pods -n jenkins -o wide
CONTROLLER_READY=$(kubectl get pod -n jenkins -l app.kubernetes.io/component=jenkins-controller \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null)
[ "$CONTROLLER_READY" = "true" ] && ok "Jenkins controller container is Ready" || bad "Jenkins controller is not Ready"

step "Jenkins namespace resources"
kubectl get service,pvc -n jenkins
kubectl get serviceaccount,role,rolebinding -n jenkins
helm list -n jenkins
kubectl get pvc -n jenkins -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Bound \
    && ok "Jenkins home PVC is Bound" || bad "Jenkins home PVC is not Bound"

step "Agent pod templates (JCasC-defined, not manual UI)"
kubectl get configmap -n jenkins -o name | grep -q jenkins \
    && ok "JCasC ConfigMap present (agent templates/plugins came from code, not the UI)" \
    || bad "No JCasC ConfigMap found"
CURRENT_AGENTS=$(kubectl get pods -n jenkins --no-headers 2>/dev/null | grep -vc '^jenkins-')
if [ "$CURRENT_AGENTS" -eq 0 ]; then
    ok "No agent Pods currently running - expected between builds (ephemeral, spawned per-build and deleted after, per idleMinutes: 5 in values.yaml). Watch 'kubectl get pods -n jenkins -w' during an actual CI/CD run to see one appear and disappear."
else
    echo "    Note: $CURRENT_AGENTS non-controller pod(s) currently in the jenkins namespace - likely a build in progress or the webhook relay."
fi

step "Webhook relay"
kubectl get deployment webhook-relay -n jenkins >/dev/null 2>&1 && ok "webhook-relay Deployment exists" || bad "webhook-relay Deployment missing - run configure-jenkins.sh"
RELAY_READY=$(kubectl get deployment webhook-relay -n jenkins -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "$RELAY_READY" = "1" ] && ok "webhook-relay is Ready" || bad "webhook-relay is not Ready"

step "Jobs created from code"
PF_PID=""
if ! curl -sf -o /dev/null http://localhost:8080/login 2>/dev/null; then
    kubectl port-forward svc/jenkins -n jenkins 8080:8080 >/tmp/verify-jenkins-pf.log 2>&1 &
    PF_PID=$!
    sleep 3
fi
# MSYS_NO_PATHCONV=1: no-op outside Windows Git Bash - see configure-jenkins.sh
# for why it's needed there (MSYS mangles the /bin/cat path argument).
JENKINS_PASSWORD=$(MSYS_NO_PATHCONV=1 kubectl exec --namespace jenkins svc/jenkins -c jenkins -- \
    /bin/cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r')
for job in ci-application cd-application; do
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${JENKINS_PASSWORD}" \
        "http://localhost:8080/job/${job}/api/json" 2>/dev/null)
    [ "$STATUS" = "200" ] && ok "Job '$job' exists" || bad "Job '$job' not found (HTTP $STATUS) - run jenkins/jobs/create-jobs.sh"
done
[ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1

step "Application (devops-app) - current deployed state"
kubectl get deployments,pods,services -n devops-app
kubectl get pods -n devops-app -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
kubectl get events -n devops-app --sort-by=.metadata.creationTimestamp | tail -10

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}All checks passed.${RESET}"
else
    echo -e "${BOLD}${RED}One or more checks failed - see ✘ lines above.${RESET}"
    exit 1
fi
