# DacsCacheServerAcceptErrors

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-saturation` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

`accept()` on the cache server's listening socket has been failing for 5
minutes. The `errno` label says why:

| errno | Name | Meaning |
|---|---|---|
| 24 | `EMFILE` | The process hit its open-file limit |
| 23 | `ENFILE` | The node hit its system-wide file limit |
| 12 | `ENOMEM` | Out of kernel memory for sockets |
| 105 | `ENOBUFS` | Out of socket buffer space |
| 103 | `ECONNABORTED` | The client gave up before the connection was accepted |

## Impact

Each failure is a client connection that was not accepted. With `EMFILE` or
`ENFILE` the server cannot accept anything new until descriptors are freed,
and may fail to open cache files as well.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

```sh
kubectl logs -n $NS $POD -c cacheserver --tail=200 | grep -i 'accept failed'
kubectl exec -n $NS $POD -c cacheserver -- sh -c 'ulimit -n; ls /proc/1/fd | wc -l; cat /proc/sys/fs/file-nr'
```

- `ulimit -n` against the descriptor count tells you whether it is the process
  limit (`EMFILE`).
- `/proc/sys/fs/file-nr` (allocated, unused, maximum) tells you whether it is
  the node (`ENFILE`). This is also what the "Allocated file handles" panel
  shows; remember it is node-wide.
- The main process is not necessarily PID 1 in the container; adjust the
  `/proc/<pid>/fd` path if needed.
- `ECONNABORTED` in small numbers is harmless; in large numbers it means
  clients are timing out in the accept queue, see
  [DacsCacheServerAcceptQueueOverflow](DacsCacheServerAcceptQueueOverflow.md).

## Mitigation

- `EMFILE`: too many client connections for the container's file limit. Add
  cache servers to spread connections, lower the clients' connection pool
  size, or raise the container runtime's `nofile` limit.
- `ENFILE`: find what is consuming file handles on the node; raise
  `fs.file-max` if the node is legitimately busy.
- `ENOMEM` / `ENOBUFS`: relieve memory pressure on the node; check
  `spec.memoryLimitMB`.

## Tuning

`_config.acceptErrorsFor` (default `5m`).
