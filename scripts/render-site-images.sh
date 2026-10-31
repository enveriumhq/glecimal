#!/usr/bin/env bash
# Renders site/og.png and site/apple-touch-icon.png from their HTML sources
# with headless Chrome. Run after changing scripts/og-card.html or
# scripts/touch-icon.html, and commit the images.
set -euo pipefail
cd "$(dirname "$0")/.."
chrome="${CHROME:-google-chrome}"
render() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --window-size="$2" --screenshot="$3" "file://$PWD/$1" >/dev/null 2>&1
}
render scripts/og-card.html 1200,630 site/og.png
render scripts/touch-icon.html 180,180 site/apple-touch-icon.png
