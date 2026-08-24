# PVC / Pod recovery (Prometheus)

Prometheus is the only stateful component in this stack (`observability/values.yaml`:
`prometheus.prometheusSpec.storageSpec`, an `ebs-gp3` PVC). Alertmanager and
Grafana are both fully reproducible from Git (Alertmanager has no
persistent storage configured at all; Grafana's dashboards/datasources are
sidecar-provisioned from ConfigMaps, not stored locally) - a deleted Pod or
even a full reinstall of either recreates them identically, nothing to
"recover." This runbook only concerns the two ways Prometheus's own data
can be lost, and the real difference between them.

## Scenario 1: Pod deleted

```
kubectl delete pod -n observability -l app.kubernetes.io/name=prometheus
```

The StatefulSet recreates the Pod immediately and it re-attaches the
**same** PVC - Pod deletion is not PVC deletion. All scraped history within
the 7-day retention window (`observability/values.yaml`) survives untouched.
Confirm with:

```
kubectl get pods -n observability -l app.kubernetes.io/name=prometheus -w
```

## Scenario 2: PVC deleted

```
kubectl delete pvc -n observability -l app.kubernetes.io/name=prometheus
```

This is real, unrecoverable data loss - every metric sample Prometheus had
stored is gone with the volume. There is no backup of Prometheus's own TSDB
in this project (out of scope - the assignment's persistence requirement is
about the stack *config* surviving a restart via ebs-gp3, not about
long-term metrics archival).

Recovery is a clean reinstall against a fresh, empty PVC - the same
JCasC-first-recovery precedent already proven for Jenkins
(`evidence/06-bonus-features/15-jcasc-recovery-drill-proof.txt`): every
alert rule, dashboard, and NetworkPolicy is defined in Git
(`observability/rules/`, `observability/dashboards/`,
`observability/networkpolicies.yaml`), so nothing about the stack's
*configuration* is actually lost - only its collected history.

```
bash observability/scripts/install-observability.sh
```

`helm upgrade --install` inside that script recreates the StatefulSet,
which provisions a brand-new PVC and starts Prometheus from an empty TSDB.
Targets, alerts, and dashboards are all back and correct within one scrape
interval (30s) - only the historical data itself doesn't come back.
