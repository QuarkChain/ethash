if (NOT BOOST_ROOT AND DEFINED ENV{BOOST_ROOT})
    set(BOOST_ROOT "$ENV{BOOST_ROOT}")
endif()
if (BOOST_ROOT)
    set(CMAKE_PREFIX_PATH "${BOOST_ROOT};${CMAKE_PREFIX_PATH}")
endif()

# The C test suite is required by the build, so fail during configuration when
# any of its Boost components are unavailable instead of omitting Test.
# use multithreaded boost libraries, with -mt suffix
set(Boost_USE_MULTITHREADED ON)

if (MSVC)
    # use static boost libraries *.lib
    set(Boost_USE_STATIC_LIBS ON)
elseif (APPLE)
    # use static boost libraries *.a
    set(Boost_USE_STATIC_LIBS ON)
elseif (UNIX)
    # use shared boost libraries
    set(Boost_USE_STATIC_LIBS OFF)
endif()

# Prefer the package configuration shipped by modern Boost distributions (for
# example Homebrew on macOS), then fall back to CMake's legacy FindBoost module
# for system packages that do not ship BoostConfig.cmake.
find_package(Boost 1.48.0 CONFIG QUIET COMPONENTS unit_test_framework system filesystem)
if (NOT Boost_FOUND)
    find_package(Boost 1.48.0 MODULE REQUIRED COMPONENTS unit_test_framework system filesystem)
endif()

file(GLOB HEADERS "*.h")

add_executable(Test "./test.cpp" ${HEADERS})
set_target_properties(Test PROPERTIES
    CXX_STANDARD 11
    CXX_STANDARD_REQUIRED YES
    CXX_EXTENSIONS NO
)
target_include_directories(Test PRIVATE ../../src)
if ((NOT MSVC) AND (NOT APPLE))
    target_compile_definitions(Test PRIVATE BOOST_TEST_DYN_LINK)
endif()
target_link_libraries(Test PRIVATE
    ${ETHHASH_LIBS}
    Boost::filesystem
    Boost::system
    Boost::unit_test_framework
)

enable_testing()
add_test(NAME ethash COMMAND Test)
