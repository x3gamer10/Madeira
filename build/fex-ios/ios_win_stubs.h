// Build-only shim for build/fex-ios/build.sh (force-included into every C++ file).
//
// FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp (IosLogUnimplementedCASPAL) calls the
// Windows VirtualQuery API in a diagnostic-only path with no platform guard. It is only
// ever valid in the ARM64EC/Windows build; the iOS static-library build has no <windows.h>.
// Supply just the names it uses. VirtualQuery reports "no info", so the probe prints "?".
#pragma once
#ifdef __APPLE__
#include <stddef.h>
#include <stdint.h>

typedef const void* LPCVOID;
#ifndef MEM_IMAGE
#define MEM_IMAGE 0x1000000
#define MEM_MAPPED 0x40000
#define MEM_PRIVATE 0x20000
#endif

typedef struct _MEMORY_BASIC_INFORMATION {
  void* BaseAddress;
  void* AllocationBase;
  uint32_t AllocationProtect;
  size_t RegionSize;
  uint32_t State;
  uint32_t Protect;
  uint32_t Type;
} MEMORY_BASIC_INFORMATION;

static inline size_t VirtualQuery(LPCVOID, MEMORY_BASIC_INFORMATION*, size_t) {
  return 0;
}

// FEXCore/Source/Utils/AllocatorHooks.cpp defines IOS_RPM_GUARD() only in its
// ENABLE_FEX_ALLOCATOR (rpmalloc) branch but also uses it in the system-malloc
// branch this build compiles (ENABLE_FEX_ALLOCATOR=OFF). With no rpmalloc there
// is no lock to take, so it is a no-op here.
#ifndef IOS_RPM_GUARD
#define IOS_RPM_GUARD() ((void)0)
#endif
#endif
