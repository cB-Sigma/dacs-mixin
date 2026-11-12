# DacsControllerReconcilePanics

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-controller` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

The cache-controller recovered from at least one panic inside a reconcile in
the last 15 minutes (`controller_runtime_reconcile_panics_total` increased).
The alert has no `for`: one panic is enough, and it clears 15 minutes after
the last one.

## Impact

A panic is a bug. controller-runtime recovers and retries, so the controller
keeps running, but the Cache that triggers it will most likely panic again on
every retry and never converge.

## Diagnosis

```sh
NS=cache-server   # namespace of the DACS Helm release
kubectl logs -n $NS -l app.kubernetes.io/name=dacs --tail=1000 | grep -B5 -A40 -i panic
```

The stack trace names the function, and the log line before it names the
Cache being reconciled. Note the DACS version and the Cache spec.

## Mitigation

- Work around it by changing or removing the Cache that triggers the panic.
- Report it at https://github.com/Azure/dacs/issues with the stack trace.
- Roll back if it started with an upgrade.
