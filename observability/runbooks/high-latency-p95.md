# HighLatencyP95

Fires when the backend's 95th-percentile request duration exceeds 1 second,
sustained for 5 minutes.

## Check first

Application Overview dashboard, "Latency (p50 / p95)" panel - is p50 also
elevated (systemic slowdown) or just p95 (a smaller number of genuinely slow
requests, e.g. one heavy S3/SNS call or a slow query)?

```
kubectl top pods -n devops-app -l app=backend
```

## Likely causes

- Backend under CPU/memory pressure - check the resource panel above
  against `helm/devops-app/values.yaml`'s `backend.resources` limits; the
  HPA (`backend.hpa`) should already be scaling out before this gets severe.
- A slow downstream call: RDS under load, or S3/SNS latency (both real AWS
  dependencies `backend/app.py` calls synchronously in the request path).
- Node-level contention: check the Kubernetes Cluster dashboard's node CPU
  panel for the nodes backend Pods are actually scheduled on.

## Resolution

Usually resolves on its own once the underlying pressure clears (HPA scale-out,
RDS load easing). If it doesn't: check `kubectl describe hpa -n devops-app`
to confirm the HPA is actually acting, and `kubectl get events -n devops-app`
for anything blocking a scale-out (e.g. insufficient node capacity - Cluster
Autoscaler should be adding nodes automatically in that case).
