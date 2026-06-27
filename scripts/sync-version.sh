#!/usr/bin/env bash
#
# Stamps MARKETING_VERSION in project.yml with today's date.
#
# Scheme: 2.<month>.<MMDD>  e.g. 2026-06-26 -> 2.6.626, 2026-12-05 -> 2.12.1205
#   major = 2        (fixed)
#   minor = month    (no leading zero)
#   patch = MMDD      (month, then zero-padded day)
#
# Idempotent: re-running on the same day is a no-op. Wired into the Makefile
# `build-device` target so every physical-device deploy stamps the build date
# onto the Settings > About screen without anyone remembering to bump it.
#
# 10#$m forces base-10 so a leading-zero month (08, 09) isn't read as octal.
set -euo pipefail
cd "$(dirname "$0")/.."

m=$(date +%m)
d=$(date +%d)
month=$((10#$m))
new="2.${month}.${month}${d}"

current=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]*)".*/\1/')

if [ "$current" = "$new" ]; then
    echo "MARKETING_VERSION already $new (no change)"
    exit 0
fi

perl -0pi -e "s/(MARKETING_VERSION:\\s*)\"[^\"]*\"/\${1}\"$new\"/" project.yml
echo "MARKETING_VERSION: $current -> $new"
