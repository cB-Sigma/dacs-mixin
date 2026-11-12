# dacs-mixin build, lint and test targets.
#
# Tools are looked up in BIN_DIR first and on PATH second. `make tools`
# installs them into BIN_DIR, which is git-ignored by default; point it
# somewhere else to keep binaries out of the checkout entirely:
#
#   make tools BIN_DIR=$HOME/.local/share/dacs-mixin/bin
#   make all   BIN_DIR=$HOME/.local/share/dacs-mixin/bin

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

BIN_DIR ?= $(CURDIR)/.bin
export PATH := $(BIN_DIR):$(PATH)
export PYTHONDONTWRITEBYTECODE := 1

# Go toolchain used to build the tools.
export GOTOOLCHAIN ?= go1.27.4

JSONNET_VERSION          ?= v0.22.0
PROMTOOL_VERSION         ?= v0.316.0
HELM_VERSION             ?= v3.22.1
KUSTOMIZE_VERSION        ?= v5.8.3
KUBECONFORM_VERSION      ?= v0.8.0
DASHBOARD_LINTER_VERSION ?= v0.5.2
MIXTOOL_COMMIT           ?= 5d4358f07f2b4d58d88b54c9eb3e7f68b62fa219

JSONNET_FILES := $(shell find . -name vendor -prune -o -name .bin -prune -o \( -name '*.libsonnet' -o -name '*.jsonnet' \) -print)
RULE_FILES    := rules_out/prometheus_rules.yaml rules_out/prometheus_alerts.yaml \
                 rules_out/prometheus_client_rules.yaml rules_out/prometheus_client_alerts.yaml
PYTHON        ?= python3

# Prometheus Operator CRD schemas come from the community CRD catalog.
KUBECONFORM_FLAGS := -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

.PHONY: tools
tools: ## Install jsonnet, jsonnetfmt, jsonnet-lint and promtool into BIN_DIR.
	mkdir -p $(BIN_DIR)
	GOBIN=$(BIN_DIR) go install github.com/google/go-jsonnet/cmd/jsonnet@$(JSONNET_VERSION)
	GOBIN=$(BIN_DIR) go install github.com/google/go-jsonnet/cmd/jsonnetfmt@$(JSONNET_VERSION)
	GOBIN=$(BIN_DIR) go install github.com/google/go-jsonnet/cmd/jsonnet-lint@$(JSONNET_VERSION)
	GOBIN=$(BIN_DIR) go install github.com/prometheus/prometheus/cmd/promtool@$(PROMTOOL_VERSION)

.PHONY: tools-extra
tools-extra: ## Install helm, kustomize, kubeconform, dashboard-linter and mixtool into BIN_DIR.
	mkdir -p $(BIN_DIR)
	GOBIN=$(BIN_DIR) go install helm.sh/helm/v3/cmd/helm@$(HELM_VERSION)
	GOBIN=$(BIN_DIR) go install sigs.k8s.io/kustomize/kustomize/v5@$(KUSTOMIZE_VERSION)
	GOBIN=$(BIN_DIR) go install github.com/yannh/kubeconform/cmd/kubeconform@$(KUBECONFORM_VERSION)
	BIN_DIR=$(BIN_DIR) DASHBOARD_LINTER_VERSION=$(DASHBOARD_LINTER_VERSION) MIXTOOL_COMMIT=$(MIXTOOL_COMMIT) scripts/install_source_tools.sh

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

.PHONY: render
render: ## Render dashboards, rules, manifests and Helm chart files from jsonnet.
	jsonnet -J . -S -c -m . lib/render.jsonnet > /dev/null
	@echo "rendered dashboards_out/, rules_out/, manifests/ and charts/dacs-mixin/files/"

.PHONY: fmt
fmt: ## Format jsonnet sources in place.
	jsonnetfmt -i $(JSONNET_FILES)

.PHONY: drift
drift: ## Fail if rendered files are out of sync with the jsonnet sources.
	scripts/check_drift.sh

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------

.PHONY: lint
lint: lint-jsonnet lint-rules lint-dashboard-queries ## Run every lint that needs only jsonnet and promtool.

.PHONY: lint-jsonnet
lint-jsonnet: ## jsonnetfmt --test and jsonnet-lint.
	jsonnetfmt --test $(JSONNET_FILES)
	jsonnet-lint -J . mixin.libsonnet lib/render.jsonnet

.PHONY: lint-rules
lint-rules: ## promtool check rules on every rule file.
	promtool check rules --lint=all --lint-fatal $(RULE_FILES)

.PHONY: lint-dashboard-queries
lint-dashboard-queries: ## Parse every dashboard query with promtool.
	$(PYTHON) scripts/dashboard_queries.py | promtool check rules

.PHONY: lint-dashboards
lint-dashboards: ## grafana/dashboard-linter in strict mode (needs tools-extra).
	for f in dashboards_out/*.json; do dashboard-linter lint --strict -c .dashboard-lint.yaml $$f > /dev/null || { dashboard-linter lint --strict -c .dashboard-lint.yaml $$f; exit 1; }; done
	@echo "dashboard-linter: OK"

.PHONY: lint-helm
lint-helm: ## helm lint, then render the chart with every toggle and compare (needs tools-extra).
	helm lint --strict charts/dacs-mixin
	helm lint --strict charts/dacs-mixin -f charts/dacs-mixin/ci/all-values.yaml
	$(PYTHON) scripts/check_chart.py

.PHONY: lint-manifests
lint-manifests: ## kustomize build, then validate manifests and chart output against CRD schemas (needs tools-extra, network).
	kustomize build manifests | kubeconform $(KUBECONFORM_FLAGS)
	kustomize build manifests/client | kubeconform $(KUBECONFORM_FLAGS)
	kubeconform $(KUBECONFORM_FLAGS) manifests/examples
	helm template dacs-mixin charts/dacs-mixin -f charts/dacs-mixin/ci/all-values.yaml | kubeconform $(KUBECONFORM_FLAGS)

.PHONY: lint-mixtool
lint-mixtool: ## Check that `mixtool generate all` reproduces the rendered files (needs tools-extra).
	$(PYTHON) scripts/check_mixtool.py

.PHONY: lint-extra
lint-extra: lint-dashboards lint-helm lint-manifests lint-mixtool ## Every lint that needs tools-extra.

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

.PHONY: test
test: test-rules test-inventory test-repo test-unit ## Run every test.

.PHONY: test-rules
test-rules: ## promtool unit tests for alerts and recording rules.
	promtool test rules tests/alerts_test.yaml

.PHONY: test-inventory
test-inventory: ## Check every metric, label and label value against inventory/metrics.yaml.
	$(PYTHON) scripts/check_metrics.py

.PHONY: test-repo
test-repo: ## JSON/YAML validity, alert annotations, runbooks, dashboard hygiene, docs.
	$(PYTHON) scripts/check_repo.py

.PHONY: test-unit
test-unit: ## Unit tests for the check scripts.
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py'

.PHONY: all
all: render lint test drift ## Render, lint, test and check for drift.

.PHONY: ci
ci: lint test drift ## What the main CI job runs; the second job runs lint-extra.
