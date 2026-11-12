# DacsCacheServersNotReady

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-availability` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

For 15 minutes the cache's StatefulSet has had fewer ready pods than
`spec.replicas` (from kube-state-metrics). Cache server pods have no readiness
probe, so "not ready" means the container is not running: Pending,
ContainerCreating, crash-looping or terminating.

The alert only covers caches that have had at least one scraped cache server
within the last hour (`_config.cacheDiscoveryLookback`).

## Impact

The discovery ConfigMap advertises the full server count, so clients keep
hashing keys onto the missing servers. Those keys miss the cache and are read
from Blob Storage. The hit ratio drops roughly in proportion to the share of
servers missing.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

```sh
kubectl get cache -n $NS $CACHE              # Ready, Current, Desired
kubectl describe cache -n $NS $CACHE         # conditions: ReplicasReady, PodsScheduled
kubectl get statefulset -n $NS $CACHE
kubectl get pods -n $NS -l dacs.azure.com/cache-name=$CACHE -o wide
kubectl describe pod -n $NS <pending-or-failing-pod>
```

- **Pending pods.** In host-storage mode the pods use
  `schedulerName: cache-controller`: they are placed by the cache-controller
  manager, not by the default scheduler. If the controller is down
  ([DacsControllerDown](DacsControllerDown.md)) nothing gets scheduled. Otherwise
  check that enough nodes carry the Cache's node selector label
  (`dacs.azure.com/processing-unit` by default) and tolerate its taints. The
  `PodsScheduled` condition reports `PodsStuck` or `PodsWaitingForNodeRecovery`.
- **Crash-looping pods.** Follow [DacsCacheServerDown](DacsCacheServerDown.md).
- **Dynamic scaling.** With `spec.scaling.dynamic` the desired count follows the
  number of eligible nodes; a node pool scale-up raises it before new pods are
  running. `status.scaling` shows the target and the stabilization window.
- **Rolling update.** The StatefulSet updates with `maxUnavailable: 10%`; a
  large cache can legitimately sit below desired for a while.

## Mitigation

- Restore or add nodes with the required label, or lower
  `spec.scaling.static.numServers` to what the cluster can hold. Remember that
  changing the server count remaps keys and costs hit ratio while the cache
  refills.
- Fix image pull, storage or resource problems reported in the pod events.
- If the controller is unhealthy, fix that first.

## Tuning

`_config.cacheServersNotReadyFor` (default `15m`). Raise it if rolling updates of large caches routinely take longer.
