#!/usr/bin/env bash
# Builds dashboard-linter and mixtool from source into BIN_DIR.
#
# Both modules carry replace directives in go.mod, so `go install pkg@version`
# refuses them; they have to be built from a checkout.
set -euo pipefail

: "${BIN_DIR:?BIN_DIR must be set}"
: "${DASHBOARD_LINTER_VERSION:?DASHBOARD_LINTER_VERSION must be set}"
: "${MIXTOOL_COMMIT:?MIXTOOL_COMMIT must be set}"

mkdir -p "$BIN_DIR"
workdir="$(mktemp -d)"
cleanup() { rm -rf -- "$workdir"; }
trap cleanup EXIT

git clone --quiet --depth 1 --branch "$DASHBOARD_LINTER_VERSION" \
  https://github.com/grafana/dashboard-linter.git "$workdir/dashboard-linter"
(cd "$workdir/dashboard-linter" && go build -o "$BIN_DIR/dashboard-linter" .)

git clone --quiet https://github.com/monitoring-mixins/mixtool.git "$workdir/mixtool"
(cd "$workdir/mixtool" && git checkout --quiet "$MIXTOOL_COMMIT" && go build -o "$BIN_DIR/mixtool" ./cmd/mixtool)

echo "installed dashboard-linter and mixtool into $BIN_DIR"
