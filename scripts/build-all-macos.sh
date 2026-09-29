#!/bin/bash
# Build Madeira end to end on macOS (local Mac or a GitHub Actions macos runner).
#
# Follows docs/BUILDING.md, but SKIPS the PE-side (Wine / FEX / DXMT / d3d12)
# builds: every arm64ec-windows / aarch64-windows DLL is already tracked in the
# repo. Set BUILD_PE=1 to rebuild the ones that have scripts (slow, extra risk).
#
# Each stage writes build-logs/<stage>.done and is skipped on re-run. Delete the
# marker (or run FORCE=1) to redo a stage. Run a single stage: STAGES="wineserver".
#
# NOT verified end to end -- docs/BUILDING.md says the same of the upstream
# steps. Expect to fix things at: wine host configure (host-wine), wineserver
# (needs a base archive that is not in the repo), and xcodebuild signing.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$R"
LOGS="$R/build-logs"; mkdir -p "$LOGS"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
LLVM_REF="${LLVM_REF:-llvmorg-15.0.7}"   # dxmt README says 15.0.7; BUILDING.md cites commit 8dfdcc7b7. Override if needed.
MINGW_VER=20260421
MINGW_DIR="$R/toolchains/llvm-mingw-$MINGW_VER-ucrt-macos-universal"
MINGW_SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
ALL_STAGES="prereqs submodules toolchain vcruntime licenses gnutls ffmpeg fex-ios freetype host-wine ntdll-unix win32u-unix wineserver llvm-ios dxmt-ios pe app ipa"
STAGES="${STAGES:-$ALL_STAGES}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run_stage() {
    local s="$1" fn="stage_${1//-/_}"
    case " $STAGES " in *" $s "*) ;; *) return 0 ;; esac
    if [ -f "$LOGS/$s.done" ] && [ "${FORCE:-0}" != 1 ]; then echo "[skip] $s (done)"; return 0; fi
    say "stage: $s"
    set +e
    ( set -e; $fn ) 2>&1 | tee "$LOGS/$s.log"
    local rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" = 0 ] || die "stage '$s' failed (rc=$rc). Log: build-logs/$s.log"
    touch "$LOGS/$s.done"
}

stage_prereqs() {
    [ "$(uname)" = Darwin ] || die "needs macOS"
    xcodebuild -version
    xcrun --sdk iphoneos --show-sdk-path >/dev/null || die "iPhoneOS SDK missing (install Xcode)"
    for t in cmake ninja meson python3 curl git wget; do
        command -v $t >/dev/null || brew install $([ $t = meson ] && echo meson || ([ $t = python3 ] && echo python || echo $t))
    done
    for t in autoconf automake libtool pkg-config nasm ccache bison flex gettext xz; do
        brew list $t >/dev/null 2>&1 || brew install $t
    done
    # DXMT shaders need the Metal toolchain.
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || echo "(no separate Metal toolchain download on this Xcode; continuing)"
}

stage_submodules() {
    git submodule update --init --recursive
    (cd research/dxmt && git submodule update --init --recursive)
}

stage_toolchain() {
    mkdir -p toolchains
    if [ ! -d "$MINGW_DIR" ]; then
        local t=toolchains/llvm-mingw.tar.xz
        curl -L -o $t "https://github.com/mstorsjo/llvm-mingw/releases/download/$MINGW_VER/llvm-mingw-$MINGW_VER-ucrt-macos-universal.tar.xz"
        [ "$(shasum -a 256 $t | cut -d' ' -f1)" = "$MINGW_SHA" ] || die "llvm-mingw hash mismatch"
        tar -xJf $t -C toolchains && rm $t
    fi
    [ -e research/dxmt/toolchains ] || ln -s ../../toolchains research/dxmt/toolchains
}

