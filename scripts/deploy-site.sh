#!/usr/bin/env bash
# Deploys site/ to the Cloudflare Pages project com-glecimal, which serves
# https://glecimal.com. The page has no build step: site/ is uploaded as is.
#
# It runs as whoever is logged in to wrangler (`wrangler login`); no
# credential lives in this repository. The project was created once with
# `wrangler pages project create com-glecimal --production-branch main`, and
# glecimal.com is attached to it as a custom domain.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I scripts/check-site.py
pnpm dlx wrangler@4.123.0 pages deploy site \
  --project-name com-glecimal --branch main --commit-dirty=true
