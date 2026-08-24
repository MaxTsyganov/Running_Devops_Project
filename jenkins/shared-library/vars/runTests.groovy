// Backend pytest suite - shared between ci/Jenkinsfile and pr-Jenkinsfile, same
// reason as lintCode.groovy. Caller still owns its own post{always{ junit ... }};
// a shared step can't add a stage-level post condition.
def call() {
    sh '''
        set -e
        cd backend
        pip install --quiet --no-cache-dir -r requirements-test.txt
        python -m pytest test_app.py -v --junitxml=test-results.xml
    '''
}
