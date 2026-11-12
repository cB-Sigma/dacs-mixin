local g = import 'g.libsonnet';

{
  local c = $._config,
  local sel = '%(cacheServerSelector)s, namespace=~"$namespace", %(cacheLabel)s=~"$cache", pod=~"$pod"' % c,
  local real = 'request_type!~"%(ignoredRequestTypes)s"' % c,

  local requests(matchers, agg) =
    'sum by (%(agg)s) (rate(cache_server_request_counter{%(sel)s%(matchers)s}[$__rate_interval]))' % {
      sel: sel,
      agg: agg,
      matchers: if matchers == '' then '' else ', ' + matchers,
    },
  local counter(metric, agg='pod') =
    'sum by (%s) (rate(%s{%s}[$__rate_interval]))' % [agg, metric, sel],
  local quantile(qt, metric, matchers='', agg='pod') = |||
    histogram_quantile(%(qt)s, sum by (%(agg)s, le) (
      rate(%(metric)s_bucket{%(sel)s%(matchers)s}[$__rate_interval])
    ))
  ||| % { qt: qt, metric: metric, sel: sel, agg: agg, matchers: if matchers == '' then '' else ', ' + matchers },
  local average(metric) =
    'sum by (pod) (rate(%(m)s_sum{%(sel)s}[$__rate_interval])) / sum by (pod) (rate(%(m)s_count{%(sel)s}[$__rate_interval]))' % { m: metric, sel: sel },

  grafanaDashboards+:: {
    'dacs-cache-servers.json':
      g.dashboard(
        'DACS / Cache servers',
        c.dashboardUIDs.servers,
        'Per-pod drill-down for DACS cache servers: requests, latency, connection and accept-queue health, file descriptors, request sizes and space used.',
        c,
        [
          g.datasourceVar,
          g.queryVar('namespace', 'Namespace', 'label_values(up{%(cacheServerSelector)s}, namespace)' % c),
          g.queryVar('cache', 'Cache', 'label_values(up{%(cacheServerSelector)s, namespace=~"$namespace"}, %(cacheLabel)s)' % c),
          g.queryVar('pod', 'Pod', 'label_values(up{%(cacheServerSelector)s, namespace=~"$namespace", %(cacheLabel)s=~"$cache"}, pod)' % c),
        ],
        [
          {
            title: 'Servers',
            height: 7,
            panels: [
              g.table(
                'Cache servers',
                'One row per cache server pod. Rates are averaged over the last 5 minutes. "Up" is 1 when the last scrape of the pod succeeded.',
                [
                  { name: 'Up', unit: 'short', expr: 'max by (namespace, %s, pod) (up{%s})' % [c.cacheLabel, sel] },
                  { name: 'Requests', unit: 'reqps', expr: 'sum by (namespace, %s, pod) (rate(cache_server_request_counter{%s, %s}[5m]))' % [c.cacheLabel, sel, real] },
                  {
                    name: 'Hit ratio',
                    unit: 'percentunit',
                    decimals: 1,
                    expr: |||
                      sum by (namespace, %(cl)s, pod) (rate(cache_server_request_counter{%(sel)s, request_type="Download", status="Success"}[5m]))
                      /
                      sum by (namespace, %(cl)s, pod) (rate(cache_server_request_counter{%(sel)s, request_type="Download", status=~"Success|InvalidTransition"}[5m]))
                    ||| % { cl: c.cacheLabel, sel: sel },
                  },
                  { name: 'In-flight requests', unit: 'short', expr: 'max by (namespace, %s, pod) (cache_server_active_connections{%s})' % [c.cacheLabel, sel] },
                  { name: 'Space used', unit: 'bytes', expr: 'max by (namespace, %s, pod) (cache_server_cache_size_bytes{%s})' % [c.cacheLabel, sel] },
                ],
              ) { w:: 24 },
            ],
          },
          {
            title: 'Requests',
            panels: [
              g.timeseries(
                'Requests by pod',
                'Request rate handled by each cache server. Clients pick a server by hashing the cache key, so load should be roughly even; a flat line on one pod usually means clients cannot reach it.',
                'reqps',
                [g.target(requests(real, 'pod'), '{{pod}}')],
                min=0,
              ),
              g.timeseries(
                'Hit ratio by pod',
                'Download hits divided by download lookups for each server. A single pod with a low ratio was probably restarted or rescheduled and is refilling.',
                'percentunit',
                [
                  g.target(
                    '%s / %s' % [
                      requests('request_type="Download", status="Success"', 'pod'),
                      requests('request_type="Download", status=~"Success|InvalidTransition"', 'pod'),
                    ],
                    '{{pod}}'
                  ),
                ],
                min=0,
                max=1,
                fill=0,
              ),
              g.timeseries(
                'Errors by pod and status',
                'Requests that ended with status %(errorStatuses)s. NetworkError means the connection broke while a request or response was in flight; InternalError includes cache state that no longer matches the files on disk.' % c,
                'reqps',
                [g.target(requests(real + ', status=~"%(errorStatuses)s"' % c, 'pod, status'), '{{pod}} {{status}}')],
                min=0,
              ),
              g.timeseries(
                'Aborted connections',
                'Connections that were closed, or sent something unparseable, before a request could be read. They are recorded as request_type Unknown and are left out of error ratios.',
                'ops',
                [g.target(requests('request_type=~"%(ignoredRequestTypes)s"' % c, 'pod'), '{{pod}}')],
                min=0,
              ),
            ],
          },
          {
            title: 'Latency',
            panels: [
              g.timeseries(
                'Download latency p99 by pod',
                'p99 server-side latency of successful downloads per pod. Buckets top out at 10 s.',
                'ms',
                [g.target(quantile('0.99', 'cache_server_successful_request_latency_ms', 'request_type="Download"'), '{{pod}}')],
                min=0,
                fill=0,
              ) { w:: 8 },
              g.timeseries(
                'Upload latency p99 by pod',
                'p99 server-side latency of successful uploads per pod, including the write to cache storage.',
                'ms',
                [g.target(quantile('0.99', 'cache_server_successful_request_latency_ms', 'request_type="Upload"'), '{{pod}}')],
                min=0,
                fill=0,
              ) { w:: 8 },
              g.heatmap(
                'Download latency distribution',
                'Distribution of successful download latency across the selected pods.',
                'ms',
                'sum by (le) (rate(cache_server_successful_request_latency_ms_bucket{%s, request_type="Download"}[$__rate_interval]))' % sel,
              ) { w:: 8 },
            ],
          },
          {
            title: 'Connections and accept queue',
            panels: [
              g.timeseries(
                'In-flight requests',
                'Requests currently being handled by worker threads (cache_server_active_connections). Despite the name this is not the number of open sockets; it is bounded by the server thread pool (spec.serverThreads).',
                'short',
                [g.target('max by (pod) (cache_server_active_connections{%s})' % sel, '{{pod}}')],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'New connections',
                'Passively opened TCP connections per second in the pod network namespace (Tcp.PassiveOpens). The server samples kernel counters once a minute.',
                'cps',
                [g.target(counter('cache_server_passive_opens_total'), '{{pod}}')],
                min=0,
              ) { w:: 8 },
              g.stat(
                'Listen backlog',
                'Backlog the server passed to listen(). The effective accept queue is also capped by net.core.somaxconn.',
                'short',
                [g.target('max by (pod) (cache_server_listen_backlog_max{%s})' % sel, '{{pod}}')],
                graph=false,
                textMode='value_and_name',
              ) { w:: 8 },
              g.timeseries(
                'Accept queue overflows and listen drops',
                'TcpExt.ListenOverflows (accept queue full) and TcpExt.ListenDrops (any SYN dropped at a listening socket) per second. Anything above zero means clients are failing or retrying connects.',
                'ops',
                [
                  g.target(counter('cache_server_accept_queue_overflows_total'), '{{pod}} overflows'),
                  g.target(counter('cache_server_listen_drops_total'), '{{pod}} listen drops'),
                ],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'SYN queue drops and SYN cookies',
                'TcpExt.TCPReqQFullDrop (SYN dropped because the request queue was full) and TcpExt.TCPReqQFullDoCookies (SYN cookie sent instead) per second.',
                'ops',
                [
                  g.target(counter('cache_server_syn_queue_full_drops_total'), '{{pod}} drops'),
                  g.target(counter('cache_server_syn_cookies_sent_total'), '{{pod}} cookies'),
                ],
                min=0,
              ) { w:: 8 },
              g.timeseries(
                'accept() errors',
                'Failed accept() calls by errno. 24 (EMFILE) and 23 (ENFILE) mean file descriptors ran out.',
                'ops',
                [g.target(counter('cache_server_accept_errors_total', 'pod, errno'), '{{pod}} errno {{errno}}')],
                min=0,
              ) { w:: 8 },
            ],
          },
          {
            title: 'File descriptors and space',
            panels: [
              g.timeseries(
                'Allocated file handles',
                'cache_server_open_fds, read from /proc/sys/fs/file-nr. That file is system-wide, so this is the number of file handles allocated on the node, not by the cache server process alone.',
                'short',
                [g.target('max by (pod) (cache_server_open_fds{%s})' % sel, '{{pod}}')],
                min=0,
              ),
              g.timeseries(
                'Space used by pod',
                'Bytes stored by each cache server. Eviction, when enabled, starts at spec.eviction.sizeThreshold (90% by default) and stops at sizeTarget (80%).',
                'bytes',
                [g.target('max by (pod) (cache_server_cache_size_bytes{%s})' % sel, '{{pod}}')],
                min=0,
              ),
            ],
          },
          {
            title: 'Request sizes',
            panels: [
              g.timeseries(
                'Bytes served by pod',
                'Throughput of successful downloads per pod.',
                'Bps',
                [g.target(counter('cache_server_download_request_size_bytes_sum'), '{{pod}}')],
                min=0,
              ) { w:: 6 },
              g.timeseries(
                'Bytes written by pod',
                'Throughput of successful uploads per pod.',
                'Bps',
                [g.target(counter('cache_server_upload_request_size_bytes_sum'), '{{pod}}')],
                min=0,
              ) { w:: 6 },
              g.timeseries(
                'Average download size',
                'Mean size of successful downloads. Size buckets are coarse (100 kB, 512 kB, 1 MB, 4 MB, 16 MB), so only the average is shown per pod.',
                'bytes',
                [g.target(average('cache_server_download_request_size_bytes'), '{{pod}}')],
                min=0,
                fill=0,
              ) { w:: 6 },
              g.timeseries(
                'Average upload size',
                'Mean size of successful uploads.',
                'bytes',
                [g.target(average('cache_server_upload_request_size_bytes'), '{{pod}}')],
                min=0,
                fill=0,
              ) { w:: 6 },
              g.heatmap(
                'Download size distribution',
                'Distribution of successful download sizes across the selected pods.',
                'bytes',
                'sum by (le) (rate(cache_server_download_request_size_bytes_bucket{%s}[$__rate_interval]))' % sel,
              ),
              g.heatmap(
                'Upload size distribution',
                'Distribution of successful upload sizes across the selected pods.',
                'bytes',
                'sum by (le) (rate(cache_server_upload_request_size_bytes_bucket{%s}[$__rate_interval]))' % sel,
              ),
            ],
          },
        ],
      ),
  },
}
