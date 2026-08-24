# ReplicasMismatch

Fires when a devops-app Deployment's available replica count differs from
its desired (spec) replica count for 5 minutes straight - a real, sustained
gap, not a normal few-second blip during a routine rollout.

## Check first

```
kubectl get deployment -n devops-app
kubectl get pods -n devops-app -o wide
kubectl describe pod <not-ready-pod> -n devops-app
```

Look at the Pod's `Events` and readiness probe status specifically -
`backend`'s readiness probe hits `/api/health`, which fails if it can't
reach the database.

## Likely causes

- A bad `config.dbHost` (or any ConfigMap value the readiness probe depends
  on) pushed by a deploy - Pods come up `Running` but never `Ready`.
- Insufficient cluster capacity - Pods stuck `Pending`. Check
  `kubectl get events -n devops-app` for `FailedScheduling`; Cluster
  Autoscaler should resolve this on its own within a few minutes.
- A crash loop - check `kubectl logs -n devops-app <pod> --previous`.

## Resolution

If caused by a bad config value from a recent deploy: `helm rollback
devops-app -n devops-app`, or fix the value and re-deploy.

If caused by capacity: wait for Cluster Autoscaler, or check
`kubectl get nodes` / the Kubernetes Cluster dashboard for node
availability.

Self-resolves once every Pod is genuinely `Ready` again - nothing to
manually clear on the alert side.
