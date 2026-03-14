#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
schema_dir="$repo_root/schema/cdp"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fetch() {
  local url="$1"
  local output="$2"

  curl --fail --location --silent --show-error \
    "$url" \
    --output "$output"
}

mkdir -p "$schema_dir"

fetch \
  "https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json" \
  "$tmp_dir/browser_protocol.json"
fetch \
  "https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/js_protocol.json" \
  "$tmp_dir/js_protocol.json"

mv "$tmp_dir/browser_protocol.json" "$schema_dir/browser_protocol.json"
mv "$tmp_dir/js_protocol.json" "$schema_dir/js_protocol.json"

printf 'Updated CDP schema in %s\n' "$schema_dir"
