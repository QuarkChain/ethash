set(LIBRARY ethash)

if (CPPETHEREUM)
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fPIC")
endif ()

set(CMAKE_BUILD_TYPE Release)

if (NOT MSVC)
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu99")
endif()

set(FILES 	util.h
          	io.c
          	internal.c
          	ethash.h
          	endian.h
          	compiler.h
          	fnv.h
          	data_sizes.h)

if (MSVC)
	list(APPEND FILES util_win32.c io_win32.c mmap_win32.c)
else()
	list(APPEND FILES io_posix.c)
endif()

# Always use the bundled Keccak implementation (sha3.c). Crypto++ >= 5.6.3
# renamed its pre-finalized Keccak to the standardized FIPS 202 SHA-3 (padding
# 0x06 vs 0x01) while keeping the SHA3_256/SHA3_512 names, which silently breaks
# ethash on any system with a modern libcryptopp installed.
list(APPEND FILES sha3.c sha3.h)

add_library(${LIBRARY} ${FILES})
