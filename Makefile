.PHONY: all build rebuild build-bench test-all test-c test-python test-go bench bench-light bench-full clean

BUILD_DIR  := build
TEST_BIN   := $(BUILD_DIR)/test/c/Test
BENCH_LIGHT := $(BUILD_DIR)/src/benchmark/Benchmark_LIGHT
BENCH_FULL  := $(BUILD_DIR)/src/benchmark/Benchmark_FULL

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

# Stamp file: touched by build.sh on success to track freshness.
$(BUILD_DIR)/.built: $(shell find src -name '*.c' -o -name '*.h' -o -name '*.cpp') \
                     ethash.go ethashc.go compat.go go.mod CMakeLists.txt
	./build.sh
	@touch $(BUILD_DIR)/.built

build: $(BUILD_DIR)/.built

$(BENCH_LIGHT) $(BENCH_FULL): $(BUILD_DIR)/.built
	cd $(BUILD_DIR) && make Benchmark_LIGHT Benchmark_FULL

build-bench: $(BENCH_LIGHT) $(BENCH_FULL)

# ---------------------------------------------------------------------------
# Test targets  (each depends only on the build it actually needs)
# ---------------------------------------------------------------------------

test-c: $(BUILD_DIR)/.built
	./test/c/test.sh

test-python:
	./test/python/test.sh

test-go: $(BUILD_DIR)/.built
	go test -timeout 9999s

test-all: $(BUILD_DIR)/.built
	./test/test.sh

# ---------------------------------------------------------------------------
# Benchmark targets
# ---------------------------------------------------------------------------

bench-light: $(BENCH_LIGHT)
	cd $(BUILD_DIR) && ./src/benchmark/Benchmark_LIGHT

bench-full: $(BENCH_FULL)
	cd $(BUILD_DIR) && ./src/benchmark/Benchmark_FULL

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
