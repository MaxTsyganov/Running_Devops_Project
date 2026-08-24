// Pyflakes static analysis - shared between ci/Jenkinsfile and pr-Jenkinsfile so
// the quality gate checks exactly what a real push would. Caller wraps this in
// container('python'); this step never opens a container itself.
def call() {
    sh '''
        set -e
        pip install --quiet --no-cache-dir pyflakes==3.2.0
        python -m pyflakes backend/app.py worker/worker.py
    '''
}
