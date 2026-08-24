# PrometheusTargetDown

Fires when Prometheus has been unable to scrape a target (`up == 0`) for
5 minutes. This is the monitoring stack's own self-check - it catches a
target going dark regardless of which specific alert would otherwise have
depended on that target's metrics.

## Check first

```
kubectl port-forward svc/observability-prometheus -n observability 9090:9090
```

Open `http://localhost:9090/targets` and find the specific `job`/`instance`
reporting down - the `lastError` field there almost always names the exact
failure (connection refused, timeout, 404, TLS error).

## Likely causes

- The target Pod crashed or was never healthy - `kubectl get pods` in its
  namespace.
- A NetworkPolicy change blocked the scrape path - check
  `helm/devops-app/templates/networkpolicies.yaml` /
  `jenkins/networkpolicies.yaml` / `observability/networkpolicies.yaml` for
  anything recently changed that touches this target's namespace or port.
- The Service/ServiceMonitor port name or path no longer matches the
  container's actual listening port (e.g. an app code change moved
  `/metrics` or changed its port without updating the ServiceMonitor).

## Resolution

Fix the underlying cause (restart the Pod, revert/correct the NetworkPolicy
change, fix the ServiceMonitor). Self-resolves once Prometheus successfully
scrapes the target again - nothing to manually clear on the alert side.
