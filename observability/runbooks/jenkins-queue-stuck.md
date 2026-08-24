# JenkinsQueueStuck

Fires when Jenkins' build queue (`jenkins_queue_size_value`) has been
non-empty for 5 minutes straight - at least one build has sat queued
without an agent Pod ever picking it up.

## Check first

Jenkins Delivery dashboard, "Build queue size" and "Executors: queue length
by agent label" panels - which agent label is actually backed up
(`ci-agent`, `cd-agent`, or the built-in executor)?

```
kubectl get pods -n jenkins -l jenkins=slave
```

Open the stuck build in Jenkins (`http://localhost:8080/queue/` via
port-forward) - it names exactly why it's blocked (e.g. "there are no
nodes with the label ... online").

## Likely causes

- An unschedulable agent template: a Jenkinsfile's `agent { label '...' }`
  requesting a label no Kubernetes cloud pod template
  (`jenkins/values.yaml`) actually provides - this is the exact mechanism
  the `JenkinsQueueStuck` drill itself uses (a throwaway branch with an
  impossible label), so a real occurrence looks identical.
- Cluster capacity: `containerCapStr` reached and no more agent Pods can be
  scheduled - check whether Cluster Autoscaler is adding nodes
  (`kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler`).
- The controller itself under load / unable to launch new agent Pods -
  check controller logs for Kubernetes API errors.

## Resolution

If caused by a bad label: fix the Jenkinsfile's `agent` block (or delete
the offending branch/PR entirely) - the queued build then either resolves
or can be manually cancelled from the queue.

If caused by capacity: wait for Cluster Autoscaler, or manually cancel
non-critical queued builds to free capacity for the rest.
