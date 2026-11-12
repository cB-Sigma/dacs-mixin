local g = import 'g.libsonnet';

{
  local c = $._config,
  local sel = '%(cacheServerSelector)s, namespace=~"$namespace", %(cacheLabel)s=~"$cache"' % c,
  local by = 'namespace, %(cacheLabel)s' % c,
  local legend = '{{namespace}}/{{%(cacheLabel)s}}' % c,
  local q = c { sel: sel, by: by },

  local requests(matchers, agg='') =
    'sum%(agg)s (rate(cache_server_request_counter{%(sel)s%(matchers)s}[$__rate_interval]))' % {
      sel: sel,
      agg: if agg == '' then '' else ' by (%s)' % agg,
      matchers: if matchers == '' then '' else ', ' + matchers,
    },
  local hits(agg='') = requests('request_type="Download", status="Success"', agg),
  local lookups(agg='') = requests('request_type="Download", status=~"Success|InvalidTransition"', agg),
  local misses(agg='') = requests('request_type="Download", status="InvalidTransition"', agg),
  local real = 'request_type!~"%(ignoredRequestTypes)s"' % c,
  local errors(agg='') = requests(real + ', status=~"%(errorStatuses)s"' % c, agg),

  // StatefulSet replica counts from kube-state-metrics, restricted to caches
  // that currently have scrape targets.
  local fleet(metric) = |||
    max by (%(by)s) (
      label_replace(%(metric)s{%(kubeStateMetricsSelector)s, namespace=~"$namespace"}, "%(cacheLabel)s", "$1", "statefulset", "(.+)")
    )
    and on (%(by)s) group by (%(by)s) (up{%(sel)s})
  ||| % (q { metric: metric }),
  local desired = fleet('kube_statefulset_replicas'),
  local ready = fleet('kube_statefulset_status_replicas_ready'),

  local latency(quantile, requestType) = |||
    histogram_quantile(%(quantile)s, sum by (%(by)s, le) (
      rate(cache_server_successful_request_latency_ms_bucket{%(sel)s, request_type="%(requestType)s"}[$__rate_interval])
    ))
  ||| % (q { quantile: quantile, requestType: requestType }),

  local usedRatio = |||
    sum by (%(by)s) (cache_server_cache_size_bytes{%(sel)s})
    /
    sum by (%(by)s) (
      (cache_server_cache_size_bytes{%(sel)s} * 0 + 1)
      * on (%(by)s) group_left () dacs:cache_server:capacity_bytes
    )
  ||| % q,

  grafanaDashboards+:: {
    'dacs-overview.json':
      g.dashboard(
        'DACS / Overview',
        c.dashboardUIDs.overview,
        'Health of every DACS cache at a glance: hit ratio, traffic, bytes served from cache, latency, space used and server fleet. All data comes from cache server metrics, plus kube-state-metrics for replica counts.',
        c,
        [
          g.datasourceVar,
          g.queryVar('namespace', 'Namespace', 'label_values(up{%(cacheServerSelector)s}, namespace)' % c),
          g.queryVar('cache', 'Cache', 'label_values(up{%(cacheServerSelector)s, namespace=~"$namespace"}, %(cacheLabel)s)' % c),
        ],
        [
          {
            title: 'At a glance',
            height: 5,
            panels: [
              g.stat(
                'Hit ratio',
                'Share of download requests answered from the cache. A download with status Success is a hit; InvalidTransition is how the server reports a miss.',
                'percentunit',
                [g.target('%s / %s' % [hits(), lookups()])],
                steps=[[null, 'red'], [0.5, 'orange'], [0.8, 'green']],
                decimals=1,
              ) { w:: 4 },
              g.stat(
                'Request rate',
                'Requests per second across the selected caches, all request types and statuses.',
                'reqps',
                [g.target(requests(real))],
              ) { w:: 4 },
              g.stat(
                'Error ratio',
                'Share of requests that ended with status %(errorStatuses)s. Cache misses are not errors. Connections dropped before a request was parsed (request_type Unknown) are excluded.' % c,
                'percentunit',
                [g.target('%s / %s' % [errors(), requests(real)])],
                steps=[[null, 'green'], [0.01, 'orange'], [0.05, 'red']],
                decimals=2,
              ) { w:: 4 },
              g.stat(
                'Served from cache',
                'Bytes per second sent to clients on cache hits (sum of successful download sizes).',
                'Bps',
                [g.target('sum(rate(cache_server_download_request_size_bytes_sum{%s}[$__rate_interval]))' % sel)],
              ) { w:: 4 },
              g.stat(
                'Cache space used',
                'Bytes currently stored across all selected cache servers. Each server refreshes this value once a minute.',
                'bytes',
                [g.target('sum(cache_server_cache_size_bytes{%s})' % sel)],
              ) { w:: 4 },
              g.stat(
                'Servers ready / desired',
                'Ready cache server pods against the replica count requested by the StatefulSets. Requires kube-state-metrics. Cache servers have no readiness probe, so "ready" means the container is running.',
                'short',
                [
                  g.target('sum(%s)' % ready, 'ready'),
                  g.target('sum(%s)' % desired, 'desired'),
                ],
                graph=false,
                textMode='value_and_name',
              ) { w:: 4 },
            ],
          },
          {
            title: 'Hits and traffic',
            panels: [
              g.timeseries(
                'Hit ratio by cache',
                'Download hits divided by download lookups, per cache. Drops are expected right after a cache is created, scaled or restarted without a usable snapshot.',
                'percentunit',
                [g.target('%s / %s' % [hits(by), lookups(by)], legend)],
                min=0,
                max=1,
                fill=0,
              ),
              g.timeseries(
                'Download hits and misses',
                'Download requests split into hits (served from cache) and misses (the client goes on to read the chunk from Blob Storage).',
                'reqps',
                [
                  g.target(hits(by), legend + ' hits'),
                  g.target(misses(by), legend + ' misses'),
                ],
                stack=true,
                min=0,
              ),
              g.timeseries(
                'Requests by type',
                'Request rate by protocol request type. Upload is a cache fill or write, Getcacheservers is client discovery, Ibinit is InfiniBand session setup.',
                'reqps',
                [g.target(requests('', 'request_type'), '{{request_type}}')],
                stack=true,
                min=0,
              ),
              g.timeseries(
                'Requests by status',
                'Request rate by server status. InvalidTransition is not an error: it marks a miss on Download and an already-cached chunk on Upload.',
                'reqps',
                [g.target(requests('', 'status'), '{{status}}')],
                stack=true,
                min=0,
              ),
            ],
          },
          {
            title: 'Bytes',
            panels: [
              g.timeseries(
                'Bytes served from cache',
                'Throughput of cache hits per cache. This is data that did not have to come from Blob Storage.',
                'Bps',
                [g.target('sum by (%s) (rate(cache_server_download_request_size_bytes_sum{%s}[$__rate_interval]))' % [by, sel], legend)],
                min=0,
              ),
              g.timeseries(
                'Bytes written into cache',
                'Throughput of successful uploads per cache. After a miss the client reads the chunk from Blob Storage and uploads it here, so this approximates bytes fetched from Blob on behalf of the cache; it also includes direct cache writes. DACS does not export Blob traffic itself.',
                'Bps',
                [g.target('sum by (%s) (rate(cache_server_upload_request_size_bytes_sum{%s}[$__rate_interval]))' % [by, sel], legend)],
                min=0,
              ),
            ],
          },
          {
            title: 'Latency',
            panels: [
              g.timeseries(
                'Download latency (successful)',
                'Server-side latency of successful downloads, from request read to response sent. Histogram buckets top out at 10 s, so higher quantiles saturate there.',
                'ms',
                [
                  g.target(latency('0.50', 'Download'), legend + ' p50'),
                  g.target(latency('0.99', 'Download'), legend + ' p99'),
                ],
                min=0,
                fill=0,
              ),
              g.timeseries(
                'Upload latency (successful)',
                'Server-side latency of successful uploads, including receiving the payload and writing it to cache storage.',
                'ms',
                [
                  g.target(latency('0.50', 'Upload'), legend + ' p50'),
                  g.target(latency('0.99', 'Upload'), legend + ' p99'),
                ],
                min=0,
                fill=0,
              ),
            ],
          },
          {
            title: 'Capacity and fleet',
            panels: [
              g.timeseries(
                'Cache space used',
                'Bytes stored per cache, summed over its servers.',
                'bytes',
                [g.target('sum by (%s) (cache_server_cache_size_bytes{%s})' % [by, sel], legend)],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'Capacity used',
                'Space used as a share of configured capacity. Empty until per-server capacity is supplied as dacs:cache_server:capacity_bytes, because DACS does not export its size limit (see docs/capacity.md). With default eviction settings usage oscillates between 80% and 90%.',
                'percentunit',
                [g.target(usedRatio, legend)],
                min=0,
                max=1,
                fill=0,
              ) { w:: 8 },
              g.timeseries(
                'Servers',
                'Desired and ready replicas from kube-state-metrics, and the number of servers Prometheus can scrape.',
                'short',
                [
                  g.target(desired, legend + ' desired'),
                  g.target(ready, legend + ' ready'),
                  g.target('sum by (%s) (up{%s})' % [by, sel], legend + ' scraped'),
                ],
                min=0,
                decimals=0,
                fill=0,
              ) { w:: 8 },
              g.table(
                'Caches',
                'Current state of each cache. Rates are averaged over the last 5 minutes.',
                [
                  { name: 'Hit ratio', unit: 'percentunit', decimals: 1, expr: std.strReplace('%s / %s' % [hits(by), lookups(by)], '$__rate_interval', '5m') },
                  { name: 'Requests', unit: 'reqps', expr: std.strReplace(requests(real, by), '$__rate_interval', '5m') },
                  { name: 'Served from cache', unit: 'Bps', expr: 'sum by (%s) (rate(cache_server_download_request_size_bytes_sum{%s}[5m]))' % [by, sel] },
                  { name: 'Space used', unit: 'bytes', expr: 'sum by (%s) (cache_server_cache_size_bytes{%s})' % [by, sel] },
                  { name: 'Servers scraped', unit: 'short', expr: 'sum by (%s) (up{%s})' % [by, sel] },
                ],
              ) { w:: 24 },
            ],
          },
        ],
      ),
  },
}
