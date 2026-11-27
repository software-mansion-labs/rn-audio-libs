# Sourced by the Conan scripts: puts the repo-local venv on PATH and keeps Conan's cache,
# profiles and remotes inside the repository instead of ~/.conan2.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CONAN_HOME="$ROOT_DIR/.conan2"
export PATH="$ROOT_DIR/.venv/bin:$PATH"
