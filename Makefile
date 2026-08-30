.PHONY: all build rebuild build-bench test-all test-c test-python test-go bench bench-light bench-full clean

# GOEXPERIMENT=noswissmap: workaround for Go 1.24 CGo+Swiss-map runtime
# redeclaration bug (map.go vs linkname_swiss.go conflict).
export GOEXPERIMENT=noswissmap

BUILD_DIR   := build
BENCH_DIR   := $(BUILD_DIR)/src/benchmark

BUILD_INPUTS := $(shell find src test/c cmake -type f \( \
	-name '*.c' -o -name '*.h' -o -name '*.cpp' -o \
	-name '*.cmake' -o -name 'CMakeLists.txt' \))
BUILD_INPUTS += $(wildcard *.go) go.mod go.sum CMakeLists.txt Makefile build.sh \
	setup.py test/python/requirements.txt

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

# Stamp file: touched by build.sh on success to track freshness.
$(BUILD_DIR)/.built: $(BUILD_INPUTS)
	./build.sh

build: $(BUILD_DIR)/.built
	@test -n "$$(find $(BUILD_DIR)/test/c -type f \( -name Test -o -name Test.exe \) -print 2>/dev/null | head -n 1)" || { echo "Required C test binary is missing under $(BUILD_DIR)/test/c" >&2; exit 1; }

build-bench: $(BUILD_DIR)/.built
	cmake --build $(BUILD_DIR) --config Release --target Benchmark_LIGHT Benchmark_FULL

# ---------------------------------------------------------------------------
# Test targets  (each depends only on the build it actually needs)
# ---------------------------------------------------------------------------

test-c: $(BUILD_DIR)/.built
	./test/c/test.sh

test-python:
	./test/python/test.sh

test-go: $(BUILD_DIR)/.built
	GOEXPERIMENT=noswissmap go test -timeout 9999s

test-all: $(BUILD_DIR)/.built
	./test/test.sh

# ---------------------------------------------------------------------------
# Benchmark targets
# ---------------------------------------------------------------------------

bench-light: build-bench
	@BENCH_BIN="$$(find "$(abspath $(BENCH_DIR))" -type f \( -name Benchmark_LIGHT -o -name Benchmark_LIGHT.exe \) -path '*/Release/*' -print -quit)"; \
	[ -n "$$BENCH_BIN" ] || BENCH_BIN="$$(find "$(abspath $(BENCH_DIR))" -type f \( -name Benchmark_LIGHT -o -name Benchmark_LIGHT.exe \) -print -quit)"; \
	[ -n "$$BENCH_BIN" ] || { echo "Benchmark_LIGHT is missing under $(BENCH_DIR)" >&2; exit 1; }; \
	cd $(BUILD_DIR) && "$$BENCH_BIN"

bench-full: build-bench
	@BENCH_BIN="$$(find "$(abspath $(BENCH_DIR))" -type f \( -name Benchmark_FULL -o -name Benchmark_FULL.exe \) -path '*/Release/*' -print -quit)"; \
	[ -n "$$BENCH_BIN" ] || BENCH_BIN="$$(find "$(abspath $(BENCH_DIR))" -type f \( -name Benchmark_FULL -o -name Benchmark_FULL.exe \) -print -quit)"; \
	[ -n "$$BENCH_BIN" ] || { echo "Benchmark_FULL is missing under $(BENCH_DIR)" >&2; exit 1; }; \
	cd $(BUILD_DIR) && "$$BENCH_BIN"

bench: bench-light bench-full

# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------

all: test-all bench

rebuild: clean build

clean:
	rm -rf \
		$(BUILD_DIR)/ \
		test/c/build/ \
		test/python/python-virtual-env/ \
		test/python/*.pyc \
		*.so \
		pyethash.so \
		pyethash.egg-info/ \
		dist/ \
		MANIFEST
