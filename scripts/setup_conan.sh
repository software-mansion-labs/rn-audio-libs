#!/usr/bin/env bash
# Creates the repo-local Python venv with the pinned Conan and configures CONAN_HOME=.conan2:
# global.conf and the default (build) profile. Recipes come from ConanCenter; conan.lock pins
# their versions and revisions.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/conan_env.sh"
cd "$ROOT_DIR"

MIN_PYTHON="3.10"
PYTHON="${PYTHON:-python3}"

if ! "$PYTHON" -c "import sys; sys.exit(sys.version_info < tuple(map(int, '$MIN_PYTHON'.split('.'))))"; then
    echo "Error: Python >= $MIN_PYTHON required, found $("$PYTHON" --version 2>&1) ($(command -v "$PYTHON"))" >&2
    echo "With pyenv: pyenv install \$(cat .python-version)" >&2
    exit 1
fi

if [ ! -x .venv/bin/python ]; then
    "$PYTHON" -m venv .venv
fi
.venv/bin/python -m pip install --quiet --require-hashes --no-deps -r requirements.txt

conan --version
conan config install conan/config
# The build profile describes this Mac. Detect Xcode's clang explicitly: a Homebrew LLVM earlier
# on PATH would otherwise be detected as compiler=clang.
CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" conan profile detect --force
conan remote enable conancenter
conan profile show -pr:b default --context=build | sed -n "/\[settings\]/,/^$/p"
