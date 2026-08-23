#!/bin/zsh
set -euo pipefail

readonly route="${1:-}"
readonly device_id="${YOUJI_SCREENSHOT_DEVICE:-${2:-}}"
readonly valid_routes=(
  overview
  playstation
  switch
  play-calendar
  game-detail-switch
  game-detail-playstation
  game-detail-playstation-trophies
  account-sync
  insights
  plans
  ai-analysis
  ai-profile-history
  ai-chat-list
  ai-chat
  data-management
  privacy
)

if [[ -z "$route" || " ${valid_routes[*]} " != *" $route "* ]]; then
  print -u2 "用法：YOUJI_SCREENSHOT_DEVICE=<真机 UDID> scripts/capture-device-screenshot.zsh <页面>"
  print -u2 "可用页面：${valid_routes[*]}"
  exit 2
fi

if [[ -z "$device_id" ]]; then
  print -u2 "请通过 YOUJI_SCREENSHOT_DEVICE 提供 Xcode 真机 UDID。"
  exit 2
fi

readonly repo_root="${0:A:h:h}"
cd "$repo_root"

xcodebuild \
  -project YouJi.xcodeproj \
  -scheme YouJi \
  -configuration Debug \
  -destination "id=$device_id" \
  build

readonly build_settings="$(xcodebuild \
  -project YouJi.xcodeproj \
  -scheme YouJi \
  -configuration Debug \
  -destination "id=$device_id" \
  -showBuildSettings)"
readonly target_build_dir="$(print -r -- "$build_settings" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }')"
readonly wrapper_name="$(print -r -- "$build_settings" | awk -F ' = ' '/^[[:space:]]*WRAPPER_NAME = / { print $2; exit }')"
readonly app_path="$target_build_dir/$wrapper_name"

if [[ ! -d "$app_path" ]]; then
  print -u2 "没有找到真机 App：$app_path"
  exit 1
fi

xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch \
  --device "$device_id" \
  --terminate-existing \
  com.youji.playlog \
  --youji-screenshot-route "$route"

print "已在真机打开：$route"
print "保持 iPhone 解锁，在 Xcode 的 Devices and Simulators 中点击 Take Screenshot。"
print "将原始 PNG 保存为：docs/screenshots/prd/$route.png"
