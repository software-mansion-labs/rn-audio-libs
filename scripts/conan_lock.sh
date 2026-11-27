#!/usr/bin/env bash
# Regenerates conan.lock from configs.json and conan/recipes for every profile in conan/profiles.
# One lockfile covers all targets, so a build can only use the pinned versions and recipe revisions.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/conan_env.sh"
cd "$ROOT_DIR"
source scripts/conan_profiles.sh

echo '{"version": "0.5"}' >conan.lock
for profile in "${CONAN_PROFILES[@]}"; do
    conan lock create . -pr:h "conan/profiles/$profile" -pr:b default \
        --lockfile-partial --lockfile conan.lock --lockfile-out conan.lock "$@"
done
echo "Wrote conan.lock:"
python3 -c "import json; l=json.load(open('conan.lock')); [print(' ', r) for k in ('requires','build_requires') for r in l[k]]"
