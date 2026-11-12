# Contributing to dacs-mixin

Thanks for taking the time. This project is small and young, and the most
useful contributions right now are reports from people running DACS for real.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Tell us what happened on a real cluster.** Which dashboards worked, which
  panels were empty, which alerts were noisy. Use the "Field report" issue
  template. "It all worked" is a useful report.
- **Report a metric mismatch.** If a name, label or value in
  [docs/metrics.md](docs/metrics.md) differs from what your DACS exposes, open
  an issue with the DACS commit or version and the relevant lines of
  `/metrics` output.
- **Improve a runbook** after using it in an incident.
- **Send screenshots**, see below.

## Screenshots wanted

The README has no screenshots because the dashboards have not been run against
a live cluster yet, and mock-ups would be dishonest. If you have them running:

1. Take screenshots of the dashboards with real data (dark or light theme,
   around 1600 px wide).
2. Make sure nothing sensitive is visible: storage account names, internal
   hostnames, namespaces you would rather not publish.
3. Open a pull request adding them under `docs/images/` and referencing them
   from the README, and mention the DACS version and Grafana version.

## Development setup

You need Go, Python 3 with PyYAML, make and git.

```sh
make tools         # installs jsonnet, jsonnetfmt, jsonnet-lint and promtool into ./.bin
make all           # render, lint, test, drift check
```

`make tools-extra` adds helm, kustomize, kubeconform, dashboard-linter and
mixtool for `make lint-extra`. Tools are built with the Go toolchain named in
the Makefile (`GOTOOLCHAIN`). `BIN_DIR` controls where they are installed.

## Making a change

1. Edit the jsonnet sources (`config.libsonnet`, `alerts/`, `rules/`,
   `dashboards/`, `lib/`). **Never edit generated files** (`dashboards_out/`,
   `rules_out/`, the rendered files in `manifests/` and
   `charts/dacs-mixin/files/`).
2. Run `make fmt render`.
3. Run `make all`, and `make lint-extra` if you touched dashboards, the chart
   or the manifests.
4. Commit the sources and the regenerated files together. CI fails if they are
   out of sync.

### Rules for queries

The metric inventory guard exists to keep invented metrics out, so:

- **Only use metrics that are in `inventory/metrics.yaml`.** To add one, find
  it in the DACS (or controller-runtime) source, add it to the inventory with
  its type, labels and a `file:line` source reference, and document it in
  `docs/metrics.md`. Say which DACS commit you looked at.
- **Do not alert on anything you could not verify.** Metrics with a `derived`
  status may only be used in dashboards and the opt-in client rules.
- Keep `InvalidTransition` out of error ratios; it is a cache miss.

### Adding or changing an alert

- Add the rule under `alerts/`, with a `severity` label, a `for` (unless the
  expression already covers a time window), and `summary`, `description` and
  `runbook_url` annotations. Put thresholds in `config.libsonnet`.
- Add `docs/runbooks/<AlertName>.md` and list it in
  `docs/runbooks/README.md` and in the README alert table.
- Add unit tests to `tests/alerts_test.yaml`: at least one case where the alert
  fires and one where it must not.

### Adding or changing a dashboard panel

- Every panel needs a title, a description that says what the numbers mean,
  and a unit.
- Use the `${datasource}` variable; never a fixed data source.
- Use `$__rate_interval` for rates, except on the Clients dashboard, which
  uses `$window` on purpose.

## Pull requests

- Keep them focused; one topic per pull request.
- Describe what you changed and how you tested it. If you tested against a
  real DACS cluster, say which version.
- Add a line to `CHANGELOG.md` under "Unreleased".

## Updating for a new DACS version

See [Re-verifying against a newer DACS](docs/metrics.md#re-verifying-against-a-newer-dacs).
Update the commit in `inventory/metrics.yaml`, `docs/metrics.md`, the README
and the chart annotation together.

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
