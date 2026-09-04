#!/bin/bash
# Run C++ unit tests.  Builds via the root build.sh if no binary exists yet.
set -e

VALGRIND_ARGS="--tool=memcheck"
VALGRIND_ARGS+=" --leak-check=yes"
VALGRIND_ARGS+=" --track-origins=yes"
VALGRIND_ARGS+=" --show-reachable=yes"
VALGRIND_ARGS+=" --num-callers=20"
VALGRIND_ARGS+=" --track-fds=yes"

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
TEST_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
REPO_ROOT="$( cd "$TEST_DIR/../.." && pwd )"
BUILD_DIR="$REPO_ROOT/build"
TEST_BIN="$BUILD_DIR/test/c/Test"

# Use the .built stamp as the build indicator (consistent with test/test.sh
# and the Makefile).  Falls back to build.sh when run standalone.
if [ ! -f "$BUILD_DIR/.built" ]; then
    echo "[test/c] Build stamp missing — running build.sh first"
    "$REPO_ROOT/build.sh"
fi

echo "[test/c] Running $TEST_BIN"

# mmap(MAP_SHARED) on NTFS via WSL DrvFs (/mnt/d/...) does not properly flush
# dirty pages to the Windows file on munmap/msync, so tests that write a DAG
# file and immediately reopen it fail.  Run from /tmp (native Linux fs) instead.
RUN_DIR="$BUILD_DIR"
if grep -q "microsoft\|WSL" /proc/version 2>/dev/null; then
    RUN_DIR=$(mktemp -d /tmp/ethash_ctest_XXXXX)
    trap "rm -rf '$RUN_DIR'" EXIT
    echo "[test/c] WSL detected — running from native fs: $RUN_DIR"
fi

cd "$RUN_DIR"
"$TEST_BIN"

# Run under valgrind if available
if hash valgrind 2>/dev/null; then
    echo "======== Running tests under valgrind ========"
    echo "Running command: valgrind $VALGRIND_ARGS $TEST_BIN"
    valgrind $VALGRIND_ARGS "$TEST_BIN"
fi
