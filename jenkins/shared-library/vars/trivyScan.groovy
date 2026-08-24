// Trivy's scan-then-gate logic, shared between ci/Jenkinsfile's matrix (scanning a
// pushed image) and pr-Jenkinsfile's quality gate (scanning a local Kaniko tarball,
// since PR builds never push). Two-pass: a full HIGH+CRITICAL report first
// (non-blocking, archived), then the real gate on fixable CRITICAL findings.
//
// target:    image ref ("registry/repo:tag") or a local tarball path
// isTarball: true when target is a local file (PR builds), false when it's
//            a real pushed image reference (CI builds)
// label:     short name for the archived report filename, e.g. the service
def call(String target, boolean isTarball, String label) {
    def source = isTarball ? "--input ${target}" : target
    sh """
        set -e
        echo "=== Scanning ${label} (${target}) ==="
        trivy image ${source} --severity HIGH,CRITICAL --exit-code 0 \\
            --format json --output "trivy-${label}.json" \\
            --ignorefile .trivyignore
        trivy image ${source} --severity HIGH,CRITICAL --exit-code 0 \\
            --format table --ignorefile .trivyignore
    """
    archiveArtifacts artifacts: "trivy-${label}.json", fingerprint: true
    sh """
        set -e
        # The actual gate: fails the build on fixable CRITICAL findings.
        # --ignore-unfixed excludes CVEs with no patch; accepted-risk exceptions
        # go in .trivyignore with a documented reason.
        trivy image ${source} --severity CRITICAL --exit-code 1 --ignore-unfixed \\
            --ignorefile .trivyignore
    """
}
