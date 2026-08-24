// Posts a short build-result message to Slack via an Incoming Webhook URL, read
// from the 'slack-webhook-url' Jenkins Credential (jenkins/scripts/configure-jenkins.sh
// creates it via the Kubernetes Credentials Provider - never inlined, never logged).
// Shared between ci/Jenkinsfile and cd/Jenkinsfile's post{} blocks; pr-Jenkinsfile
// doesn't call this since the PR's own build page already shows the gate result.
//
// Picks wget or a urllib fallback depending on which agent container this runs in
// (ci-agent's python container has neither curl nor wget). The JSON payload goes to
// a file and the webhook URL is read from the environment, avoiding shell/Python/
// Groovy quoting collisions entirely.

String esc(String s) {
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')
}

def call(String status, String context) {
    // Notifications are optional (configure-jenkins.sh skips creating the credential
    // if SLACK_WEBHOOK_URL was never set), so a missing credential must never fail an
    // otherwise-successful build. withCredentials throws CredentialsNotFoundException
    // in that case; caught here to avoid that.
    try {
        def color = (status == 'SUCCESS') ? 'good' : 'danger'
        def title = "${env.JOB_NAME} #${env.BUILD_NUMBER} - ${status}"
        def payload = """{"attachments":[{"color":"${color}","title":"${esc(title)}","text":"${esc(context)}","title_link":"${env.BUILD_URL}"}]}"""
        writeFile file: 'slack-payload.json', text: payload
        withCredentials([string(credentialsId: 'slack-webhook-url', variable: 'SLACK_URL')]) {
            sh '''
                set -e
                if command -v wget >/dev/null 2>&1; then
                    wget -q -O- --header="Content-Type: application/json" \
                        --post-file=slack-payload.json "$SLACK_URL" >/dev/null
                else
                    python3 -c "
import os, urllib.request
data = open('slack-payload.json', 'rb').read()
req = urllib.request.Request(os.environ['SLACK_URL'], data=data, headers={'Content-Type': 'application/json'})
urllib.request.urlopen(req)
"
                fi
                rm -f slack-payload.json
            '''
        }
    } catch (Exception e) {
        echo "notifySlack: skipped - ${e.getMessage()} (slack-webhook-url credential probably not configured; see jenkins/scripts/configure-jenkins.sh step 5/5)"
    }
}
