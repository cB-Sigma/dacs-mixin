# DacsCacheDownloadLatencyHigh

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-traffic` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The p99 server-side latency of successful downloads from this cache has been
above 1000 ms for 15 minutes. Latency is measured in the cache server from
reading the request to finishing the response, so it includes sending the
chunk to the client.

The histogram's largest finite bucket is 10 s; values near 10000 ms mean
"at least that".

## Impact

Cache hits are slow. Data loaders and model loads that depend on the cache
slow down even though the hit ratio looks healthy. Slow clients on a congested
network also show up here, because the server waits for the socket.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

On **DACS / Cache servers**, compare "Download latency p99 by pod" across pods.

- **One pod slow:** look at that node.

  ```sh
  kubectl get pod -n $NS $POD -o wide
  kubectl top pod -n $NS $POD
  kubectl describe node <node>
  ```

  Check NVMe health and I/O wait, CPU throttling (`spec.cpuLimit`) and noisy
  neighbours.
- **All pods slow:** look for saturation.
  - "In-flight requests" pinned at `spec.serverThreads` means the worker pool
    is full and requests queue.
  - An egress cap (`spec.egressBandwidthLimitGbps`) shapes traffic with `tc`
    and stretches every large download once it is reached. Compare "Bytes
    served by pod" with the cap.
  - "Average download size": a workload that moved to much larger reads raises
    latency without anything being wrong.
- **Accept-queue alerts firing too:** the server is overloaded; see
  [DacsCacheServerAcceptQueueOverflow](DacsCacheServerAcceptQueueOverflow.md).

## Mitigation

- Add servers or raise `spec.serverThreads` if the pool is saturated and the
  node has CPU to spare.
- Raise or remove the egress or CPU limit if it is the bottleneck.
- Replace or drain a node with degraded storage.
- If large reads are simply the workload's nature, raise the threshold.

## Tuning

`_config.downloadLatencyP99ThresholdMs` (1000) and `downloadLatencyFor` (`15m`).
