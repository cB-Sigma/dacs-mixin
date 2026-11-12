## What does this change?

<!-- A sentence or two. Link the issue if there is one. -->

## How was it tested?

<!-- `make all` output, a real cluster (which DACS version?), screenshots. -->

## Checklist

- [ ] I changed the jsonnet sources, not the generated files, and ran `make fmt render`
- [ ] `make all` passes (and `make lint-extra` if dashboards, the chart or manifests changed)
- [ ] New or changed queries only use metrics listed in `inventory/metrics.yaml`
- [ ] New metrics in the inventory have a source reference and are documented in `docs/metrics.md`
- [ ] New or changed alerts have unit tests in `tests/alerts_test.yaml` and a runbook
- [ ] `CHANGELOG.md` is updated
