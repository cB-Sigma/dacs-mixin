# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
has a first tagged release.

Because DACS is pre-release, a change in DACS metric names can force a breaking
change here. Each entry states which DACS commit the inventory was verified
against.

## [Unreleased]

Initial version. Verified against Azure/dacs commit `27ec57c` (2026-11-11).

### Added

- Metric inventory for cache servers, cache clients and the cache-controller,
  with source references (`docs/metrics.md`, `inventory/metrics.yaml`).
- Dashboards: DACS / Overview, DACS / Cache servers, DACS / Clients,
  DACS / Controller.
- Recording rules for request rates, hit ratio, error ratio, latency quantiles,
  byte rates, space used and server counts.
- Alerts for cache server availability, hit ratio, error ratio, download
  latency, accept-queue and SYN-queue saturation, `accept()` errors, capacity
  and the controller, each with a runbook.
- Opt-in rules, alert and dashboard for cache client (OTLP) metrics.
- `PodMonitor` for cache servers and `ServiceMonitor` for the controller.
- Kustomize base (`manifests/`) and Helm chart (`charts/dacs-mixin`).
- Tooling: `make render`, lint, drift check, `promtool` unit tests and the
  metric inventory guard, wired into CI.

### Known limitations

- Not yet validated against a live DACS cluster.
- Client metric names in Prometheus are derived from the OTLP translation
  rules, not observed.
- Capacity has to be supplied by the operator because DACS does not export its
  size limit.
