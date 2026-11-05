#!/bin/bash
# Renders marketing/ad.html to site/ads/: og.png (link previews, 1200x630),
# square.png (1080x1080 posts) and story.png (1080x1920 stories). Needs Google Chrome.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p "$root/site/ads"

render() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --virtual-time-budget=3000 --window-size="$2" \
    --screenshot="$root/site/ads/$1.png" "file://$root/marketing/ad.html?f=$1" >/dev/null 2>&1
  echo "site/ads/$1.png ($2)"
}

render og 1200,630
render square 1080,1080
render story 1080,1920
