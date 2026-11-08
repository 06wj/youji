#!/bin/bash
set -euo pipefail

# Build a device app for signing on the phone. No Apple account is used here.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-"$repo_root/build/unsigned-ipa"}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
staging_dir="$(mktemp -d "$output_dir/.build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

xcodebuild \
  -project "$repo_root/YouJi.xcodeproj" \
  -scheme YouJi \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$staging_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  build

app_path="$staging_dir/DerivedData/Build/Products/Release-iphoneos/YouJi.app"
test -f "$app_path/YouJi"
test ! -e "$app_path/embedded.mobileprovision"
test ! -d "$app_path/_CodeSignature"
plutil -lint "$app_path/Info.plist"
xcrun lipo "$app_path/YouJi" -verify_arch arm64

mkdir -p "$staging_dir/Payload"
ditto --norsrc --noextattr "$app_path" "$staging_dir/Payload/YouJi.app"
ditto -c -k --norsrc --noextattr --keepParent \
  "$staging_dir/Payload" "$output_dir/YouJi-unsigned.ipa"

printf 'Unsigned IPA: %s\n' "$output_dir/YouJi-unsigned.ipa"
