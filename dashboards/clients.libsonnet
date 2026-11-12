local g = import 'g.libsonnet';

{
  local c = $._config,
  local wl = c.clientWorkloadLabel,
  local sel = std.join(', ', (if c.clientSelector == '' then [] else [c.clientSelector]) + ['%s=~"$workload"' % wl]),
  local legend = '{{%s}}' % wl,

  // Counters carry the suffix added by the OTLP -> Prometheus translation.
  local counter(name) = 'cache_client_%s%s' % [name, c.clientCounterSuffix],
  local rate(name, agg=wl, extra='') =
    'sum by (%s) (rate(%s{%s%s}[$window]))' % [agg, counter(name), sel, extra],
  local quantile(qt, metric, agg=wl) = |||
    histogram_quantile(%(qt)s, sum by (%(agg)s) (
      rate(%(metric)s_bucket{%(sel)s}[$window])
    ))
  ||| % { qt: qt, metric: metric, sel: sel, agg: if agg == '' then 'le' else agg + ', le' },
  local sizeClasses = ['40KB', '400KB', '4MB', '40MB', 'huge'],

  grafanaDashboards+:: {
    'dacs-clients.json':
      g.dashboard(
        'DACS / Clients',
        c.dashboardUIDs.clients,
        'DACS as seen by workloads: cache hits and misses, bytes requested and served, upload volume, DNS failures and client-side latency. Requires cache client metrics, which are off by default and are pushed over OTLP (see docs/client-metrics.md).',
        c,
        [
          g.datasourceVar,
          g.queryVar('workload', 'Workload', 'label_values(%s, %s)' % [counter('download_requests'), wl]),
          g.customVar('window', 'Rate window', ['15m', '30m', '1h', '3h'], c.clientRateInterval),
        ],
        [
          {
            title: 'About this dashboard',
            height: 4,
            panels: [
              g.text(
                'Read me',
                |||
                  Cache client metrics are **opt-in** (`STORAGE_METRIC_OTEL_ENABLED=true`) and are **pushed** over OTLP/HTTP every 5 minutes by default, so rates here use the long **Rate window** variable instead of the scrape interval.
                  The series names assume the standard OTLP to Prometheus translation (`_total` on counters) and `service.name` mapped to `%s`. If your pipeline differs, re-render the mixin with other settings. Client metrics carry no cache label; use one service name per workload to tell them apart.
                ||| % wl,
              ) { w:: 24 },
            ],
          },
          {
            title: 'Cache effectiveness',
            panels: [
              g.timeseries(
                'Hit ratio by workload',
                'Client-side hits divided by hits plus misses. A miss means the client went on to read the chunk from Blob Storage.',
                'percentunit',
                [
                  g.target(
                    '%s / (%s + %s)' % [rate('download_cache_hits'), rate('download_cache_hits'), rate('download_cache_misses')],
                    legend
                  ),
                ],
                min=0,
                max=1,
                fill=0,
              ),
              g.timeseries(
                'Hits and misses',
                'Download outcomes per workload. Downloads that fail with a transport or server error are in neither series.',
                'ops',
                [
                  g.target(rate('download_cache_hits'), legend + ' hits'),
                  g.target(rate('download_cache_misses'), legend + ' misses'),
                ],
                stack=true,
                min=0,
              ),
              g.timeseries(
                'Download requests',
                'Download calls made to the cache client per workload, whatever their outcome.',
                'ops',
                [g.target(rate('download_requests'), legend)],
                min=0,
              ),
              g.timeseries(
                'Downloads without a hit or miss',
                'Download requests minus hits and misses: calls that ended in an error or never reached a cache server. Negative blips are export-timing noise.',
                'ops',
                [
                  g.target(
                    '%s - (%s + %s)' % [rate('download_requests'), rate('download_cache_hits'), rate('download_cache_misses')],
                    legend
                  ),
                ],
                fill=0,
              ),
            ],
          },
          {
            title: 'Volume',
            panels: [
              g.timeseries(
                'Bytes requested and served from cache',
                'Bytes workloads asked the cache for against bytes it actually returned. The gap is data that had to come from Blob Storage or failed.',
                'Bps',
                [
                  g.target(rate('download_requested_bytes'), legend + ' requested'),
                  g.target(rate('downloaded_bytes'), legend + ' served from cache'),
                ],
                min=0,
              ),
              g.timeseries(
                'Bytes uploaded to cache',
                'Bytes workloads wrote into the cache: fills after a miss, plus cache writes.',
                'Bps',
                [g.target(rate('uploaded_bytes'), legend)],
                min=0,
              ),
              g.timeseries(
                'Upload requests',
                'Upload calls made to the cache client per workload.',
                'ops',
                [g.target(rate('upload_requests'), legend)],
                min=0,
              ),
              g.timeseries(
                'Maintenance requests',
                'Group deletes, deletes by last access time and last-access-time distribution queries issued by clients.',
                'ops',
                [
                  g.target(rate('delete_group_requests'), legend + ' delete group'),
                  g.target(rate('delete_by_last_access_time_requests'), legend + ' delete by access time'),
                  g.target(rate('get_last_access_time_distribution_requests'), legend + ' access time distribution'),
                ],
                min=0,
              ),
            ],
          },
          {
            title: 'Discovery and DNS',
            panels: [
              g.timeseries(
                'DNS errors by cache server',
                'Failed lookups of cache server pod DNS names. The server list comes from discovery, so errors here usually mean a listed server pod does not exist or is not ready yet.',
                'ops',
                [g.target(rate('dns_errors', wl + ', hostname'), legend + ' {{hostname}}')],
                min=0,
              ) { w:: 24 },
            ],
          },
          {
            title: 'Latency',
            panels: [
              g.timeseries(
                'Download latency',
                'Client-side latency of successful cache downloads (hits only), including connection setup and transfer.',
                'ms',
                [
                  g.target(quantile('0.50', 'cache_client_download_latency_ms'), legend + ' p50'),
                  g.target(quantile('0.99', 'cache_client_download_latency_ms'), legend + ' p99'),
                ],
                min=0,
                fill=0,
              ),
              g.timeseries(
                'Upload latency',
                'Client-side latency of successful cache uploads.',
                'ms',
                [
                  g.target(quantile('0.50', 'cache_client_upload_latency_ms'), legend + ' p50'),
                  g.target(quantile('0.99', 'cache_client_upload_latency_ms'), legend + ' p99'),
                ],
                min=0,
                fill=0,
              ),
              g.timeseries(
                'Download latency p99 by I/O size',
                'p99 download latency per I/O size class. The client records a separate histogram for requests up to 40 KB, 400 KB, 4 MB, 40 MB and larger.',
                'ms',
                [
                  g.target(quantile('0.99', 'cache_client_download_latency_ms_' + s, ''), s)
                  for s in sizeClasses
                ],
                min=0,
                fill=0,
              ),
              g.timeseries(
                'Upload latency p99 by I/O size',
                'p99 upload latency per I/O size class.',
                'ms',
                [
                  g.target(quantile('0.99', 'cache_client_upload_latency_ms_' + s, ''), s)
                  for s in sizeClasses
                ],
                min=0,
                fill=0,
              ),
            ],
          },
        ],
        timeFrom='now-6h',
      ),
  },
}
