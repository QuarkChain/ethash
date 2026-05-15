// Copyright 2015 The go-ethereum Authors
// Copyright 2015 Lefteris Karapetsas <lefteris@refu.co>
// Copyright 2015 Matthew Wampler-Doty <matthew.wampler.doty@gmail.com>
// This file is part of the go-ethereum library.
//
// The go-ethereum library is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The go-ethereum library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with the go-ethereum library. If not, see <http://www.gnu.org/licenses/>.

package ethash

/*
#include "src/libethash/internal.h"
#include "src/libethash/sha3.h"

// ethash_keccak256_go: thin C wrapper so Go can call the already-compiled
// Keccak-256 (sha3_256 with 0x01 padding, as required by Ethereum) without
// any extra Go-level dependency.
static void __attribute__((unused))
ethash_keccak256_go(uint8_t* out, const uint8_t* data, size_t len) {
    sha3_256(out, 32, data, len);
}

int ethashGoCallback_cgo(unsigned);
*/
import "C"

import (
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"math/big"
	"math/rand"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

// ---------------------------------------------------------------------------
// Hash type — replaces github.com/ethereum/go-ethereum/common.Hash
// ---------------------------------------------------------------------------

// Hash is a 32-byte Keccak-256 digest.
type Hash [32]byte

// HexToHash decodes a hex string (with or without 0x prefix) into a Hash.
func HexToHash(s string) Hash {
	s = strings.TrimPrefix(s, "0x")
	b, _ := hex.DecodeString(s)
	return BytesToHash(b)
}

// BytesToHash right-aligns b into a 32-byte Hash.
func BytesToHash(b []byte) Hash {
	var h Hash
	if len(b) > 32 {
		b = b[len(b)-32:]
	}
	copy(h[32-len(b):], b)
	return h
}

// Big interprets the hash as a big-endian unsigned integer.
func (h Hash) Big() *big.Int { return new(big.Int).SetBytes(h[:]) }

// keccak256Hash computes the Keccak-256 hash of the concatenation of inputs
// using the C implementation already compiled in via ethashc.go (sha3.c).
// This avoids any external Go dependency and the //go:linkname conflicts
// that golang.org/x/sys introduces in Go 1.24 with Swiss maps.
func keccak256Hash(data ...[]byte) Hash {
	var combined []byte
	for _, b := range data {
		combined = append(combined, b...)
	}
	var h Hash
	if len(combined) > 0 {
		C.ethash_keccak256_go(
			(*C.uint8_t)(unsafe.Pointer(&h[0])),
			(*C.uint8_t)(unsafe.Pointer(&combined[0])),
			C.size_t(len(combined)),
		)
	} else {
		C.ethash_keccak256_go((*C.uint8_t)(unsafe.Pointer(&h[0])), nil, 0)
	}
	return h
}

var (
	maxUint256  = new(big.Int).Exp(big.NewInt(2), big.NewInt(256), big.NewInt(0))
	sharedLight = new(Light)
)

const (
	epochLength         uint64     = 30000
	cacheSizeForTesting C.uint64_t = 1024
	dagSizeForTesting   C.uint64_t = 1024 * 32
)

var DefaultDir = defaultDir()

func defaultDir() string {
	home := os.Getenv("HOME")
	if user, err := user.Current(); err == nil {
		home = user.HomeDir
	}
	if runtime.GOOS == "windows" {
		return filepath.Join(home, "AppData", "Ethash")
	}
	return filepath.Join(home, ".ethash")
}

// cache wraps an ethash_light_t with some metadata
// and automatic memory management.
type cache struct {
	epoch uint64
	used  time.Time
	test  bool

	gen sync.Once // ensures cache is only generated once.
	ptr *C.struct_ethash_light
}

// generate creates the actual cache. it can be called from multiple
// goroutines. the first call will generate the cache, subsequent
// calls wait until it is generated.
func (cache *cache) generate() {
	cache.gen.Do(func() {
		started := time.Now()
		seedHash := makeSeedHash(cache.epoch)
		log.Printf("[ethash] Generating cache for epoch %d (%x)", cache.epoch, seedHash)
		size := C.ethash_get_cachesize(C.uint64_t(cache.epoch * epochLength))
		if cache.test {
			size = cacheSizeForTesting
		}
		cache.ptr = C.ethash_light_new_internal(size, (*C.ethash_h256_t)(unsafe.Pointer(&seedHash[0])))
		// Panic rather than silently storing a nil ptr that would crash later
		// inside compute() when the C code dereferences light->cache.
		if cache.ptr == nil {
			panic(fmt.Sprintf("ethash: ethash_light_new_internal returned nil for epoch %d (OOM?)", cache.epoch))
		}
		runtime.SetFinalizer(cache, freeCache)
		log.Printf("[ethash] Done generating cache for epoch %d, took %v", cache.epoch, time.Since(started))
	})
}

func freeCache(cache *cache) {
	C.ethash_light_delete(cache.ptr)
	cache.ptr = nil
}

func (cache *cache) compute(dagSize uint64, hash Hash, nonce uint64) (ok bool, mixDigest, result Hash) {
	ret := C.ethash_light_compute_internal(cache.ptr, C.uint64_t(dagSize), hashToH256(hash), C.uint64_t(nonce))
	// Keep cache alive past the C call to prevent premature GC finalisation.
	_ = cache
	return bool(ret.success), h256ToHash(ret.mix_hash), h256ToHash(ret.result)
}

// Light implements the Verify half of the proof of work. It uses a few small
// in-memory caches to verify the nonces found by Full.
type Light struct {
	test bool // If set, use a smaller cache size

	mu     sync.Mutex        // Protects the per-epoch map of verification caches
	caches map[uint64]*cache // Currently maintained verification caches
	future *cache            // Pre-generated cache for the estimated future DAG

	NumCaches int // Maximum number of caches to keep before eviction (only init, don't modify)
}

// Verify checks whether the block's nonce is valid.
func (l *Light) Verify(block Block) bool {
	blockNum := block.NumberU64()
	if blockNum >= epochLength*2048 {
		return false
	}

	difficulty := block.Difficulty()
	if difficulty.Cmp(new(big.Int)) == 0 {
		return false
	}

	cache := l.getCache(blockNum)
	dagSize := C.ethash_get_datasize(C.uint64_t(blockNum))
	if l.test {
		dagSize = dagSizeForTesting
	}
	ok, mixDigest, result := cache.compute(uint64(dagSize), block.HashNoNonce(), block.Nonce())
	if !ok {
		return false
	}
	if block.MixDigest() != mixDigest {
		return false
	}
	target := new(big.Int).Div(maxUint256, difficulty)
	return result.Big().Cmp(target) <= 0
}

func h256ToHash(in C.ethash_h256_t) Hash {
	return *(*Hash)(unsafe.Pointer(&in.b))
}

func hashToH256(in Hash) C.ethash_h256_t {
	return C.ethash_h256_t{b: *(*[32]C.uint8_t)(unsafe.Pointer(&in[0]))}
}

func (l *Light) getCache(blockNum uint64) *cache {
	var c *cache
	epoch := blockNum / epochLength

	l.mu.Lock()
	if l.caches == nil {
		l.caches = make(map[uint64]*cache)
	}
	if l.NumCaches == 0 {
		l.NumCaches = 3
	}
	c = l.caches[epoch]
	if c == nil {
		if len(l.caches) >= l.NumCaches {
			var evict *cache
			for _, cache := range l.caches {
				if evict == nil || evict.used.After(cache.used) {
					evict = cache
				}
			}
			delete(l.caches, evict.epoch)
		}
		if l.future != nil && l.future.epoch == epoch {
			c, l.future = l.future, nil
		} else {
			c = &cache{epoch: epoch, test: l.test}
		}
		l.caches[epoch] = c

		if l.future == nil || l.future.epoch <= epoch {
			l.future = &cache{epoch: epoch + 1, test: l.test}
			go l.future.generate()
		}
	}
	c.used = time.Now()
	l.mu.Unlock()

	c.generate()
	return c
}

// dag wraps an ethash_full_t with some metadata
// and automatic memory management.
type dag struct {
	epoch uint64
	test  bool
	dir   string

	gen sync.Once // ensures DAG is only generated once.
	ptr *C.struct_ethash_full
}

// generate creates the actual DAG. it can be called from multiple
// goroutines. the first call will generate the DAG, subsequent
// calls wait until it is generated.
func (d *dag) generate() {
	d.gen.Do(func() {
		var (
			started   = time.Now()
			seedHash  = makeSeedHash(d.epoch)
			blockNum  = C.uint64_t(d.epoch * epochLength)
			cacheSize = C.ethash_get_cachesize(blockNum)
			dagSize   = C.ethash_get_datasize(blockNum)
		)
		if d.test {
			cacheSize = cacheSizeForTesting
			dagSize = dagSizeForTesting
		}
		if d.dir == "" {
			d.dir = DefaultDir
		}
		log.Printf("[ethash] Generating DAG for epoch %d (size %d) (%x)", d.epoch, dagSize, seedHash)
		cache := C.ethash_light_new_internal(cacheSize, (*C.ethash_h256_t)(unsafe.Pointer(&seedHash[0])))
		defer C.ethash_light_delete(cache)
		// C.CString allocates on the C heap — free after the call.
		cDir := C.CString(d.dir)
		d.ptr = C.ethash_full_new_internal(
			cDir,
			hashToH256(seedHash),
			dagSize,
			cache,
			(C.ethash_callback_t)(unsafe.Pointer(C.ethashGoCallback_cgo)),
		)
		C.free(unsafe.Pointer(cDir))
		if d.ptr == nil {
			panic("ethash_full_new IO or memory error")
		}
		runtime.SetFinalizer(d, freeDAG)
		log.Printf("[ethash] Done generating DAG for epoch %d, took %v", d.epoch, time.Since(started))
	})
}

func freeDAG(d *dag) {
	C.ethash_full_delete(d.ptr)
	d.ptr = nil
}

func (d *dag) Ptr() unsafe.Pointer {
	return unsafe.Pointer(d.ptr.data)
}

//export ethashGoCallback
func ethashGoCallback(percent C.unsigned) C.int {
	log.Printf("[ethash] Generating DAG: %d%%", percent)
	return 0
}

// MakeDAG pre-generates a DAG file for the given block number in the
// given directory. If dir is the empty string, the default directory
// is used.
func MakeDAG(blockNum uint64, dir string) error {
	d := &dag{epoch: blockNum / epochLength, dir: dir}
	if blockNum >= epochLength*2048 {
		return fmt.Errorf("block number too high, limit is %d", epochLength*2048)
	}
	d.generate()
	if d.ptr == nil {
		return errors.New("failed")
	}
	return nil
}

// Full implements the Search half of the proof of work.
type Full struct {
	Dir string // use this to specify a non-default DAG directory

	test     bool // if set use a smaller DAG size
	turbo    bool
	hashRate int32

	mu      sync.Mutex // protects dag
	current *dag       // current full DAG
}

func (pow *Full) getDAG(blockNum uint64) (d *dag) {
	epoch := blockNum / epochLength
	pow.mu.Lock()
	if pow.current != nil && pow.current.epoch == epoch {
		d = pow.current
	} else {
		d = &dag{epoch: epoch, test: pow.test, dir: pow.Dir}
		pow.current = d
	}
	pow.mu.Unlock()
	d.generate()
	return d
}

func (pow *Full) Search(block Block, stop <-chan struct{}, index int) (nonce uint64, mixDigest []byte) {
	dag := pow.getDAG(block.NumberU64())

	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	diff := block.Difficulty()

	i := int64(0)
	starti := i
	start := time.Now().UnixNano()
	previousHashrate := int32(0)

	nonce = uint64(r.Int63())
	hash := hashToH256(block.HashNoNonce())
	target := new(big.Int).Div(maxUint256, diff)
	for {
		select {
		case <-stop:
			atomic.AddInt32(&pow.hashRate, -previousHashrate)
			return 0, nil
		default:
			i++
			if i == 2 || ((i % (1 << 16)) == 0) {
				elapsed := time.Now().UnixNano() - start
				hashes := (float64(1e9) / float64(elapsed)) * float64(i-starti)
				hashrateDiff := int32(hashes) - previousHashrate
				previousHashrate = int32(hashes)
				atomic.AddInt32(&pow.hashRate, hashrateDiff)
			}

			ret := C.ethash_full_compute(dag.ptr, hash, C.uint64_t(nonce))
			result := h256ToHash(ret.result).Big()

			if ret.success && result.Cmp(target) <= 0 {
				mixDigest = C.GoBytes(unsafe.Pointer(&ret.mix_hash), C.int(32))
				atomic.AddInt32(&pow.hashRate, -previousHashrate)
				return nonce, mixDigest
			}
			nonce += 1
		}

		if !pow.turbo {
			time.Sleep(20 * time.Microsecond)
		}
	}
}

func (pow *Full) GetHashrate() int64 {
	return int64(atomic.LoadInt32(&pow.hashRate))
}

func (pow *Full) Turbo(on bool) {
	pow.turbo = on
}

// Ethash combines block verification with Light and
// nonce searching with Full into a single proof of work.
type Ethash struct {
	*Light
	*Full
}

// New creates an instance of the proof of work.
func New() *Ethash {
	return &Ethash{new(Light), &Full{turbo: true}}
}

// NewShared creates an instance of the proof of work., where a single instance
// of the Light cache is shared across all instances created with NewShared.
func NewShared() *Ethash {
	return &Ethash{sharedLight, &Full{turbo: true}}
}

// NewForTesting creates a proof of work for use in unit tests.
// It uses a smaller DAG and cache size to keep test times low.
// DAG files are stored in a temporary directory.
//
// Nonces found by a testing instance are not verifiable with a
// regular-size cache.
func NewForTesting() (*Ethash, error) {
	dir, err := os.MkdirTemp("", "ethash-test")
	if err != nil {
		return nil, err
	}
	return &Ethash{&Light{test: true}, &Full{Dir: dir, test: true}}, nil
}

func GetSeedHash(blockNum uint64) ([]byte, error) {
	if blockNum >= epochLength*2048 {
		return nil, fmt.Errorf("block number too high, limit is %d", epochLength*2048)
	}
	sh := makeSeedHash(blockNum / epochLength)
	return sh[:], nil
}

func makeSeedHash(epoch uint64) (sh Hash) {
	for ; epoch > 0; epoch-- {
		sh = keccak256Hash(sh[:])
	}
	return sh
}
