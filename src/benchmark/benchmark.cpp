/*
  This file is part of cpp-ethereum.

  cpp-ethereum is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  cpp-ethereum is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with cpp-ethereum.  If not, see <http://www.gnu.org/licenses/>.
*/
/**
 * @file benchmark.cpp
 * Updated to use the current ethash API (ethash_light_new / ethash_light_compute /
 * ethash_full_new / ethash_full_compute).
 *
 * Build targets (via cmake from repo root build dir):
 *   make Benchmark_LIGHT   — light-client mode  (~1K hashes, reports Kh/s)
 *   make Benchmark_FULL    — full-DAG mode      (~128K hashes, reports Mh/s)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <chrono>
#include <libethash/ethash.h>
#include <libethash/util.h>

using std::chrono::high_resolution_clock;
using std::chrono::duration_cast;
using std::chrono::microseconds;
using std::chrono::milliseconds;

// Trial counts — same as original
#ifdef FULL
static const unsigned TRIALS = 1024 * 1024 / 8;
#else
static const unsigned TRIALS = 1024 * 1024 / 1024;
#endif

// Block number used for benchmarking (epoch 0)
static const uint64_t BLOCK_NUMBER = 0;

// Fixed header hash for reproducible results
static ethash_h256_t make_header_hash()
{
    ethash_h256_t h;
    memset(&h, 0, sizeof(h));
    // use a known non-zero pattern
    const char* hex = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
    for (int i = 0; i < 32; ++i) {
        unsigned byte;
        sscanf(hex + i * 2, "%02x", &byte);
        h.b[i] = (uint8_t)byte;
    }
    return h;
}

int main(void)
{
    printf("ethash benchmark — block %llu, %u trials\n",
           (unsigned long long)BLOCK_NUMBER, TRIALS);

    // ---- build light cache ----
    printf("Building light cache...\n");
    auto t0 = high_resolution_clock::now();
    ethash_light_t light = ethash_light_new(BLOCK_NUMBER);
    auto cache_ms = duration_cast<milliseconds>(high_resolution_clock::now() - t0).count();
    if (!light) {
        fprintf(stderr, "ethash_light_new failed\n");
        return 1;
    }
    printf("  cache built in %lld ms\n", (long long)cache_ms);

#ifdef FULL
    // ---- build full DAG ----
    printf("Building full DAG (this takes a while)...\n");
    t0 = high_resolution_clock::now();
    ethash_full_t full = ethash_full_new(light, NULL);
    auto dag_ms = duration_cast<milliseconds>(high_resolution_clock::now() - t0).count();
    if (!full) {
        fprintf(stderr, "ethash_full_new failed\n");
        ethash_light_delete(light);
        return 1;
    }
    printf("  DAG built in %lld ms (%.1f GB)\n",
           (long long)dag_ms,
           (double)ethash_full_dag_size(full) / (1024.0 * 1024.0 * 1024.0));
#endif

    // ---- one warm-up hash ----
    ethash_h256_t header = make_header_hash();
    {
        ethash_return_value_t result;
#ifdef FULL
        result = ethash_full_compute(full, header, 0);
#else
        result = ethash_light_compute(light, header, 0);
#endif
        printf("  warm-up result: %02x%02x%02x%02x...\n",
               result.result.b[0], result.result.b[1],
               result.result.b[2], result.result.b[3]);
    }

    // ---- timed benchmark loop ----
    printf("Running %u hashes...\n", TRIALS);
    t0 = high_resolution_clock::now();
    for (unsigned nonce = 0; nonce < TRIALS; ++nonce) {
#ifdef FULL
        ethash_full_compute(full, header, nonce);
#else
        ethash_light_compute(light, header, nonce);
#endif
    }
    auto elapsed_us = duration_cast<microseconds>(high_resolution_clock::now() - t0).count();

    // ---- report ----
    double elapsed_s = elapsed_us / 1e6;
    double hashrate  = TRIALS / elapsed_s;
    unsigned read_bytes = ETHASH_ACCESSES * ETHASH_MIX_BYTES;

#ifdef FULL
    printf("Full-DAG hashrate : %8.2f Mh/s\n", hashrate / 1e6);
    printf("Memory bandwidth  : %8.2f GB/s\n",
           hashrate * read_bytes / (1024.0 * 1024.0 * 1024.0));
#else
    printf("Light hashrate    : %8.2f Kh/s\n", hashrate / 1e3);
    printf("Memory bandwidth  : %8.2f MB/s\n",
           hashrate * read_bytes / (1024.0 * 1024.0));
#endif
    printf("Elapsed           : %.3f s (%lld us/hash)\n",
           elapsed_s, (long long)(elapsed_us / TRIALS));

#ifdef FULL
    ethash_full_delete(full);
#endif
    ethash_light_delete(light);
    return 0;
}
