# DacsCacheServerNearCapacity

| | |
|---|---|
| Severity | warning |
| Rule group | `dacs-cache-saturation` |
| Source | [`alerts/`](../../alerts/) |

## Meaning

A cache server has been using more than 95% of its configured size for 30
minutes.

DACS does not export the size limit, so this alert only works for caches whose
per-server capacity you have supplied as `dacs:cache_server:capacity_bytes`
(see [capacity.md](../capacity.md)). Without that series it never fires.

With default settings (`spec.eviction`: access-time eviction on, start at 90%,
stop at 80%) usage should oscillate between 80% and 90%. Staying above 95%
means eviction is disabled, mis-configured, or cannot keep up with writes.

## Impact

A cache server at its limit cannot store new chunks, so fills fail and the hit
ratio decays as the working set moves on. On host storage shared with other
data it can also put the node under disk pressure.

## Diagnosis

Set these first; the alert labels give you the values:

```sh
NS=cache-server        # {{ $labels.namespace }}
CACHE=cache-sample     # {{ $labels.cache }}
POD=cache-sample-0     # {{ $labels.pod }}, where the alert has one
```

```sh
kubectl get cache -n $NS $CACHE -o jsonpath='{.spec.serverSizeInGB}{"\n"}{.spec.eviction}{"\n"}'
kubectl logs -n $NS $POD -c cacheserver --tail=500 | grep -iE 'evict|CacheSize'
kubectl exec -n $NS $POD -c cacheserver -- df -h
```

- The server logs `CacheSize`, `CacheSizeLimit` and `CacheSizePercentage` once
  a minute; that is the authoritative utilisation.
- Check that the capacity you supplied to the mixin still matches
  `spec.serverSizeInGB`. A resized cache with a stale capacity rule produces a
  false alert.
- Eviction settings: `enableAccessTimeEviction`, `sizeThreshold`, `sizeTarget`,
  `passFrequency`, `lastAccessThreshold`, `evictionMaintainFreeSpace`.
- Is the write rate ("Bytes written by pod") higher than one eviction pass can
  free?

## Mitigation

- Enable eviction, or lower `sizeThreshold` / raise the pass frequency so it
  runs sooner and more often.
- Raise `spec.serverSizeInGB` if the NVMe has room, or add servers.
- Delete data that is no longer needed through the client's delete-by-group
  or delete-by-last-access-time operations.
- Fix the capacity rule if it is simply out of date.

## Tuning

`_config.nearCapacityThreshold` (0.95) and `nearCapacityFor` (`30m`). Keep the threshold above the cache's eviction `sizeThreshold`.
