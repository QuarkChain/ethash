"""Python 3 port of the original pyethash test suite.

Current API (QuarkChain fork):
  mkcache_bytes(block_number)                         -> bytes
  hashimoto_light(block_number, cache, header, nonce) -> dict
  get_seedhash(block_number)                          -> bytes

Tests that cannot be ported (functions removed from C extension):
  - test_get_cache_size_*       : get_cache_size() not exposed
  - test_get_full_size_*        : get_full_size() not exposed
  - test_calc_dataset_is_not_None : calc_dataset_bytes() commented out
  - test_light_and_full_agree   : hashimoto_full() + calc_dataset_bytes() commented out
  - test_mining_*               : mine() commented out
"""
import hashlib
import pytest
import pyethash
from random import randint
from Crypto.Hash import keccak

def _keccak256(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()

# Cache epoch-0 result once for the whole module (~16 MB, takes ~0.5 s)
@pytest.fixture(scope="module")
def cache_epoch0():
    return pyethash.mkcache_bytes(0)


# ===========================================================================
# Originally: test_get_cache_size_not_None / test_get_cache_size_based_on_EPOCH
# get_cache_size() is not exposed in this fork — tested indirectly via mkcache_bytes
# Each call to `mkcache_bytes` recalculates a cache of ~16-84 MB, which can be very 
# slow (potentially taking several minutes) with 100 random calls. Reducing the 
# number of calls to 10 is recommended.
# ===========================================================================

def test_mkcache_bytes_not_none():
    """Cache must not be empty for random block numbers (mirrors test_get_cache_size_not_None)."""
    for _ in range(10):
        block_num = randint(0, 12456789)
        out = pyethash.mkcache_bytes(block_num)
        assert out is not None
        assert len(out) > 0


def test_mkcache_bytes_same_within_epoch():
    """Blocks in the same epoch produce the same cache (replaces test_get_cache_size_based_on_EPOCH)."""
    for _ in range(10):
        block_num = randint(0, 12456789)
        out1 = pyethash.mkcache_bytes(block_num)
        out2 = pyethash.mkcache_bytes((block_num // pyethash.EPOCH_LENGTH) * pyethash.EPOCH_LENGTH)
        assert out1 == out2


# ===========================================================================
# Originally: test_mkcache_is_as_expected
# Now verify: size matches the formula from the spec, and content is deterministic.
# ===========================================================================

def test_mkcache_is_as_expected(cache_epoch0):
    """Cache bytes must match the pre-computed SHA-256 reference.
    """
    # Size must be a multiple of HASH_BYTES
    assert len(cache_epoch0) % pyethash.HASH_BYTES == 0

    # Compare SHA-256 fingerprint against stored reference
    expected = "396c1ff479b0a02b88bad57fe69a6a4f573b180cc4f108d0d7f431a7d3d666d9"
    actual = hashlib.sha256(cache_epoch0).hexdigest()
    assert actual == expected, (
        f"cache_epoch0 SHA-256 mismatch:\n  got:      {actual}\n  expected: {expected}"
    )

    expected = "fda2c14d3a454243c6f58f74ec60ae854f7d286497757ad32449e42e2dcd0535"
    raw = pyethash.mkcache_bytes(pyethash.EPOCH_LENGTH)
    actual = hashlib.sha256(raw).hexdigest()
    assert actual == expected, (
        f"cache_epoch1 SHA-256 mismatch:\n  got:      {actual}\n  expected: {expected}"
    )


# ===========================================================================
# hashimoto_light
# ===========================================================================

def test_hashimoto_light_returns_expected_keys(cache_epoch0):
    """Result dict must contain b'mix digest' and b'result' with 32-byte values."""
    header = b"~~~~~X~~~~~~~~~~~~~~~~~~~~~~~~~~"  # same as original test
    light_result = pyethash.hashimoto_light(0, cache_epoch0, header, 0)
    assert light_result[b"mix digest"] is not None
    assert len(light_result[b"mix digest"]) == 32
    assert light_result[b"result"] is not None
    assert len(light_result[b"result"]) == 32


def test_hashimoto_light_deterministic(cache_epoch0):
    """Same inputs must always produce the same outputs."""
    header = b"~~~~~X~~~~~~~~~~~~~~~~~~~~~~~~~~"
    r1 = pyethash.hashimoto_light(0, cache_epoch0, header, 0)
    r2 = pyethash.hashimoto_light(0, cache_epoch0, header, 0)
    assert r1[b"mix digest"] == r2[b"mix digest"]
    assert r1[b"result"]     == r2[b"result"]


def test_hashimoto_light_nonce_changes_result(cache_epoch0):
    header = b"~~~~~X~~~~~~~~~~~~~~~~~~~~~~~~~~"
    r0 = pyethash.hashimoto_light(0, cache_epoch0, header, 0)
    r1 = pyethash.hashimoto_light(0, cache_epoch0, header, 1)
    assert r0[b"result"] != r1[b"result"]


def test_hashimoto_light_bad_header_raises(cache_epoch0):
    """Header != 32 bytes must raise ValueError. Error message must include both the actual size and 32 (tests %zd fix)."""
    with pytest.raises(ValueError, match=r"16") as exc_info:
        pyethash.hashimoto_light(0, cache_epoch0, bytes(16), 0)
    assert "32" in str(exc_info.value)

# ===========================================================================
# Originally: test_get_seedhash
# Only Python 2 syntax changed: .encode('hex') -> .hex()
#                                import hashlib, sha3 -> pycryptodome keccak
# ===========================================================================

def test_get_seedhash():
    # Epoch-0 seed must be all zeros
    assert pyethash.get_seedhash(0).hex() == "0" * 64

    # All blocks in the same epoch share the same seed
    expected = pyethash.get_seedhash(0)
    for i in range(0, pyethash.EPOCH_LENGTH * 10, pyethash.EPOCH_LENGTH):
        assert pyethash.get_seedhash(i) == expected
        expected = _keccak256(expected)

    # Out-of-range block number must raise
    with pytest.raises(ValueError):
        pyethash.get_seedhash(pyethash.EPOCH_LENGTH * 2048)
