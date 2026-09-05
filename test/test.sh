#!/bin/bash
# Master test runner: build first, then run all test suites.
set -e

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
TEST_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
REPO_ROOT="$( cd "$TEST_DIR/.." && pwd )"
BUILD_DIR="$REPO_ROOT/build"

# Use the .built stamp (touched by build.sh on success) as the build indicator.
# Checking the stamp is more reliable than checking individual binaries because
# it reflects a complete, successful build rather than a partial one.
if [ ! -f "$BUILD_DIR/.built" ]; then
    echo "[test] Build stamp missing — running build.sh first"
    "$REPO_ROOT/build.sh"
fi

echo -e "\n################# Testing JS ##################"
cd "$REPO_ROOT/js"
if [ -x "$(which nodejs)" ]; then nodejs test.js; fi
if [ -x "$(which node)" ];   then node test.js;    fi

echo -e "\n################# Testing C ##################"
"$TEST_DIR/c/test.sh"

echo -e "\n################# Testing Python ##################"
"$TEST_DIR/python/test.sh"

echo -e "\n################# Testing Go ##################"
cd "$REPO_ROOT"
go test -timeout 9999s

echo -e "\n################# All tests passed ##################"
