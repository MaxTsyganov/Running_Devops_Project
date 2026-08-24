# NodeNotReady

Fires when an EKS node reports condition `Ready` as `false` (or unknown),
**or** reports `MemoryPressure`/`DiskPressure`/`PIDPressure` as `true`, for
5 minutes. `{{ $labels.condition }}` in the alert tells you which one.

## Check first

```
kubectl get nodes -o wide
kubectl describe node <node-name>
```

Check the node's `Conditions` section (`MemoryPressure`, `DiskPressure`,
`PIDPressure`, `NetworkUnavailable`) and recent `Events` for the actual
cause, plus what's still scheduled on it (`kubectl get pods -A --field-selector
spec.nodeName=<node-name>`).

## Likely causes

- Underlying EC2 instance issue (AWS-side hardware/host problem, rare but
  real) - check the EC2 console / `aws ec2 describe-instance-status`.
- Resource exhaustion on the node itself (disk/memory pressure from a
  runaway Pod).
- kubelet/container runtime crash on the node.

## Resolution

Kubernetes/Cluster Autoscaler generally self-heal this: a genuinely dead
node's Pods get rescheduled elsewhere once the node is marked `NotReady`
long enough, and Cluster Autoscaler eventually replaces the node itself
(scale down the bad one, scale up a fresh one) if it never recovers.

If it doesn't clear on its own: `kubectl delete node <node-name>` to force
the ASG (via Cluster Autoscaler / EC2 health checks) to replace it, or
manually terminate the underlying EC2 instance from the AWS console and let
the managed node group replace it.
