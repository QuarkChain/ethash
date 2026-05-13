#!/bin/bash
# Run Python tests.  The venv and pyethash extension are built by build.sh;
# this script only activates the venv and runs pytest.
set -e

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
TEST_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
REPO_ROOT="$( cd "$TEST_DIR/../.." && pwd )"
VENV_DIR="$TEST_DIR/python-virtual-env"

# Fallback: if venv is missing (running standalone without build.sh), build now.
if [ ! -d "$VENV_DIR" ]; then
    echo "[test/python] venv not found — running build.sh first"
    "$REPO_ROOT/build.sh"
fi

source "$VENV_DIR/bin/activate"
pytest "$TEST_DIR/test_pyethash.py" -v