stage_vcruntime() {
    # Microsoft's runtime DLLs are not in the repo (tools/fetch-vcruntime.md). CI copies them
    # from a Windows runner's System32 and passes VCRUNTIME_DIR; locally, point it at a folder
    # holding the 12 DLLs.
    local out=app/Madeira/x86_64-vcruntime
    [ -n "${VCRUNTIME_DIR:-}" ] || die "set VCRUNTIME_DIR to a folder with the 12 VC++ runtime DLLs (see tools/fetch-vcruntime.md)"
    mkdir -p "$out"
    cp "$VCRUNTIME_DIR"/*.dll "$out"/
    [ "$(ls "$out"/*.dll | wc -l)" -ge 12 ] || die "need 12 DLLs in $out"
    ls "$out"
}

stage_licenses() { build/stage-licenses.sh; }
stage_gnutls()   { build/gnutls-ios/build.sh; }     # outputs are also tracked
stage_ffmpeg()   { build/ffmpeg/build.sh; }
stage_fex_ios()  { build/fex-ios/build.sh; }

stage_freetype() {
    [ -d research/freetype ] || git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
    build/freetype-ios/build.sh
}

# ntdll-unix / win32u-unix include wine/build-macos/include/config.h and use its
# generated headers. Not documented anywhere in the repo: this is a guess at a
# plain macOS host configure of the wine fork. Fix here first if it fails.
stage_host_wine() {
    mkdir -p wine/build-macos && cd wine/build-macos
    [ -f config.status ] || ../configure --enable-win64 --without-x --disable-tests \
        --without-freetype --without-gnutls --without-vulkan
    make -j"$JOBS" __tooldeps__ || true
    make -j"$JOBS" include || true
    [ -f include/config.h ] || die "wine/build-macos/include/config.h missing"
}

stage_ntdll_unix()  { build/ntdll-unix/build.sh; }
stage_win32u_unix() { build/win32u-unix/build.sh; }

# build.sh only *replaces* objects inside an existing libwineserver.a that is
# neither tracked nor documented. If there is none, seed one from wine/server so
# the replace logic has something to work on. Best effort.
stage_wineserver() {
    local base=app/Madeira/libwineserver.a
    if [ ! -f "$base" ] && [ ! -f build/wineserver/obj/libwineserver.a ]; then
        echo "No base libwineserver.a; seeding from wine/server/*.c"
        local sdk; sdk=$(xcrun --sdk iphoneos --show-sdk-path) o=build/wineserver/obj/seed
        mkdir -p $o
        for c in wine/server/*.c; do
            xcrun -sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=17.0 -O2 \
                -Iwine/include -Iwine/include/wine -Iwine/build-macos/include -Iwine/server \
                -Ibuild/ntdll-unix/shims -include build/wineserver/config_ios.h -include stdarg.h \
                -D__WINESRC__ -DWINE_IOS=1 -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\" \
                -Dmain=wineserver_main -Wno-implicit-function-declaration -Wno-int-conversion \
                -c "$c" -o "$o/$(basename "$c" .c).o" 2>>"$LOGS/wineserver-seed.err" \
                || echo "  (seed) failed: $c -- see build-logs/wineserver-seed.err"
        done
        mkdir -p build/wineserver/obj
        ar rcs build/wineserver/obj/libwineserver.a $o/*.o
    fi
    build/wineserver/build.sh
}

stage_llvm_ios() {
    mkdir -p toolchains
    if [ ! -d toolchains/llvm-project ]; then
        git clone --depth 1 --branch "$LLVM_REF" https://github.com/llvm/llvm-project.git toolchains/llvm-project
    fi
    # Apple ld rejects --gc-sections; treat iOS like Darwin (dxmt README).
    sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/g' toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD= -DLLVM_INCLUDE_TESTS=Off
    cmake --build toolchains/llvm-host-build --target llvm-tblgen
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= \
        -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_UTILS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off \
        -DLLVM_TABLEGEN="$R/toolchains/llvm-host-build/bin/llvm-tblgen"
    cmake --build toolchains/llvm-ios-build   # hours
}

stage_dxmt_ios() {
    build/dxmt-ios/build.sh
    xcrun -sdk iphoneos libtool -static -o build/dxmt-ios/libdxmt_combined.a \
        build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a
    cp build/dxmt-ios/libdxmt_combined.a app/Madeira/
}

stage_pe() {
    [ "${BUILD_PE:-0}" = 1 ] || { echo "skipped: PE DLLs are tracked (set BUILD_PE=1 to rebuild)"; return 0; }
    build/fex-arm64ec/build.sh
    build/wine-pe/build-ntdll.sh
    build/madeira-d3d12/build-pe.sh
}

stage_app() {
    local sign=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
    [ -z "${TEAM_ID:-}" ] || sign=(DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates)
    xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath build/xcode "${sign[@]}" build
}

stage_ipa() {
    local app; app="$(find build/xcode/Build/Products -maxdepth 2 -name Madeira.app | head -1)"
    [ -n "$app" ] || die "Madeira.app not found"
    rm -rf build/ipa && mkdir -p build/ipa/Payload
    cp -R "$app" build/ipa/Payload/
    (cd build/ipa && zip -qry Madeira.ipa Payload)
    echo "IPA: $R/build/ipa/Madeira.ipa (unsigned unless TEAM_ID was set; sign with Sideloadly/AltStore)"
}

for s in $ALL_STAGES; do run_stage "$s"; done
say "done"
