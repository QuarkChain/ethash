cmake_minimum_required(VERSION 3.10...3.31)
project(ethash)

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CMAKE_SOURCE_DIR}/cmake/modules/")
set(ETHHASH_LIBS ethash)

if (WIN32 AND WANT_CRYPTOPP)
	add_subdirectory(cryptopp)
endif()

add_subdirectory(src/libethash)

add_subdirectory(src/benchmark EXCLUDE_FROM_ALL)
add_subdirectory(test/c)
