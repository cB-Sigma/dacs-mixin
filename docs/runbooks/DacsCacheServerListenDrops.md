# DacsCacheServerListenDrops

| | |
|---|---|
| Severity | critical |
| Rule group | `dacs-cache-saturation` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The cache server pod is dropping more than one incoming connection attempt per
second at its listening sockets (`TcpExt.ListenDrops`) and has been for 10
minutes. `ListenDrops` counts every SYN the kernel discarded at a listener;
accept-queue overflow is the most common reason, but it also includes SYN-queue
overflow and memory pressure.

## Impact

A sustained share of client connects to this server fail or stall. Reads for
keys on this server time out and fall back to Blob Storage; in practice the
server is partly unreachable.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

Same procedure as
[DacsCacheServerAcceptQueueOverflow](DacsCacheServerAcceptQueueOverflow.md).
In addition:

- Compare "Accept queue overflows and listen drops": drops well above overflows
  point at the SYN queue or memory, see
  [DacsCacheServerSynQueueDrops](DacsCacheServerSynQueueDrops.md).
- Check the node for memory pressure and conntrack exhaustion
  (`dmesg | grep -i conntrack` on the node).
- Check whether one workload is opening connections in a tight loop
  ("New connections").

## Mitigation

- Reduce the connection rate (fix the looping client) or add servers.
- Raise the listen backlog and `net.core.somaxconn` as described in the
  accept-queue runbook.
- If the pod is otherwise healthy but stuck, restart it; clients re-resolve
  and reconnect.

## Tuning

`_config.listenDropsPerSecondThreshold` (1) and `listenDropsFor` (`10m`).
