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
# Never printed to this console - the assignment's Secrets requirement is
# explicit ("do not print secrets to the console log; verify masking
# works"), and a password sitting in a saved terminal transcript is exactly
# what that rule is guarding against. Retrieve it yourself when you need it:
info "Not printed here - retrieve it yourself when needed:"
info "  MSYS_NO_PATHCONV=1 kubectl exec --namespace jenkins svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password"
info "(MSYS_NO_PATHCONV=1 only matters on Windows Git Bash - see the comment on this same pattern elsewhere in this script)"

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

step "[3/5] Webhook shared-secret + PR-endpoint token..."
# Two values, one Secret: "text" is the HMAC shared secret GitHub signs
# every delivery with, and "pr-token" is the routing token
# ci-application-pr-config.xml's generic-webhook-trigger endpoint expects.
# Created *before* the relay is deployed below (not after) - webhook-relay.yaml's
# Deployment references this Secret via secretKeyRef, and a Pod referencing a
# Secret that doesn't exist yet fails to start at all (CreateContainerConfigError),
# not just with empty env vars, which would make the rollout-status wait right
# after applying it time out. "text" is also labeled for the Kubernetes
# Credentials Provider plugin, so it still shows up as a normal Jenkins
# credential too, in case a future pipeline stage wants it.
SECRET_EXISTS=false
kubectl get secret git-webhook-secret -n jenkins >/dev/null 2>&1 && SECRET_EXISTS=true
# Checked as its own condition, not folded into the one above: a Secret
# created by an older version of this script (before pr-token existed)
# would exist but be missing this specific key - secretKeyRef on a missing
# *key* fails the Pod the same way a missing Secret does, so "the Secret
# exists" alone isn't enough to skip past this block.
HAS_PR_TOKEN=false
$SECRET_EXISTS && kubectl get secret git-webhook-secret -n jenkins -o jsonpath='{.data.pr-token}' 2>/dev/null | grep -q . && HAS_PR_TOKEN=true

if $SECRET_EXISTS && $HAS_PR_TOKEN; then
    info "git-webhook-secret already exists with both keys, leaving it as-is."
elif $SECRET_EXISTS; then
    # text stays untouched (rotating it would desync from whatever's already
    # saved in the GitHub repo's webhook settings) - only the missing key
    # gets patched in.
    PR_TOKEN=$(openssl rand -hex 20)
    kubectl patch secret git-webhook-secret -n jenkins --type=merge \
        -p "{\"stringData\":{\"pr-token\":\"$PR_TOKEN\"}}"
    info "git-webhook-secret existed without a pr-token key (predates that key being added) -"
    info "patched it in without touching the existing webhook secret."
else
    WEBHOOK_SECRET=$(openssl rand -hex 20)
    PR_TOKEN=$(openssl rand -hex 20)
    # Schema per jenkinsci/kubernetes-credentials-provider-plugin's own
    # secretText example - the label is what makes the plugin pick this
    # Secret up as a Jenkins "Secret text" credential named git-webhook-secret
    # (keyed off the "text" data key specifically; "pr-token" alongside it is
    # just a second plain data key, not itself exposed as a credential).
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
  pr-token: "$PR_TOKEN"
EOF
    # Not printed to console (see the [1/5] admin-password comment above for
    # why) - written straight to a local file instead, which the operator
    # copies into GitHub's webhook config and then deletes. Truncated with
    # : > rather than rm, so a re-run of this script can't fail on a
    # missing file, and never left lying around after this run either way.
    WEBHOOK_SECRET_FILE="$(mktemp -t git-webhook-secret.XXXXXX)"
    printf '%s' "$WEBHOOK_SECRET" > "$WEBHOOK_SECRET_FILE"
    info "Generated a new webhook secret - written to $WEBHOOK_SECRET_FILE (not printed here)."
    info "Copy it into GitHub's webhook config below, then delete that file."
    info "Also generated the ci-application-pr routing token - jenkins/jobs/create-jobs.sh"
    info "reads it from this same Secret and injects it when it creates that job; nothing"
    info "further to do here."
fi

step "[4/5] Deploying the webhook relay..."
# Applied after the Secret above (see that step's comment for why the order
# matters) - webhook-relay.yaml's Deployment reads WEBHOOK_HMAC_SECRET and
# PR_WEBHOOK_TOKEN from it via secretKeyRef, so the Secret has to exist first.
kubectl apply -f jenkins/webhook-relay.yaml
kubectl rollout status deployment/webhook-relay -n jenkins --timeout=120s
success "Relay is up - GitHub POSTs to $SMEE_URL will forward straight to Jenkins' internal /github-webhook/ or /generic-webhook-trigger/ endpoint, by event type, HMAC-verified against the Secret above before either forward happens."

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
echo "    Secret:       (from the temp file noted above, first time only - delete it after)"
echo "    Events:       push and pull_request (ci-application-pr needs the"
echo "                  latter - see jenkins/webhook-relay.yaml for how each"
echo "                  gets routed to the right Jenkins endpoint)"
echo "=================================================================="
echo -e "${RESET}"
success "configure-jenkins.sh complete. Run jenkins/jobs/create-jobs.sh next."
