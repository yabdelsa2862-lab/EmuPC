# MADEIRA: the iOS-host build exports more: libarm64ecfex_ios.def adds the symbols that only exist under
# FEX_IOS_HOST, and a .def entry for a symbol that does not exist is a link error.
if (FEX_IOS_HOST_BUILD)
  set(ARM64ECFEX_DEF libarm64ecfex_ios.def)
else()
  set(ARM64ECFEX_DEF libarm64ecfex.def)
endif()

add_library(arm64ecfex SHARED
  Module.cpp
  Module.S
  IosJitAlias.cpp
  ${ARM64ECFEX_DEF}
  $<TARGET_OBJECTS:FEXCore_object>)

patch_library_wine(arm64ecfex)

target_include_directories(arm64ecfex PRIVATE
  "${CMAKE_SOURCE_DIR}/Source/Windows/include/"
  "${CMAKE_SOURCE_DIR}/Source/"
  "${CMAKE_SOURCE_DIR}/Source/Windows/")

target_link_libraries(arm64ecfex PRIVATE
  FEXCore_Base
  Common
  CommonTools
  CommonWindows
  CommonWindowsRuntime
  ntdll_ex)

# Upstream FEX uses `-static -nostdlib -nostartfiles -nodefaultlibs` to avoid
# pulling in mingw's CRT, then re-adds libc++/libc++abi/libunwind manually.
# The non-iOS build keeps that line; it links with macOS-host llvm-mingw
# 20260421 (LLVM 22.1.4).
#
# For our iOS-host build, fall through to the default mingw link rules —
# they include the right startup files, CRT, and produce a clean arm64ec PE.
# The resulting DLL is slightly larger.
if (FEX_IOS_HOST_BUILD)
  target_link_options(arm64ecfex PRIVATE -static)
else()
  target_link_options(arm64ecfex PRIVATE -static -nostdlib -nostartfiles -nodefaultlibs -lc++ -lc++abi -lunwind)
  target_link_libraries(arm64ecfex PRIVATE ${LIBGCC_PATH})
endif()
install(TARGETS arm64ecfex RUNTIME
  DESTINATION ${CMAKE_INSTALL_LIBDIR}
  COMPONENT Runtime)
