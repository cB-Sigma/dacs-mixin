{
  _config+:: {
    // ---------------------------------------------------------------------
    // Selectors. These must match the labels your scrape configuration
    // attaches. The defaults match the PodMonitor / ServiceMonitor shipped
    // in manifests/ and in the Helm chart.
    // ---------------------------------------------------------------------

    // Cache server pods (prometheus-cpp exposer, port "metrics", /metrics).
    cacheServerSelector: 'job="dacs-cache-server"',
    // cache-controller manager (controller-runtime metrics server).
    controllerSelector: 'job="dacs-controller"',
    // kube-state-metrics, used only for StatefulSet desired/ready replicas.
    kubeStateMetricsSelector: 'job="kube-state-metrics"',
    // Extra matchers applied to cache client (OTLP-pushed) series. Empty by
    // default because the label set depends entirely on your OTel pipeline.
    clientSelector: '',

    // Target label that carries the Cache name. The shipped PodMonitor
    // derives it from the pod label dacs.azure.com/cache-name.
    cacheLabel: 'cache',
    // Label that identifies a client workload. With the standard
    // OTLP -> Prometheus translation, service.name becomes `job`.
    clientWorkloadLabel: 'job',

    // Name passed to .Named() by the Cache reconciler.
    controllerName: 'cache',

    // ---------------------------------------------------------------------
    // Cache client metrics (opt-in, pipeline dependent). See
    // docs/client-metrics.md before changing these.
    // ---------------------------------------------------------------------

    // Suffix the OTLP -> Prometheus translation appends to monotonic sums.
    // Use '' if your collector runs with add_metric_suffixes: false.
    clientCounterSuffix: '_total',
    // The client exports every 5 minutes by default, so short windows
    // return nothing. Keep this at >= 3x the export interval.
    clientRateInterval: '15m',

    // ---------------------------------------------------------------------
    // Semantics of the cache server `status` label.
    // ---------------------------------------------------------------------

    // Statuses counted as errors. InvalidTransition is deliberately absent:
    // on Download it means "cache miss", on Upload it means "already cached".
    errorStatuses: 'BadRequest|InternalError|NetworkError|NotSet',
    // request_type="Unknown" is recorded when a connection is dropped before
    // a request could be parsed. It is excluded from the error ratio.
    ignoredRequestTypes: 'Unknown',

    // ---------------------------------------------------------------------
    // Alert thresholds.
    // ---------------------------------------------------------------------

    cacheServerDownFor: '5m',
    cacheServersNotReadyFor: '15m',
    cacheNoReadyServersFor: '5m',
    // How long a cache keeps being tracked for replica alerts after its last
    // successful service discovery.
    cacheDiscoveryLookback: '1h',

    hitRatioLowThreshold: 0.5,
    hitRatioLowMinDownloadRate: 1,  // downloads/s, below this the alert is silent
    hitRatioLowFor: '30m',

    errorRatioWarningThreshold: 0.05,
    errorRatioCriticalThreshold: 0.25,
    errorRatioMinRequestRate: 0.1,  // requests/s
    errorRatioWarningFor: '10m',
    errorRatioCriticalFor: '5m',

    downloadLatencyP99ThresholdMs: 1000,
    downloadLatencyFor: '15m',

    acceptQueueOverflowFor: '10m',
    listenDropsPerSecondThreshold: 1,
    listenDropsFor: '10m',
    synQueueDropsFor: '10m',
    acceptErrorsFor: '5m',

    // Fraction of the configured per-server size. Eviction starts at 90% by
    // default, so sitting above 95% means eviction is off or not keeping up.
    nearCapacityThreshold: 0.95,
    nearCapacityFor: '30m',

    controllerDownFor: '10m',
    controllerReconcileErrorRatioThreshold: 0.1,
    controllerReconcileErrorsFor: '15m',
    controllerWorkqueueStalledSeconds: 600,
    controllerWorkqueueStalledFor: '5m',

    clientDnsErrorsFor: '15m',

    // ---------------------------------------------------------------------
    // Capacity. DACS does not export the per-server size limit
    // (spec.serverSizeInGB), so it has to be supplied. Each entry becomes a
    // static dacs:cache_server:capacity_bytes series. Example:
    //   cacheCapacities: [
    //     { namespace: 'cache-server', cache: 'cache-sample', serverSizeBytes: 100 * 1024 * 1024 * 1024 },
    //   ],
    // ---------------------------------------------------------------------
    cacheCapacities: [],

    // ---------------------------------------------------------------------
    // Presentation.
    // ---------------------------------------------------------------------

    runbookURLPattern: 'https://github.com/cb-Sigma/dacs-mixin/blob/main/docs/runbooks/%s.md',

    dashboardTags: ['dacs'],
    dashboardRefresh: '1m',
    dashboardTimeFrom: 'now-3h',
    dashboardUIDs: {
      overview: 'dacs-overview',
      servers: 'dacs-cache-servers',
      clients: 'dacs-clients',
      controller: 'dacs-controller',
    },
  },
}
