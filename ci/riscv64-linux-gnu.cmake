# CMake toolchain file for cross-compiling to riscv64 Linux (glibc) from an
# x86-64 host with the Debian/Ubuntu gcc-riscv64-linux-gnu toolchain.
#
#   cmake -DCMAKE_TOOLCHAIN_FILE=ci/riscv64-linux-gnu.cmake ...
#
# RISCV64_SYSROOT        riscv64 sysroot (default: /usr/riscv64-linux-gnu,
#                        populated by the Ubuntu cross packages)
# RISCV64_STAGING_PREFIX optional extra root holding cross-built dependencies
#                        (e.g. the Vulkan loader/headers from ci/build-llamacpp.sh)
#
# Both can be passed as -D cache variables or environment variables.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv64)

set(CMAKE_C_COMPILER   riscv64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER riscv64-linux-gnu-g++)
set(CMAKE_ASM_COMPILER riscv64-linux-gnu-gcc)

if(NOT DEFINED RISCV64_SYSROOT)
  if(DEFINED ENV{RISCV64_SYSROOT})
    set(RISCV64_SYSROOT "$ENV{RISCV64_SYSROOT}")
  else()
    set(RISCV64_SYSROOT /usr/riscv64-linux-gnu)
  endif()
endif()
if(NOT DEFINED RISCV64_STAGING_PREFIX AND DEFINED ENV{RISCV64_STAGING_PREFIX})
  set(RISCV64_STAGING_PREFIX "$ENV{RISCV64_STAGING_PREFIX}")
endif()

# Forward to try_compile() projects, which re-read this file.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES RISCV64_SYSROOT RISCV64_STAGING_PREFIX)

set(CMAKE_FIND_ROOT_PATH "${RISCV64_SYSROOT}")
if(RISCV64_STAGING_PREFIX)
  list(APPEND CMAKE_FIND_ROOT_PATH "${RISCV64_STAGING_PREFIX}")
endif()

# Libraries, headers and CMake packages come only from the riscv64 roots,
# never from the host. Programs (glslc, python3, ...) run on the build machine,
# so they are looked up on the host only.
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)

# Keep pkg-config away from the host's x86-64 .pc files as well.
set(_riscv64_pc_dirs "${RISCV64_SYSROOT}/lib/pkgconfig" "${RISCV64_SYSROOT}/share/pkgconfig")
if(RISCV64_STAGING_PREFIX)
  list(PREPEND _riscv64_pc_dirs "${RISCV64_STAGING_PREFIX}/lib/pkgconfig" "${RISCV64_STAGING_PREFIX}/share/pkgconfig")
endif()
string(REPLACE ";" ":" _riscv64_pc_dirs "${_riscv64_pc_dirs}")
set(ENV{PKG_CONFIG_LIBDIR} "${_riscv64_pc_dirs}")
set(ENV{PKG_CONFIG_PATH} "")
