# HighErrorRate

Fires when more than 5% of `backend-service` requests return a 5xx status
over a 5-minute window, sustained for 2 minutes.

## Check first

```
kubectl logs -n devops-app -l app=backend --tail=100
kubectl get pods -n devops-app -l app=backend
```

Application Overview dashboard, "Request rate by status" panel - confirm
which status codes are actually spiking and whether it's one Pod or all of them.

## Likely causes

- A bad release: check `app_info{git_sha=...}` against the last CD deploy -
  if the spike started right after a deploy, this is very likely
  `helm rollback` territory (CD's own Monitoring Gate should have already
  caught this before Verify/Smoke Test passed, in which case it never
  reaches production - see `jenkins/cd/Jenkinsfile`).
- Database connectivity: `/api/health` failing DB checks surfaces as 5xx on
  every DB-touching route, not just one.
- The deliberate drill endpoint (`POST /api/debug/fail`) left running -
  confirm nothing is still hitting it after a failure exercise.

## Resolution

If caused by a bad release: `helm rollback devops-app -n devops-app`
(CD's own `post{failure{}}` block already does this automatically when the
Monitoring Gate stage itself fails).

If caused by a DB outage: fix connectivity first (RDS security group,
`DB_HOST` value in `helm/devops-app/values.yaml`/the release's ConfigMap) -
the alert self-resolves once requests succeed again, nothing to manually clear.
