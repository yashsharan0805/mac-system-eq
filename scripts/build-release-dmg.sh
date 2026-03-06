#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-release-dmg.sh --version <semver> [options]

Options:
  --version <value>       Version string (for example: 0.1.0) [required]
  --build-number <value>  CFBundleVersion value [default: 1]
  --output-dir <path>     Output directory [default: ./dist]
  --sign-identity <name>  codesign identity; "-" for ad-hoc [default: -]
EOF
}

version=""
build_number="1"
output_dir=""
sign_identity="-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --build-number)
      build_number="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --sign-identity)
      sign_identity="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "--version is required"
  usage
  exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product_name="MacSystemEQApp"
app_name="MacSystemEQ.app"
exec_name="MacSystemEQ"
info_src="$root_dir/apps/MacSystemEQApp/Config/Info.plist"
entitlements="$root_dir/apps/MacSystemEQApp/Config/MacSystemEQ.entitlements"

if [[ -z "$output_dir" ]]; then
  output_dir="$root_dir/dist"
fi
mkdir -p "$output_dir"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

app_bundle_dir="$work_dir/$app_name"
contents_dir="$app_bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
info_dst="$contents_dir/Info.plist"

echo "Building release executable..."
swift build --package-path "$root_dir" -c release --product "$product_name"
bin_dir="$(swift build --package-path "$root_dir" -c release --show-bin-path)"
bin_path="$bin_dir/$product_name"

if [[ ! -x "$bin_path" ]]; then
  echo "Expected executable not found at: $bin_path"
  exit 1
fi

mkdir -p "$macos_dir" "$resources_dir"
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
set_plist_value "CFBundleShortVersionString" "string" "$version"
set_plist_value "CFBundleVersion" "string" "$build_number"

echo "Signing app bundle..."
if [[ "$sign_identity" == "-" ]]; then
  codesign --force --deep --sign - "$app_bundle_dir"
else
  codesign \
    --force \
    --deep \
    --timestamp \
    --options runtime \
    --entitlements "$entitlements" \
    --sign "$sign_identity" \
    "$app_bundle_dir"
fi

stage_dir="$work_dir/dmg-root"
mkdir -p "$stage_dir"
cp -R "$app_bundle_dir" "$stage_dir/"
ln -s /Applications "$stage_dir/Applications"

dmg_path="$output_dir/MacSystemEQ-$version.dmg"
rm -f "$dmg_path"
echo "Creating DMG..."
hdiutil create \
  -volname "MacSystemEQ $version" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$dmg_path"

if [[ "$sign_identity" != "-" ]]; then
  echo "Signing DMG..."
  codesign --force --timestamp --sign "$sign_identity" "$dmg_path"
fi

"$root_dir/scripts/make-checksum.sh" "$dmg_path" >/dev/null

echo "DMG ready: $dmg_path"
echo "SHA256: ${dmg_path}.sha256"
