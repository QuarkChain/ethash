#!/bin/bash
# Build the ethash project.
#
# Usage:
#   ./build.sh          # incremental build (C + Go)
#   ./build.sh --clean  # wipe build dir first, then full rebuild
set -e

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="$REPO_ROOT/build"

# Parse flags — use a loop so order doesn't matter
DO_CLEAN=0
DO_BENCH=0
for arg in "$@"; do
    case "$arg" in
        --clean) DO_CLEAN=1 ;;
        --bench) DO_BENCH=1 ;;
        *) echo "[build] Unknown argument: $arg"; exit 1 ;;
    esac
done

if [[ "$DO_CLEAN" -eq 1 ]]; then
    echo "[build] Removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# ---------------------------------------------------------------------------
# C/C++ build (cmake → libethash.a + Test binary + Python extension)
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
# Never leave a stale success marker after a failed rebuild.
rm -f "$BUILD_DIR/.built"
cd "$BUILD_DIR"

cmake "$REPO_ROOT" -DCMAKE_BUILD_TYPE=Release > /dev/null 2>&1 || {
    # On failure re-run without redirection so the error is visible
    cmake "$REPO_ROOT" -DCMAKE_BUILD_TYPE=Release
    exit 1
}

# Touch C source files modified via WSL on an NTFS mount to work around clock
# skew that prevents make from detecting changes.
if grep -q "microsoft\|WSL" /proc/version 2>/dev/null; then
    touch "$REPO_ROOT/src/libethash/internal.c"
    touch "$REPO_ROOT/src/python/core.c"
fi

# Test is a required build artifact. Build it explicitly so a missing CMake
# target fails this script before the success stamp is written. Use CMake's
# build command so this also works with Ninja and non-Makefile generators.
cmake --build "$BUILD_DIR" --config Release --target Test

TEST_BIN="$(find "$BUILD_DIR/test/c" -type f \( -name Test -o -name Test.exe \) -print 2>/dev/null | head -n 1 || true)"
if [[ -z "$TEST_BIN" ]]; then
    echo "[build/c] Required C test binary was not generated under $BUILD_DIR/test/c" >&2
    exit 1
fi
echo "[build/c] Done — binaries in $BUILD_DIR"

# Build benchmark binaries if --bench flag is passed
if [[ "$DO_BENCH" -eq 1 ]]; then
    echo "[build/bench] Building benchmark binaries..."
    cmake --build "$BUILD_DIR" --config Release --target Benchmark_LIGHT Benchmark_FULL
    echo "[build/bench] Done — binaries in $BUILD_DIR/src/benchmark/"
fi

# ---------------------------------------------------------------------------
# Go build (CGo; compiles its own copy of the C sources via ethashc.go)
# ---------------------------------------------------------------------------
cd "$REPO_ROOT"

if [ ! -f go.mod ]; then
    echo "[build/go] go.mod not found, skipping Go build"
else
    # GOEXPERIMENT=noswissmap: workaround for Go 1.24 CGo + Swiss-map
    # runtime redeclaration bug (map.go vs linkname_swiss.go conflict).
    echo "[build/go] Building Go package..."
    GOEXPERIMENT=noswissmap go build ./...
    echo "[build/go] Done"

    # Verify the package compiles cleanly with vet as well
    echo "[build/go] Running go vet..."
    GOEXPERIMENT=noswissmap go vet ./...
    echo "[build/go] vet passed"
fi

# ---------------------------------------------------------------------------
# Python extension build (compiles src/python/core.c via pip editable install)
# ---------------------------------------------------------------------------
PYTHON_TEST_DIR="$REPO_ROOT/test/python"
VENV_DIR="$PYTHON_TEST_DIR/python-virtual-env"

echo "[build/python] Setting up venv and building pyethash extension..."
[ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install -r "$PYTHON_TEST_DIR/requirements.txt" -q
# --no-build-isolation: reuse the already-activated venv's build tools rather
# than spawning an isolated env; this also ensures the compiled extension ends
# up inside the venv so pytest can import it.
pip install -e "$REPO_ROOT" -q --no-build-isolation
deactivate
echo "[build/python] Done"

touch "$BUILD_DIR/.built"
echo "[build] All done"
