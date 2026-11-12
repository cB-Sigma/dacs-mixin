# DacsCacheNoReadyServers

| | |
|---|---|
| Severity | critical |
| Rule group | `dacs-cache-availability` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The cache's StatefulSet wants at least one replica and has had zero ready pods
for 5 minutes.

## Impact

The cache is effectively off. Discovery requests to
`<cache>-discovery.<namespace>.svc.cluster.local` have no backend, and every
read goes to Azure Blob Storage. Workloads keep running if Blob is reachable,
but at Blob latency and throughput; jobs sized on the assumption of a warm
cache may stall or time out, and Blob egress and transaction costs rise.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

```sh
kubectl get cache -n $NS $CACHE
kubectl describe cache -n $NS $CACHE
kubectl get pods -n $NS -l dacs.azure.com/cache-name=$CACHE -o wide
kubectl get events -n $NS --sort-by=.lastTimestamp | tail -n 30
kubectl get nodes -l dacs.azure.com/processing-unit   # adjust to the Cache's node selector key
```

All pods failing at once usually has a shared cause:

- the node pool that hosts the cache was scaled to zero, upgraded or lost;
- the cache server image cannot be pulled;
- the cache-controller is down and pods are waiting to be scheduled
  (host-storage mode uses `schedulerName: cache-controller`);
- a bad change to the Cache spec (image, env, resources) crash-loops every pod.

Then follow [DacsCacheServersNotReady](DacsCacheServersNotReady.md) and
[DacsCacheServerDown](DacsCacheServerDown.md) for the individual pods.

## Mitigation

- Bring the hosting nodes back, or fix the shared cause above.
- Roll back the most recent change to the Cache resource or the DACS release
  if the outage followed one.
- Warn workload owners: until servers return, expect cold-read performance.
  When they do return on the same nodes, snapshots usually restore the cache
  contents; on new nodes the cache starts empty.

## Tuning

`_config.cacheNoReadyServersFor` (default `5m`).
