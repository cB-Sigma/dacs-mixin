# DacsCacheServerDown

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-availability` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

Prometheus has failed to scrape the metrics endpoint of a cache server pod
(`up == 0`) for 5 minutes. The pod still exists as a scrape target, so it has
an IP address; either the process is not running, or port `metrics` (9096 by
default) is unreachable.

The metrics exposer is started just before the server begins accepting cache
traffic, so a pod that fails this check is very likely not serving the cache
port either.

## Impact

Clients pick a server by hashing the cache key over the full server list.
Keys that map to this pod cannot be served from the cache: reads fall back to
Azure Blob Storage and fills for those keys fail. Other servers are unaffected.
Workloads keep running, slower and with more Blob egress.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

```sh
kubectl get pod -n $NS $POD -o wide
kubectl describe pod -n $NS $POD            # restarts, OOMKilled, probe failures, events
kubectl logs -n $NS $POD -c cacheserver --tail=200
kubectl logs -n $NS $POD -c cacheserver --previous --tail=200
```

Things to look for:

- **CrashLoopBackOff at start-up.** The container runs
  `check_space_overuse.sh` and then `CacheServer`; a full or missing cache
  directory shows up here.
- **Liveness restarts.** The liveness probe runs `/root/LivenessProbe` every
  120 s and restarts the container after 10 failures.
- **OOMKilled.** Compare the container limit with `spec.memoryLimitMB` on the
  Cache.
- **Process fine, scrape failing.** Check from inside the pod, then check
  NetworkPolicies between Prometheus and the cache namespace:

  ```sh
  kubectl exec -n $NS $POD -c cacheserver -- curl -s http://localhost:9096/metrics | head
  ```

- **Node trouble.** `kubectl describe node <node>` for NotReady, disk pressure
  or an NVMe/RAID problem.

## Mitigation

- Fix the cause shown in the pod events or logs.
- If the node is unhealthy, cordon and drain it. In host-storage mode the
  cache-controller reschedules the pod; data on the old node's NVMe is lost
  and refills on demand.
- After a restart the server reloads its periodic snapshot if it is less than
  a week old and was written by the same pod name, so a restart on the same
  node normally comes back warm.
- Planned maintenance: silence this alert for the affected pods.

## Tuning

`_config.cacheServerDownFor` (default `5m`).
