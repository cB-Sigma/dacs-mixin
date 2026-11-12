{
  local c = $._config,
  local runbook(name) = c.runbookURLPattern % name,

  prometheusAlerts+:: {
    groups+: [
      {
        name: 'dacs-cache-availability',
        rules: [
          {
            alert: 'DacsCacheServerDown',
            expr: |||
              up{%(cacheServerSelector)s} == 0
            ||| % c,
            'for': c.cacheServerDownFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache server metrics endpoint is down.',
              description: 'Prometheus cannot scrape cache server {{ $labels.pod }} of cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }}. Keys that hash to this server are being read from Blob Storage instead of the cache.' % c,
              runbook_url: runbook('DacsCacheServerDown'),
            },
          },
          {
            alert: 'DacsCacheServersNotReady',
            expr: |||
              dacs:cache:servers_ready < dacs:cache:servers_desired
            |||,
            'for': c.cacheServersNotReadyFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache has fewer ready servers than desired.',
              description: 'Cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }} has {{ $value }} ready cache server pods, fewer than its StatefulSet asks for. Clients still address the full server list, so keys owned by the missing servers miss the cache.' % c,
              runbook_url: runbook('DacsCacheServersNotReady'),
            },
          },
          {
            alert: 'DacsCacheNoReadyServers',
            expr: |||
              dacs:cache:servers_ready == 0 and dacs:cache:servers_desired > 0
            |||,
            'for': c.cacheNoReadyServersFor,
            labels: { severity: 'critical' },
            annotations: {
              summary: 'DACS cache has no ready servers.',
              description: 'Cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }} has zero ready cache server pods. Every read falls through to Blob Storage and discovery requests fail.' % c,
              runbook_url: runbook('DacsCacheNoReadyServers'),
            },
          },
        ],
      },
      {
        name: 'dacs-cache-traffic',
        rules: [
          {
            alert: 'DacsCacheHitRatioLow',
            expr: |||
              dacs:cache:download_hit_ratio_rate5m < %(hitRatioLowThreshold)g
              and on (namespace, %(cacheLabel)s)
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type="Download"}) > %(hitRatioLowMinDownloadRate)g
            ||| % c,
            'for': c.hitRatioLowFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache hit ratio is low.',
              description: 'Only {{ $value | humanizePercentage }} of download requests to cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }} were hits over the last 5 minutes. Expected while a cache warms up; sustained, it means workloads are mostly reading from Blob Storage.' % c,
              runbook_url: runbook('DacsCacheHitRatioLow'),
            },
          },
          {
            alert: 'DacsCacheErrorRatioHigh',
            expr: |||
              dacs:cache:error_ratio_rate5m > %(errorRatioWarningThreshold)g
              and on (namespace, %(cacheLabel)s)
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type!~"%(ignoredRequestTypes)s"}) > %(errorRatioMinRequestRate)g
            ||| % c,
            'for': c.errorRatioWarningFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache servers are returning errors.',
              description: '{{ $value | humanizePercentage }} of requests to cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }} ended in an error status (%(errorStatuses)s).' % c,
              runbook_url: runbook('DacsCacheErrorRatioHigh'),
            },
          },
          {
            alert: 'DacsCacheErrorRatioCritical',
            expr: |||
              dacs:cache:error_ratio_rate5m > %(errorRatioCriticalThreshold)g
              and on (namespace, %(cacheLabel)s)
              sum by (namespace, %(cacheLabel)s) (dacs:cache:request_rate5m{request_type!~"%(ignoredRequestTypes)s"}) > %(errorRatioMinRequestRate)g
            ||| % c,
            'for': c.errorRatioCriticalFor,
            labels: { severity: 'critical' },
            annotations: {
              summary: 'DACS cache servers are failing a large share of requests.',
              description: '{{ $value | humanizePercentage }} of requests to cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }} ended in an error status (%(errorStatuses)s).' % c,
              runbook_url: runbook('DacsCacheErrorRatioHigh'),
            },
          },
          {
            alert: 'DacsCacheDownloadLatencyHigh',
            expr: |||
              dacs:cache:request_latency_ms:p99_rate5m{request_type="Download"} > %(downloadLatencyP99ThresholdMs)g
            ||| % c,
            'for': c.downloadLatencyFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache download latency is high.',
              description: 'p99 latency of successful downloads from cache {{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }} is {{ $value | printf "%%.0f" }}ms (threshold %(downloadLatencyP99ThresholdMs)gms).' % c,
              runbook_url: runbook('DacsCacheDownloadLatencyHigh'),
            },
          },
        ],
      },
      {
        name: 'dacs-cache-saturation',
        rules: [
          {
            alert: 'DacsCacheServerAcceptQueueOverflow',
            expr: |||
              sum by (namespace, %(cacheLabel)s, pod) (
                rate(cache_server_accept_queue_overflows_total{%(cacheServerSelector)s}[5m])
              ) > 0
            ||| % c,
            'for': c.acceptQueueOverflowFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache server accept queue is overflowing.',
              description: 'Cache server {{ $labels.pod }} ({{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }}) is overflowing its TCP accept queue ({{ $value | printf "%%.2f" }}/s). New client connections are being dropped or delayed.' % c,
              runbook_url: runbook('DacsCacheServerAcceptQueueOverflow'),
            },
          },
          {
            alert: 'DacsCacheServerListenDrops',
            expr: |||
              sum by (namespace, %(cacheLabel)s, pod) (
                rate(cache_server_listen_drops_total{%(cacheServerSelector)s}[5m])
              ) > %(listenDropsPerSecondThreshold)g
            ||| % c,
            'for': c.listenDropsFor,
            labels: { severity: 'critical' },
            annotations: {
              summary: 'DACS cache server is dropping incoming connections.',
              description: 'Cache server {{ $labels.pod }} ({{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }}) is dropping {{ $value | printf "%%.2f" }} connection attempts per second at the listen socket.' % c,
              runbook_url: runbook('DacsCacheServerListenDrops'),
            },
          },
          {
            alert: 'DacsCacheServerSynQueueDrops',
            expr: |||
              sum by (namespace, %(cacheLabel)s, pod) (
                rate(cache_server_syn_queue_full_drops_total{%(cacheServerSelector)s}[5m])
              ) > 0
            ||| % c,
            'for': c.synQueueDropsFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache server SYN queue is full.',
              description: 'Cache server {{ $labels.pod }} ({{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }}) is dropping SYNs because its request queue is full ({{ $value | printf "%%.2f" }}/s).' % c,
              runbook_url: runbook('DacsCacheServerSynQueueDrops'),
            },
          },
          {
            alert: 'DacsCacheServerAcceptErrors',
            expr: |||
              sum by (namespace, %(cacheLabel)s, pod, errno) (
                rate(cache_server_accept_errors_total{%(cacheServerSelector)s}[5m])
              ) > 0
            ||| % c,
            'for': c.acceptErrorsFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache server accept() calls are failing.',
              description: 'accept() on cache server {{ $labels.pod }} ({{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }}) is failing with errno {{ $labels.errno }}.' % c,
              runbook_url: runbook('DacsCacheServerAcceptErrors'),
            },
          },
          {
            // Inert until dacs:cache_server:capacity_bytes exists, see docs/capacity.md.
            alert: 'DacsCacheServerNearCapacity',
            expr: |||
              cache_server_cache_size_bytes{%(cacheServerSelector)s}
              / on (namespace, %(cacheLabel)s) group_left ()
              dacs:cache_server:capacity_bytes
              > %(nearCapacityThreshold)g
            ||| % c,
            'for': c.nearCapacityFor,
            labels: { severity: 'warning' },
            annotations: {
              summary: 'DACS cache server is close to its size limit.',
              description: 'Cache server {{ $labels.pod }} ({{ $labels.namespace }}/{{ $labels.%(cacheLabel)s }}) is using {{ $value | humanizePercentage }} of its configured size. Eviction should keep usage below its size threshold; staying above it means eviction is disabled or cannot keep up.' % c,
              runbook_url: runbook('DacsCacheServerNearCapacity'),
            },
          },
        ],
      },
    ],
  },
}
