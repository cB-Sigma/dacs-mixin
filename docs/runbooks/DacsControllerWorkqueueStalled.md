# DacsControllerWorkqueueStalled

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-controller` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

A worker of the controller's workqueue has been processing the same item for
more than 10 minutes (`workqueue_longest_running_processor_seconds`). A
reconcile normally finishes in well under a second.

## Impact

The stuck worker is unavailable. If it is the only worker for the `cache`
controller, no Cache is reconciled until it returns, with the same
consequences as [DacsControllerDown](DacsControllerDown.md) even though the
pod looks healthy.

## Diagnosis

```sh
NS=cache-server   # namespace of the DACS Helm release
kubectl logs -n $NS -l app.kubernetes.io/name=dacs --tail=500
kubectl get --raw /readyz?verbose | tail -n 5      # API server health
```

On **DACS / Controller**: "Unfinished work" rising in a straight line confirms
it; "Workers" shows whether all workers are busy; "Kubernetes API requests by
code" shows whether calls to the API server are hanging or failing.

A reconcile usually hangs on a call that never returns: an unreachable API
server or webhook, or a lock.

## Mitigation

- Restart the controller pod. It is safe: the controller is not in the data
  path and reconciliation is idempotent.

  ```sh
  kubectl rollout restart deployment -n $NS -l app.kubernetes.io/name=dacs
  ```
- If it recurs, capture logs (and a goroutine dump through the controller's
  optional pprof endpoint) and report it upstream.

## Tuning

`_config.controllerWorkqueueStalledSeconds` (600) and `controllerWorkqueueStalledFor` (`5m`).
