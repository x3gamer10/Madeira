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
# Homebrew's bison/flex are keg-only; Wine's configure rejects the ancient system bison.
for p in bison flex; do
    [ -d "/opt/homebrew/opt/$p/bin" ] && export PATH="/opt/homebrew/opt/$p/bin:$PATH"
done
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
    if [ "$rc" != 0 ]; then
        # The per-file compile loops only print FAILED; show the saved compiler errors.
        local e o
        for e in build/*/obj/*.err build/*/obj/err-*.txt build/*/obj/seed/err-*.txt; do
            [ -s "$e" ] || continue
            o="${e%.err}.o"; [[ "$e" == *.txt ]] && o="$(dirname "$e")/$(basename "$e" .txt | sed 's/^err-//').o"
            [ -f "$o" ] && continue
            echo "----- $e"; grep -m 15 -E "error|Error" "$e" || head -15 "$e"
        done 2>/dev/null | tee -a "$LOGS/$s.log"
        die "stage '$s' failed (rc=$rc). Log: build-logs/$s.log"
    fi
    touch "$LOGS/$s.done"
}

stage_prereqs() {
    [ "$(uname)" = Darwin ] || die "needs macOS"
    xcodebuild -version
    xcrun --sdk iphoneos --show-sdk-path >/dev/null || die "iPhoneOS SDK missing (install Xcode)"
    for t in cmake ninja meson python3 curl git wget; do
        command -v $t >/dev/null || brew install $([ $t = meson ] && echo meson || ([ $t = python3 ] && echo python || echo $t))
    done
    for t in autoconf automake libtool pkg-config nasm ccache bison flex gettext xz llvm; do
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

# ntdll-unix / win32u-unix include wine/build-macos/include/config.h and the
# widl-generated headers (mfobjects.h etc.). Not documented in the repo: this is
# a plain macOS host configure of the wine fork (Wine 11.4, single Makefile).
stage_host_wine() {
    export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$MINGW_DIR/bin:$PATH"
    bison --version | head -1
    mkdir -p wine/build-macos && cd wine/build-macos
    [ -f config.status ] || ../configure --without-x --disable-tests \
        --without-freetype --without-gnutls --without-vulkan
    make -j"$JOBS" __tooldeps__
    make -j"$JOBS" include/all
    [ -f include/config.h ] || die "wine/build-macos/include/config.h missing"
    [ -f include/mfobjects.h ] || die "widl headers (include/mfobjects.h) were not generated"
}

stage_ntdll_unix() {
    # dwrite_unixlib reads widl headers from wine/build-arm64ec/include (the PE tree).
    # When the PE side isn't rebuilt, the host tree's generated headers are the same files.
    if [ "${BUILD_PE:-0}" != 1 ] && [ ! -e wine/build-arm64ec/include ]; then
        mkdir -p wine/build-arm64ec && ln -s ../build-macos/include wine/build-arm64ec/include
    fi
    build/ntdll-unix/build.sh
}
stage_win32u_unix() { build/win32u-unix/build.sh; }

# build.sh only *replaces* objects inside an existing libwineserver.a that is
# neither tracked nor documented. If there is none, seed one by compiling the
# wine/server SOURCES with build.sh's own flags; build.sh then swaps in the
# iOS-patched objects. A seed failure only matters if build.sh doesn't replace it.
stage_wineserver() {
    export PATH="$(brew --prefix llvm)/bin:$PATH"   # llvm-objcopy for the symbol renames
    local base=app/Madeira/libwineserver.a
    if [ ! -f "$base" ] && [ ! -f build/wineserver/obj/libwineserver.a ]; then
        echo "No base libwineserver.a; seeding from wine/server"
        local sdk o=build/wineserver/obj/seed B=build/wineserver W=wine
        sdk=$(xcrun --sdk iphoneos --show-sdk-path)
        mkdir -p $o
        for c in $(sed -n '/^SOURCES/,/^$/p' wine/server/Makefile.in | grep -o '[a-z_0-9]*\.c'); do
            printf '  seed %s... ' "$c"
            if xcrun -sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=17.0 -O2 \
                -I$W/include -I$W/include/wine -I$W/build-macos/include -I$B -I$W/server \
                -Ibuild/ntdll-unix/shims -Ibuild/madsync -DHAVE_LINUX_NTSYNC_H=1 \
                -include $B/config_ios.h -include stdarg.h -include $B/unicode_fix.h \
                -include $B/wineserver_ios_kill.h \
                -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\" \
                -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main -Wno-implicit-function-declaration \
                -c "wine/server/$c" -o "$o/${c%.c}.o" 2>"$o/err-${c%.c}.txt"; then
                echo OK
            else
                echo "FAILED"; head -5 "$o/err-${c%.c}.txt"
            fi
        done
        ar rcs build/wineserver/obj/libwineserver.a $o/*.o
    fi
    build/wineserver/build.sh
}

# LLVM 15.0.7 for iOS, needed by DXMT's airconv. CI builds this in its own job and
# caches it; the main job then finds it already present.
stage_llvm_ios() {
    if [ -f toolchains/llvm-ios-build/lib/libLLVMCore.a ]; then
        echo "LLVM iOS libs already present (cache)"; return 0
    fi
    [ "${REQUIRE_CACHED_LLVM:-0}" != 1 ] || die "LLVM iOS build not cached yet: let the 'llvm' job finish, then re-run"
    mkdir -p toolchains
    if [ ! -d toolchains/llvm-project ]; then
        git clone --depth 1 --branch "$LLVM_REF" https://github.com/llvm/llvm-project.git toolchains/llvm-project
    fi
    # Apple ld rejects --gc-sections; treat iOS like Darwin (dxmt README).
    sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/g' toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_INCLUDE_TESTS=Off
        -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_DOCS=Off
        -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_LIBXML2=Off -DLLVM_ENABLE_TERMINFO=Off)
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host-build "${common[@]}"
    cmake --build toolchains/llvm-host-build --target llvm-tblgen
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build "${common[@]}" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_TARGET_ARCH=host -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_UTILS=Off \
        -DLLVM_TABLEGEN="$R/toolchains/llvm-host-build/bin/llvm-tblgen"
    cmake --build toolchains/llvm-ios-build
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
