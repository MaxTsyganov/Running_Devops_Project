#!/bin/bash
set -e

# Creates or updates ci-application and cd-application via Jenkins' REST API -
# idempotent (safe to re-run after editing the config.xml files or the
# Jenkinsfiles they point at). Deliberately NOT run during Jenkins' own boot
# sequence (see jenkins/values.yaml) - this only ever touches an already
# running, already healthy controller, so a mistake here can't take down
# Jenkins itself, only fail this one script.
#
# Requires: kubectl pointed at the cluster, and a port-forward to Jenkins
# already running in another terminal:
#   kubectl port-forward svc/jenkins -n jenkins 8080:8080

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="admin"
JENKINS_PASSWORD=$(kubectl exec --namespace jenkins svc/jenkins -c jenkins -- \
    /bin/cat /run/secrets/additional/chart-admin-password | tr -d '\r')

# Jenkins' CSRF crumb is tied to the session it was issued in - fetching it
# and using it in two separate curl invocations (each its own fresh Basic
# Auth session, no cookie continuity) makes it invalid by the second
# request, failing with "403 No valid crumb was included in the request".
# A shared cookie jar keeps both calls in the same session.
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

CRUMB=$(curl -sf -c "$JAR" -b "$JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
    "${JENKINS_URL}/crumbIssuer/api/json" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")

create_or_update_job() {
    local job_name="$1"
    local config_file="$2"
    local status
    status=$(curl -s -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code}' \
        -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
        "${JENKINS_URL}/job/${job_name}/api/json")

    if [ "$status" = "200" ]; then
        echo "Updating existing job: ${job_name}"
        curl -sf -c "$JAR" -b "$JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" -H "${CRUMB}" \
            -H "Content-Type: application/xml" \
            --data-binary "@${config_file}" \
            "${JENKINS_URL}/job/${job_name}/config.xml"
    else
        echo "Creating job: ${job_name}"
        curl -sf -c "$JAR" -b "$JAR" -u "${JENKINS_USER}:${JENKINS_PASSWORD}" -H "${CRUMB}" \
            -H "Content-Type: application/xml" \
            --data-binary "@${config_file}" \
            "${JENKINS_URL}/createItem?name=${job_name}"
    fi
    echo ""
}

create_or_update_job "ci-application" "jenkins/jobs/ci-application-config.xml"
create_or_update_job "cd-application" "jenkins/jobs/cd-application-config.xml"

echo "Done. Verify:"
echo "  curl -s -u ${JENKINS_USER}:\$JENKINS_PASSWORD ${JENKINS_URL}/job/ci-application/api/json | head -c 300"
echo "  curl -s -u ${JENKINS_USER}:\$JENKINS_PASSWORD ${JENKINS_URL}/job/cd-application/api/json | head -c 300"
