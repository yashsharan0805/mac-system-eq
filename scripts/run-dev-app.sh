#!/usr/bin/env bash
set -euo pipefail

prepare_only=0
if [[ "${1:-}" == "--prepare-only" ]]; then
  prepare_only=1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product_name="MacSystemEQApp"
app_name="MacSystemEQ.app"
exec_name="MacSystemEQ"
app_bundle_dir="$root_dir/.dev-app/$app_name"
contents_dir="$app_bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"
info_src="$root_dir/apps/MacSystemEQApp/Config/Info.plist"
info_dst="$contents_dir/Info.plist"

echo "Building $product_name..."
swift build --package-path "$root_dir" --product "$product_name"

bin_dir="$(swift build --package-path "$root_dir" --show-bin-path)"
bin_path="$bin_dir/$product_name"

if [[ ! -x "$bin_path" ]]; then
  echo "Expected executable not found at: $bin_path"
  exit 1
fi

mkdir -p "$macos_dir" "$contents_dir/Resources"
cp "$bin_path" "$macos_dir/$exec_name"
cp "$info_src" "$info_dst"

plist_tool="/usr/libexec/PlistBuddy"

set_plist_value() {
  local key="$1"
  local type="$2"
  local value="$3"
  if "$plist_tool" -c "Set :$key $value" "$info_dst" >/dev/null 2>&1; then
    return
  fi
  "$plist_tool" -c "Add :$key $type $value" "$info_dst"
}

set_plist_value "CFBundleExecutable" "string" "$exec_name"
set_plist_value "CFBundlePackageType" "string" "APPL"
set_plist_value "CFBundleShortVersionString" "string" "0.1.0"
set_plist_value "CFBundleVersion" "string" "1"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$app_bundle_dir" >/dev/null
fi

bundle_id="$(defaults read "$info_dst" CFBundleIdentifier)"

if [[ "$prepare_only" -eq 1 ]]; then
  echo "Prepared $app_bundle_dir"
  echo "Bundle identifier: $bundle_id"
  exit 0
fi

echo "Launching $app_bundle_dir"
open "$app_bundle_dir"
echo "Bundle identifier: $bundle_id"
