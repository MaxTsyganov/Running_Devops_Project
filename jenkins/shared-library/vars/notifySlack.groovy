// Posts a short build-result message to Slack via an Incoming Webhook URL,
// read from the 'slack-webhook-url' Jenkins Credential
// (jenkins/scripts/configure-jenkins.sh creates it the same way as the
// existing GitHub webhook secret via the Kubernetes Credentials Provider -
// never inlined here, never printed to a log). Shared between ci/Jenkinsfile
// and cd/Jenkinsfile's post{} blocks - pr-Jenkinsfile doesn't call this, a
// quality-gate result showing on the PR's own build page is enough.
//
// Two POST implementations, picked automatically by which agent container
// this runs in: ci-agent's python container has neither curl nor wget
// (checked directly earlier in this project, not assumed); cd-agent's
// deploy container is Alpine-based and already uses wget for the CD smoke
// test. The JSON payload is written to a file rather than embedded inline
// in any command, and the webhook URL is read from the process environment
// rather than string-substituted - avoids shell/Python/Groovy quoting
// collisions entirely instead of trying to escape around them.

String esc(String s) {
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')
}

def call(String status, String context) {
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
}
