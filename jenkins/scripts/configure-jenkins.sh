#!/bin/bash
set -e

# Post-install configuration: everything that needs a Jenkins controller
# already running, but isn't "create the two jobs" (that's create-jobs.sh).
# Wires up the GitHub webhook relay and prepares the shared-secret credential
# for validating incoming webhook payloads. Idempotent - re-running reuses
# the existing smee.io channel and secret instead of rotating them, since
# rotating either would desync from the GitHub repo's webhook settings.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/output.sh"

kubectl get statefulset/jenkins -n jenkins >/dev/null 2>&1 \
    || fail "Jenkins isn't installed yet - run jenkins/scripts/install-jenkins.sh first."

step "[1/5] Admin credentials..."
# MSYS_NO_PATHCONV=1: on Windows Git Bash, MSYS rewrites any argument that
# looks like a Unix absolute path (like /bin/cat here) into a literal
# Windows path before it reaches kubectl - the exec then fails inside the
# Linux container looking for "C:/Program Files/Git/usr/bin/cat". No-op
# everywhere else (Linux/Mac), so it's safe to set unconditionally.
ADMIN_PASSWORD=$(MSYS_NO_PATHCONV=1 kubectl exec --namespace jenkins svc/jenkins -c jenkins -- \
    /bin/cat /run/secrets/additional/chart-admin-password | tr -d '\r')
info "User:     admin"
info "Password: $ADMIN_PASSWORD"
info "(Also always readable later via: kubectl exec --namespace jenkins svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password)"

step "[2/5] GitHub webhook relay channel..."
# Reuse the existing channel if configure-jenkins.sh already ran once -
# minting a new one every run would silently break whatever's already saved
# in the GitHub repo's webhook settings.
if kubectl get configmap smee-channel -n jenkins >/dev/null 2>&1; then
    SMEE_URL=$(kubectl get configmap smee-channel -n jenkins -o jsonpath='{.data.url}')
    info "Reusing existing channel: $SMEE_URL"
else
    SMEE_URL=$(curl -sI https://smee.io/new | grep -i '^location:' | sed 's/^[Ll]ocation: //' | tr -d '\r\n')
    [ -n "$SMEE_URL" ] || fail "Couldn't mint a new smee.io channel - check network/DNS and retry."
    kubectl create configmap smee-channel -n jenkins --from-literal=url="$SMEE_URL"
    info "Minted new channel: $SMEE_URL"
fi
success "Webhook channel ready."

step "[3/5] Deploying the webhook relay..."
kubectl apply -f jenkins/webhook-relay.yaml
kubectl rollout status deployment/webhook-relay -n jenkins --timeout=120s
success "Relay is up - GitHub POSTs to $SMEE_URL will forward straight to Jenkins' internal /github-webhook/ or /generic-webhook-trigger/ endpoint, by event type."

step "[4/5] Webhook shared-secret credential..."
# Made available to Jenkins via the Kubernetes Credentials Provider plugin
# (any Secret in this namespace labeled jenkins.io/credentials-type shows up
# as a real Jenkins credential automatically - no JCasC edit, no restart).
# This makes the credential exist and usable, but Jenkins' GitHub plugin
# still needs to be told (System config, "Manage hooks" - a one-time global
# setting) to actually validate incoming payloads against it. Until that's
# set, the webhook still works (GitHub allows a webhook with no secret, or
# Jenkins simply won't check it) - it just isn't signature-verified yet.
# Documented as a follow-up in the README's security section rather than
# scripted here, since it needs verifying against the exact GitHub plugin
# version this chart resolves, not guessing at a JCasC schema.
if kubectl get secret git-webhook-secret -n jenkins >/dev/null 2>&1; then
    info "git-webhook-secret already exists, leaving it as-is."
else
    WEBHOOK_SECRET=$(openssl rand -hex 20)
    # Schema per jenkinsci/kubernetes-credentials-provider-plugin's own
    # secretText example - the label is what makes the plugin pick this
    # Secret up as a Jenkins "Secret text" credential named git-webhook-secret.
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: git-webhook-secret
  namespace: jenkins
  labels:
    jenkins.io/credentials-type: secretText
  annotations:
    jenkins.io/credentials-description: Shared secret for validating incoming GitHub webhook payloads
type: Opaque
stringData:
  text: "$WEBHOOK_SECRET"
EOF
    info "Generated a new webhook secret (shown once - save it now):"
    info "$WEBHOOK_SECRET"
fi

step "[5/5] Slack notification credential..."
# Same pattern as git-webhook-secret above, deliberately: a Secret text
# credential the Kubernetes Credentials Provider picks up automatically,
# nothing hand-typed into Jenkins' own UI. Optional - a Slack Incoming
# Webhook URL is an external dependency this script can't provision itself,
# so it's read from an env var the caller sets before running this script
# (`export SLACK_WEBHOOK_URL=https://hooks.slack.com/...`) rather than
# prompted for, and skipped entirely (not a failure) if unset - CI/CD keep
# working with or without it, jenkins/shared-library/vars/notifySlack.groovy
# is only ever called from a build, never a requirement to have one running.
if kubectl get secret slack-webhook-url -n jenkins >/dev/null 2>&1; then
    info "slack-webhook-url already exists, leaving it as-is."
elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: slack-webhook-url
  namespace: jenkins
  labels:
    jenkins.io/credentials-type: secretText
  annotations:
    jenkins.io/credentials-description: Slack Incoming Webhook URL for CI/CD build notifications
type: Opaque
stringData:
  text: "$SLACK_WEBHOOK_URL"
EOF
    success "slack-webhook-url credential created from \$SLACK_WEBHOOK_URL."
else
    info "SLACK_WEBHOOK_URL not set - skipping. CI/CD keep working normally either way:"
    info "notifySlack.groovy catches a missing credential and logs one line, it never fails the"
    info "build over it. Re-run with SLACK_WEBHOOK_URL exported to enable notifications later -"
    info "nothing else needs re-running, the shared library reads the credential fresh each time."
fi

echo ""
echo -e "${BOLD}=================================================================="
echo "  Add this webhook on the GitHub repo (Settings > Webhooks > Add webhook):"
echo "    Payload URL:  $SMEE_URL"
echo "    Content type: application/json"
echo "    Secret:       (the value printed above, first time only)"
echo "    Events:       push and pull_request (ci-application-pr needs the"
echo "                  latter - see jenkins/webhook-relay.yaml for how each"
echo "                  gets routed to the right Jenkins endpoint)"
echo "=================================================================="
echo -e "${RESET}"
success "configure-jenkins.sh complete. Run jenkins/jobs/create-jobs.sh next."
