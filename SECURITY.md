# Security policy

## Scope

This repository contains monitoring configuration: Grafana dashboards,
Prometheus rules, Kubernetes manifests and a Helm chart. It ships no running
service. Security issues that are in scope include, for example:

- a manifest or chart template that grants more access than it needs, or that
  weakens the security of the cluster it is installed in;
- a dashboard or rule that leaks sensitive label values in a way an operator
  would not expect;
- a problem in the build and CI tooling that could compromise a contributor or
  the published artifacts.

Vulnerabilities in DACS itself are out of scope here. Report those through the
process described in the [DACS repository](https://github.com/Azure/dacs/security).

One default deserves a mention: the controller `ServiceMonitor` uses
`insecureSkipVerify: true`, because the DACS controller serves metrics with a
self-signed certificate unless cert-manager is enabled. If you run DACS with
cert-manager, configure proper verification (see `monitors.controller.tlsConfig`
in the Helm chart values).

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
reporting instead:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability**.

Include what you found, how to reproduce it and what you think the impact is.
You should get an acknowledgement within a week. This is a volunteer-run
project, so please allow reasonable time for a fix before disclosing publicly.

## Supported versions

Only the latest state of the `main` branch is supported until the project has
tagged releases.
