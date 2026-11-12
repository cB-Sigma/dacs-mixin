{
  local c = $._config,

  // Recording rules for cache server metrics. Everything here is computed
  // from metrics the cache server exports directly.
  prometheusRules+:: {
    groups+: [
      {
        name: 'dacs-cache.rules',
        rules: [
          {
            record: 'dacs:cache:request_rate5m',
            expr: |||
              sum by (namespace, %(cacheLabel)s, request_type, status) (
                rate(cache_server_request_counter{%(cacheServerSelector)s}[5m])
              )
            ||| % c,
          },
          {
            // Download + Success is a hit, Download + InvalidTransition is a miss.
            record: 'dacs:cache:download_hit_ratio_rate5m',
            expr: |||
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type="Download", status="Success"})
              /
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type="Download", status=~"Success|InvalidTransition"})
            ||| % c,
          },
          {
            record: 'dacs:cache:error_ratio_rate5m',
            expr: |||
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type!~"%(ignoredRequestTypes)s", status=~"%(errorStatuses)s"})
              /
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type!~"%(ignoredRequestTypes)s"})
            ||| % c,
          },
        ] + [
          {
            record: 'dacs:cache:request_latency_ms:p%d_rate5m' % q,
            expr: |||
              histogram_quantile(
                0.%(q)d,
                sum by (namespace, %(cacheLabel)s, request_type, le) (
                  rate(cache_server_successful_request_latency_ms_bucket{%(cacheServerSelector)s}[5m])
                )
              )
            ||| % (c { q: q }),
          }
          for q in [50, 90, 99]
        ] + [
          {
            // Bytes sent to clients on cache hits.
            record: 'dacs:cache:served_bytes_rate5m',
            expr: |||
              sum by (namespace, %(cacheLabel)s) (
                rate(cache_server_download_request_size_bytes_sum{%(cacheServerSelector)s}[5m])
              )
            ||| % c,
          },
          {
            // Bytes clients uploaded into the cache (fills after a miss, plus cache writes).
            record: 'dacs:cache:written_bytes_rate5m',
            expr: |||
              sum by (namespace, %(cacheLabel)s) (
                rate(cache_server_upload_request_size_bytes_sum{%(cacheServerSelector)s}[5m])
              )
            ||| % c,
          },
          {
            record: 'dacs:cache:size_bytes',
            expr: |||
              sum by (namespace, %(cacheLabel)s) (cache_server_cache_size_bytes{%(cacheServerSelector)s})
            ||| % c,
          },
          {
            record: 'dacs:cache:servers_up',
            expr: |||
              sum by (namespace, %(cacheLabel)s) (up{%(cacheServerSelector)s})
            ||| % c,
          },
        ],
      },
      {
        // Desired / ready replicas come from kube-state-metrics. The StatefulSet
        // is named after the Cache, so `statefulset` is mapped onto the cache
        // label and restricted to caches that have been scraped recently.
        name: 'dacs-cache-fleet.rules',
        rules: [
          {
            record: 'dacs:cache:servers_%s' % r.name,
            expr: |||
              max by (namespace, %(cacheLabel)s) (
                label_replace(%(metric)s{%(kubeStateMetricsSelector)s}, "%(cacheLabel)s", "$1", "statefulset", "(.+)")
              )
              and on (namespace, %(cacheLabel)s)
              group by (namespace, %(cacheLabel)s) (last_over_time(up{%(cacheServerSelector)s}[%(cacheDiscoveryLookback)s]))
            ||| % (c { metric: r.metric }),
          }
          for r in [
            { name: 'desired', metric: 'kube_statefulset_replicas' },
            { name: 'ready', metric: 'kube_statefulset_status_replicas_ready' },
          ]
        ],
      },
    ] + (
      if std.length(c.cacheCapacities) == 0 then [] else [
        {
          // Static per-server capacity supplied through _config.cacheCapacities.
          name: 'dacs-cache-capacity.rules',
          rules: [
            {
              record: 'dacs:cache_server:capacity_bytes',
              expr: 'vector(%d)' % cap.serverSizeBytes,
              labels: {
                namespace: cap.namespace,
                [c.cacheLabel]: cap.cache,
              },
            }
            for cap in c.cacheCapacities
          ],
        },
      ]
    ),
  },

  // Opt-in rules for cache client metrics. Not part of prometheusRules
  // because the series names depend on the OTel pipeline in use.
  clientRules+:: {
    local sel = if c.clientSelector == '' then '' else '{%s}' % c.clientSelector,
    local cc = c { sel: sel },
    groups+: [
      {
        name: 'dacs-client.rules',
        rules: [
          {
            record: 'dacs:client:download_hit_ratio_rate%(clientRateInterval)s' % c,
            expr: |||
              sum by (%(clientWorkloadLabel)s) (rate(cache_client_download_cache_hits%(clientCounterSuffix)s%(sel)s[%(clientRateInterval)s]))
              /
              (
                sum by (%(clientWorkloadLabel)s) (rate(cache_client_download_cache_hits%(clientCounterSuffix)s%(sel)s[%(clientRateInterval)s]))
                +
                sum by (%(clientWorkloadLabel)s) (rate(cache_client_download_cache_misses%(clientCounterSuffix)s%(sel)s[%(clientRateInterval)s]))
              )
            ||| % cc,
          },
        ],
      },
    ],
  },
}
