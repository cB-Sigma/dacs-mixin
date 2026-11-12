#!/usr/bin/env bash
# Fails when the committed rendered files differ from what the jsonnet
# sources produce, or when a rendered directory contains a stale file.
set -euo pipefail

cd "$(dirname "$0")/.."
JSONNET="${JSONNET:-jsonnet}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$JSONNET" -J . -S -c -m "$tmp" lib/render.jsonnet > /dev/null

status=0
while IFS= read -r -d '' file; do
  rel="${file#"$tmp"/}"
  if [ ! -f "$rel" ]; then
    echo "drift: $rel is missing; run 'make render'" >&2
    status=1
  elif ! diff -u "$rel" "$file" > /dev/null; then
    echo "drift: $rel is out of date; run 'make render'" >&2
    diff -u "$rel" "$file" | head -n 20 >&2 || true
    status=1
  fi
done < <(find "$tmp" -type f -print0)

# Directories that contain nothing but rendered files.
for dir in dashboards_out rules_out charts/dacs-mixin/files/dashboards charts/dacs-mixin/files/rules; do
  while IFS= read -r -d '' file; do
    if [ ! -f "$tmp/$file" ]; then
      echo "drift: $file is not produced by lib/render.jsonnet; delete it" >&2
      status=1
    fi
  done < <(find "$dir" -type f -print0)
done

if [ "$status" -eq 0 ]; then
  echo "rendered files are in sync with the jsonnet sources ($(find "$tmp" -type f | wc -l) files)"
fi
exit "$status"
