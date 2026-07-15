if(GPU_LANG STREQUAL "SYCL")

find_package(SyclTla)

if(DPCPP_VERSION STREQUAL "2025.3")
  set(SYCL_TLA_REVISION "v0.8" CACHE STRING "sycl-tla revision to use")
elseif(DPCPP_VERSION STREQUAL "2026.0")
  set(SYCL_TLA_REVISION "v0.9.1" CACHE STRING "sycl-tla revision to use")
else()
  message(FATAL_ERROR "Unknown DPCPP_VERSION: ${DPCPP_VERSION}")
endif()

if (NOT SyclTla_FOUND)
  set(CUTLASS_ENABLE_HEADERS_ONLY ON CACHE BOOL "Enable only the header library")
  set(CUTLASS_ENABLE_BENCHMARKS OFF CACHE BOOL "Disable sycl-tla Benchmarks")
# Use the specified sycl-tla source directory for compilation if SYCL_TLA_SRC_DIR is provided
  if (DEFINED ENV{SYCL_TLA_SRC_DIR})
    set(SYCL_TLA_SRC_DIR $ENV{SYCL_TLA_SRC_DIR})
  endif()

  if(SYCL_TLA_SRC_DIR)
    if(NOT IS_ABSOLUTE SYCL_TLA_SRC_DIR)
      get_filename_component(SYCL_TLA_SRC_DIR "${SYCL_TLA_SRC_DIR}" ABSOLUTE)
    endif()
    message(STATUS "The SYCL_TLA_SRC_DIR is set, using ${SYCL_TLA_SRC_DIR} for compilation")
    FetchContent_Declare(cutlass SOURCE_DIR ${SYCL_TLA_SRC_DIR})
  else()
    # Speed up sycl-tla download by retrieving only the specified GIT_TAG instead of the history.
    # Important: If GIT_SHALLOW is enabled then GIT_TAG works only with branch names and tags.
    # So if the GIT_TAG above is updated to a commit hash, GIT_SHALLOW must be set to FALSE
    if(SYCL_TLA_REVISION MATCHES "^v")
      set(SYCL_TLA_GIT_SHALLOW TRUE)
    else()
      set(SYCL_TLA_GIT_SHALLOW FALSE)
    endif()
    FetchContent_Declare(
        cutlass
        GIT_REPOSITORY https://github.com/intel/sycl-tla.git
        GIT_TAG ${SYCL_TLA_REVISION}
        GIT_PROGRESS TRUE
        GIT_SHALLOW ${SYCL_TLA_GIT_SHALLOW}
    )
  endif()

  # Set Intel backend env
  message(STATUS "Setting Intel GPU optimization env vars for sycl-tla")
  set(CUTLASS_ENABLE_SYCL ON CACHE BOOL "Enable SYCL for sycl-tla")
  add_compile_definitions(CUTLASS_ENABLE_SYCL=1)
  set(DPCPP_SYCL_TARGET "intel_gpu_bmg_g21,intel_gpu_pvc" CACHE STRING "SYCL target for Intel GPU")
  add_compile_definitions(DPCPP_SYCL_TARGET=intel_gpu_bmg_g21,intel_gpu_pvc)
  set(SYCL_INTEL_TARGET ON CACHE BOOL "Enable SYCL for INTEL")
  add_compile_definitions(SYCL_INTEL_TARGET=1)

  set(ENV{SYCL_PROGRAM_COMPILE_OPTIONS} "-ze-opt-large-register-file")
  set(ENV{IGC_VISAOptions} "-perfmodel")
  set(ENV{IGC_VectorAliasBBThreshold} "10000")
  set(ENV{IGC_ExtraOCLOptions} "-cl-intel-256-GRF-per-thread")

  FetchContent_MakeAvailable(cutlass)

  include_directories(${CUTLASS_INCLUDE_DIR})
  include_directories(${CUTLASS_TOOLS_UTIL_INCLUDE_DIR})
else()
  include_directories(${CUTLASS_INCLUDE_DIR})
  include_directories(${CUTLASS_TOOLS_UTIL_INCLUDE_DIR})
endif(NOT SyclTla_FOUND)
if(SYCL_TLA_REVISION MATCHES "^v3\\.9")
  add_compile_definitions(OLD_API=1)
endif()

# Select the XPU compilation target(s) via the KERNEL_XPU_TARGET environment
# variable. This controls which Intel GPU targets are baked into the produced
# extension .so:
#   unset / "bmg" : BMG + PVC, JIT-compiled through spir64 (default, unchanged).
#   "cri"         : CRI only, ahead-of-time compiled for intel_gpu_cri.
#   "both"        : CRI (AOT, intel_gpu_cri) and BMG/PVC (JIT, spir64) fused
#                   into a single fat binary that loads on both device families.
if(DEFINED ENV{KERNEL_XPU_TARGET})
  set(KERNEL_XPU_TARGET "$ENV{KERNEL_XPU_TARGET}")
