// Pyflakes static analysis - shared between ci/Jenkinsfile and
// pr-Jenkinsfile, identical either way since the quality gate is supposed
// to check exactly what a real push would. Caller wraps this in
// container('python') - same convention as trivyScan.groovy, this step
// never opens a container itself.
def call() {
    sh '''
        set -e
        pip install --quiet --no-cache-dir pyflakes==3.2.0
        python -m pyflakes backend/app.py worker/worker.py
    '''
}
