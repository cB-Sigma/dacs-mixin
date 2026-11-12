# Runbooks

One page per alert. Each alert's `runbook_url` annotation points here.

| Alert | Severity | What it means |
|---|---|---|
| [DacsCacheServerDown](DacsCacheServerDown.md) | warning | A cache server's metrics endpoint cannot be scraped |
| [DacsCacheServersNotReady](DacsCacheServersNotReady.md) | warning | Fewer ready cache servers than the StatefulSet wants |
| [DacsCacheNoReadyServers](DacsCacheNoReadyServers.md) | critical | A cache has no ready servers at all |
| [DacsCacheHitRatioLow](DacsCacheHitRatioLow.md) | warning | Most downloads miss the cache |
| [DacsCacheErrorRatioHigh](DacsCacheErrorRatioHigh.md) | warning | More than 5% of requests end in an error status |
| [DacsCacheErrorRatioCritical](DacsCacheErrorRatioHigh.md) | critical | More than 25% of requests end in an error status |
| [DacsCacheDownloadLatencyHigh](DacsCacheDownloadLatencyHigh.md) | warning | p99 download latency above 1 s |
| [DacsCacheServerAcceptQueueOverflow](DacsCacheServerAcceptQueueOverflow.md) | warning | TCP accept queue overflowing |
| [DacsCacheServerListenDrops](DacsCacheServerListenDrops.md) | critical | Connection attempts dropped at the listen socket |
| [DacsCacheServerSynQueueDrops](DacsCacheServerSynQueueDrops.md) | warning | SYN queue full |
| [DacsCacheServerAcceptErrors](DacsCacheServerAcceptErrors.md) | warning | `accept()` failing |
| [DacsCacheServerNearCapacity](DacsCacheServerNearCapacity.md) | warning | Cache server above 95% of its configured size |
| [DacsControllerDown](DacsControllerDown.md) | warning | cache-controller down or not scraped |
| [DacsControllerReconcileErrors](DacsControllerReconcileErrors.md) | warning | Reconciles failing |
| [DacsControllerReconcilePanics](DacsControllerReconcilePanics.md) | warning | A reconcile panicked |
| [DacsControllerWorkqueueStalled](DacsControllerWorkqueueStalled.md) | warning | A reconcile has been running for over 10 minutes |
| [DacsClientDnsErrors](DacsClientDnsErrors.md) | warning | Opt-in. Clients cannot resolve a cache server |

The runbooks are written from the DACS source and documentation at commit
`27ec57c`. They have not been exercised against real incidents. If one sends
you down the wrong path, please open an issue or a pull request.

Useful background:

- [DACS architecture](https://github.com/Azure/dacs/blob/main/docs/architecture.md)
- [DACS deployment and operations guide](https://github.com/Azure/dacs/blob/main/user-guide.md)
- [Metric inventory](../metrics.md)