else()
  set(KERNEL_XPU_TARGET "bmg")
endif()
message(STATUS "sycl-tla KERNEL_XPU_TARGET: ${KERNEL_XPU_TARGET}")

# SPIR-V extensions required by sycl-tla. The extra block-IO / matrix-multiply
# extensions are only available on newer DPCPP / sycl-tla combinations.
set(SYCL_TLA_SPIRV_EXT "+SPV_INTEL_split_barrier")
if(DPCPP_VERSION STREQUAL "2025.2" OR DPCPP_VERSION STREQUAL "2025.3" OR DPCPP_VERSION STREQUAL "2026.0" OR SYCL_TLA_REVISION STREQUAL "v0.5")
  string(APPEND SYCL_TLA_SPIRV_EXT ",+SPV_INTEL_2d_block_io,+SPV_INTEL_subgroup_matrix_multiply_accumulate")
endif()

if(KERNEL_XPU_TARGET STREQUAL "cri")
  # CRI: AOT-compile directly for the intel_gpu_cri target. The BMG/PVC
  # ahead-of-time device options are not valid for intel_gpu_cri and are dropped.
  string(REPLACE "-fsycl-targets=spir64_gen,spir64" "-fsycl-targets=intel_gpu_cri" sycl_link_flags "${sycl_link_flags}")
  string(REPLACE "-Xs;-device pvc,xe-lpg,ats-m150 -options ' -cl-intel-enable-auto-large-GRF-mode -cl-poison-unsupported-fp64-kernels -cl-intel-greater-than-4GB-buffer-required';" "" sycl_link_flags "${sycl_link_flags}")
  string(APPEND sycl_link_flags "-Xspirv-translator=intel_gpu_cri;-spirv-ext=${SYCL_TLA_SPIRV_EXT}")
  string(REPLACE "-fsycl-targets=spir64_gen,spir64" "-fsycl-targets=intel_gpu_cri" sycl_flags "${sycl_flags}")
elseif(KERNEL_XPU_TARGET STREQUAL "both")
  # CRI (AOT) + BMG/PVC (JIT) fused into a single fat binary. The two device
  # targets are compiled from the same sources; the SYCL compiler emits
  # per-target code based on the built-in __SYCL_TARGET_INTEL_GPU_CRI__ macro.
  string(REPLACE "-fsycl-targets=spir64_gen,spir64" "-fsycl-targets=intel_gpu_cri,spir64" sycl_link_flags "${sycl_link_flags}")
  # Bind the BMG/PVC ahead-of-time device options to the spir64 target only, so
  # they are not applied to the intel_gpu_cri target.
  string(REPLACE "-Xs;-device pvc,xe-lpg,ats-m150" "-Xsycl-target-backend=spir64;-device bmg_g21,pvc" sycl_link_flags "${sycl_link_flags}")
  # With multiple targets the SPIR-V translator options must name the triple
  # explicitly. Both targets need the identical -spirv-ext list, so each
  # -Xspirv-translator=<triple> -spirv-ext=... pair is wrapped in a SHELL:
  # group. SHELL: keeps the two tokens together and prevents CMake from
  # de-duplicating the identical -spirv-ext arguments (which would otherwise
  # strip the second one and break the spir64 translator invocation).
  string(APPEND sycl_link_flags "SHELL:-Xspirv-translator=intel_gpu_cri -spirv-ext=${SYCL_TLA_SPIRV_EXT};SHELL:-Xspirv-translator=spir64 -spirv-ext=${SYCL_TLA_SPIRV_EXT}")
  string(REPLACE "-fsycl-targets=spir64_gen,spir64" "-fsycl-targets=intel_gpu_cri,spir64" sycl_flags "${sycl_flags}")
else()
  # Default: BMG + PVC, JIT-compiled through spir64 (unchanged behaviour).
  string(REPLACE "-fsycl-targets=spir64_gen,spir64" "-fsycl-targets=spir64" sycl_link_flags "${sycl_link_flags}")
  string(REPLACE "-device pvc,xe-lpg,ats-m150" "-device bmg_g21,pvc" sycl_link_flags "${sycl_link_flags}")
  string(APPEND sycl_link_flags "-Xspirv-translator;-spirv-ext=${SYCL_TLA_SPIRV_EXT}")
  string(REPLACE "-fsycl-targets=spir64_gen,spir64" "-fsycl-targets=spir64" sycl_flags "${sycl_flags}")
endif()

endif(GPU_LANG STREQUAL "SYCL")
