#!/bin/bash
set -e

# Captures the exact plugin versions a live, already-running controller actually
# resolved and booted with, into jenkins/plugins.lock.txt - not guessed version
# numbers. An earlier attempt pinned each plugin's version independently and
# those turned out mutually incompatible (a snakeyaml/credentials
# ClassNotFoundException killed the controller on boot), since each dependency
# graph was checked in isolation, not as a set. This captures a set that's
# already *proven* compatible - the standard Jenkins "plugins.txt lock file" pattern.
#
# Run this once after a clean install-jenkins.sh boots successfully (or after
# any deliberate plugin-list change in values.yaml), then paste the resulting
# entries into values.yaml's installPlugins list as "shortName:version" - see
# the instructions this script prints at the end.
#
# Requires: kubectl pointed at the cluster, and a port-forward to Jenkins
# already running in another terminal:
#   kubectl port-forward svc/jenkins -n jenkins 8080:8080

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="admin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/output.sh"

command -v python3 >/dev/null 2>&1 \
    || fail "'python3' is not installed or not on your PATH."

step "Reading the admin password..."
JENKINS_PASSWORD=$(MSYS_NO_PATHCONV=1 kubectl exec --namespace jenkins svc/jenkins -c jenkins -- \
    /bin/cat /run/secrets/additional/chart-admin-password | tr -d '\r')

step "Querying the live controller's actual installed plugin set..."
LOCK_FILE="jenkins/plugins.lock.txt"
curl -sf -g -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
    "${JENKINS_URL}/pluginManager/api/json?depth=1&tree=plugins[shortName,version]" \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
plugins = sorted(data["plugins"], key=lambda p: p["shortName"])
for p in plugins:
    print(p["shortName"] + ":" + p["version"])
' > "$LOCK_FILE"

PLUGIN_COUNT=$(wc -l < "$LOCK_FILE")
success "Captured ${PLUGIN_COUNT} plugin:version pairs (installPlugins entries plus every transitive dependency actually resolved) into ${LOCK_FILE}."

echo ""
echo "Next step (manual - this script deliberately doesn't rewrite values.yaml for you):"
echo "  Replace jenkins/values.yaml's installPlugins list (bare names) with the"
echo "  shortName:version pairs from ${LOCK_FILE} - Jenkins' Helm chart accepts"
echo "  \"name:version\" entries in that same list. Re-run install-jenkins.sh"
echo "  against a *fresh* controller afterward to confirm the locked set still"
echo "  boots cleanly before trusting it - a set that resolved cleanly once on"
echo "  this controller isn't proof it'll resolve the same way installed fresh,"
echo "  only that it's a real, mutually-compatible set that has actually run."
