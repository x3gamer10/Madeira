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
ALL_STAGES="prereqs submodules toolchain vcruntime licenses gnutls ffmpeg fex-ios freetype host-wine ntdll-unix win32u-unix wineserver llvm-ios dxmt-ios wine-i386 wine-aarch64 wine-arm64ec pe pe-fixes dock app ipa"
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
# FEX_IOS_HOST is NOT defined for this library: it selects code for FEX's Windows-side
# modules (ARM64EC/WOW64 DLLs), which define IosMonoResolveRW, ios_fex_band_* etc. that
# the app does not have. The patch guards the two probes that don't compile without it.
stage_fex_ios()  { python3 tools/patch-fex-ios-probes.py; build/fex-ios/build.sh; }

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
    # Configured --without-gnutls (the host has none for iOS), so config.h defines neither
    # guard below; dlls/bcrypt/gnutls.c and dlls/secur32/schannel_gnutls.c would compile to
    # EMPTY objects and the app link would fail on _bcrypt/_secur32_unix_call_funcs.
    # ntdll-unix links toolchains/gnutls-ios statically and ios_gnutls_shim.h maps
    # dlopen/dlsym onto a static table, so the soname is only matched, never opened.
    # (Fix from github.com/bahacan16/madeira-bcd, build-ipa.yml.)
    grep -q "madeira: gnutls guards" include/config.h || cat >> include/config.h <<'EOF'

/* madeira: gnutls guards (see scripts/build-all-macos.sh, stage_host_wine) */
#ifndef SONAME_LIBGNUTLS
#define SONAME_LIBGNUTLS "libgnutls.so.30"
#endif
#ifndef HAVE_GNUTLS_CIPHER_INIT
#define HAVE_GNUTLS_CIPHER_INIT 1
#endif
EOF
}

stage_ntdll_unix() {
    # dwrite_unixlib reads widl headers from wine/build-arm64ec/include (the PE tree).
    # When the PE side isn't rebuilt, the host tree's generated headers are the same files.
    if [ "${BUILD_PE:-0}" != 1 ] && [ ! -e wine/build-arm64ec/include ]; then
        mkdir -p wine/build-arm64ec && ln -s ../build-macos/include wine/build-arm64ec/include
    fi
    build/ntdll-unix/build.sh
    # An #ifdef-guarded unixlib compiles "OK" to an empty object; catch that here rather
    # than as undefined symbols at the very end of the Xcode link.
    local s missing=""
    nm -gU app/Madeira/libntdll_unix.a 2>/dev/null | awk '{print $NF}' | sort -u > "$LOGS/ntdll-syms.txt"
    for s in bcrypt secur32 crypt32 ws2_32 dwrite; do
        grep -qx "_${s}_unix_call_funcs" "$LOGS/ntdll-syms.txt" && echo "  OK   ${s}_unix_call_funcs" \
            || { echo "  MISS ${s}_unix_call_funcs"; missing="$missing $s"; }
    done
    [ -z "$missing" ] || die "libntdll_unix.a lacks unix call tables for:$missing"
}
stage_win32u_unix() { build/win32u-unix/build.sh; }

# build.sh only *replaces* objects inside an existing libwineserver.a that is
# neither tracked nor documented. If there is none, seed one by compiling the
# wine/server SOURCES with build.sh's own flags; build.sh then swaps in the
# iOS-patched objects. A seed failure only matters if build.sh doesn't replace it.
stage_wineserver() {
    export PATH="$(brew --prefix llvm)/bin:$PATH"   # llvm-objcopy for the symbol renames
    # compiled from wine/server/thread.c below: async I/O APCs for busy threads
    apply_wine_patches patches/wine-server-apc-requeue.patch
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
        -DLLVM_TOOL_LTO_BUILD=Off -DLLVM_TOOL_REMARKS_SHLIB_BUILD=Off \
        -DLLVM_TABLEGEN="$R/toolchains/llvm-host-build/bin/llvm-tblgen"
    # Only the static libraries matter; a stray tool/dylib failing to link (libLTO did,
    # with -z defs) must not throw away an otherwise finished build.
    cmake --build toolchains/llvm-ios-build -- -k 0 || echo "(some non-library targets failed; checking the libraries)"
    local l
    for l in Support Core BitReader BitWriter IRReader AsmParser Analysis TransformUtils; do
        [ -f "toolchains/llvm-ios-build/lib/libLLVM$l.a" ] || die "libLLVM$l.a was not built"
    done
    ls toolchains/llvm-ios-build/lib/*.a | wc -l
}

stage_dxmt_ios() {
    # airconv_context.cpp includes air_{msad,samplepos,tessellation}.h, which DXMT's
    # meson build generates (src/airconv/meson.build: metal -> .air -> xxd). build.sh
    # has no such step, so generate them into its shader-headers include dir.
    local sh=build/dxmt-ios/shader-headers s n
    mkdir -p "$sh"
    for s in research/dxmt/src/airconv/shaders/*.metal; do
        n=$(basename "$s" .metal)
        xcrun -sdk macosx metal -o "$sh/$n.air" -c "$s" -std=metal3.1 --target=air64-apple-macos14.0
        (cd "$sh" && xxd -n "$n" -i "$n.air" "$n.h")
        echo "  $n.h OK"
    done
    build/dxmt-ios/build.sh
    xcrun -sdk iphoneos libtool -static -o build/dxmt-ios/libdxmt_combined.a \
        build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a
    cp build/dxmt-ios/libdxmt_combined.a app/Madeira/
}

# Apply Wine patches to the submodule's working tree, each once.
apply_wine_patches() {
    local p
    for p in "$@"; do
        [ -f "$p" ] || continue
        if git -C wine apply --reverse --check "$R/$p" 2>/dev/null; then
            echo "already applied: $p"
        else
            git -C wine apply "$R/$p" || die "cannot apply $p to wine"
            echo "applied: $p"
        fi
    done
}

# WoW64 (32-bit x86 games, e.g. Saints Row 2): the i386 Windows farm that
# app/Madeira/i386-windows must hold. Upstream does not commit it (docs/WOW64.md,
# "Building"); without it a 32-bit exe fails with "the bundle has no i386-windows"
# and then an assertion in build_wow64_parameters. The aarch64 half (wow64.dll,
# wow64win.dll, FEX's xtajit.dll) is committed. CI restores the farm from a cache
# keyed on the wine/DXMT revisions. A failure here does not stop the IPA: 64-bit
# games do not need it.
stage_wine_i386() {
    local n
    n=$(ls app/Madeira/i386-windows 2>/dev/null | grep -ci '\.dll$' || true)
    if [ "$n" -gt 300 ]; then echo "i386 farm already present ($n DLLs, cache)"; return 0; fi
    export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
    # i386-only Wine patches (the workflow's farm cache key hashes these files too).
    apply_wine_patches patches/wine-i386-*.patch
    if build/wine-i386/build.sh; then
        echo "i386 farm: $(ls app/Madeira/i386-windows | wc -l | tr -d ' ') files"
        # patches/wine-i386-audio-125hz.patch leaves a build tag in the XACT engine
        grep -aq MADEIRA-FACT app/Madeira/i386-windows/xactengine3_7.dll \
            && echo "xactengine3_7.dll: FACT streaming fix present" \
            || echo "WARNING: xactengine3_7.dll lacks the FACT streaming fix"
    else
        cp -f wine/build-i386/madeira-i386-build.log "$LOGS/wine-i386-build.log" 2>/dev/null || true
        echo "WARNING: i386 farm build FAILED -- this IPA cannot run 32-bit games" \
             "(64-bit games are unaffected). Log: build-logs/wine-i386-build.log"
        grep -E "error:|Error [0-9]" wine/build-i386/madeira-i386-build.log 2>/dev/null | head -30 || true
        # Leave the folder empty rather than half-filled: a partial farm fails later,
        # per missing import, instead of at the clear "no i386-windows" message.
        find app/Madeira/i386-windows -type f ! -name .gitkeep -delete 2>/dev/null || true
        touch "$LOGS/wine-i386.FAILED"
    fi
}

# 64-bit (aarch64) WoW64 PE modules rebuilt from the pinned Wine with
# patches/wine-aarch64-*.patch, in place of the tracked prebuilt copies (the
# layout docs/WOW64.md, "Building", step 2 describes). The host tree already has
# the aarch64 PE rules: its configure finds llvm-mingw's aarch64 compiler. Only
# the modules a patch touches are rebuilt.
AARCH64_PE_MODULES="wow64win"
stage_wine_aarch64() {
    export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$MINGW_DIR/bin:$PATH"
    apply_wine_patches patches/wine-aarch64-*.patch
    local m t B=wine/build-macos
    for m in $AARCH64_PE_MODULES; do
        t="dlls/$m/aarch64-windows/$m.dll"
        grep -q "^$t" "$B/Makefile" || die "$B/Makefile has no rule for $t (no aarch64 PE compiler at configure?)"
        make -C "$B" -j"$JOBS" "$t" > "$LOGS/wine-aarch64-$m.log" 2>&1             || { grep -E "error|Error" "$LOGS/wine-aarch64-$m.log" | head -30; die "building $t failed"; }
        "$MINGW_DIR/bin/aarch64-w64-mingw32-strip" --strip-debug -o "app/Madeira/aarch64-windows/$m.dll" "$B/$t"
        echo "rebuilt aarch64-windows/$m.dll ($(wc -c < "app/Madeira/aarch64-windows/$m.dll" | tr -d ' ') bytes)"
    done
}

# The ARM64EC ntdll (the one x64 processes such as Madeira Dock's host load) rebuilt
# from the pinned Wine with patches/wine-arm64ec-*.patch, in place of the tracked
# prebuilt, with build/wine-pe/build-ntdll.sh's post-processing (strip, then pad to
# SizeOfImage + 0x50000). Its own tree: wine/build-arm64ec/include is a link to the
# host tree's (stage_ntdll_unix), so configuring there would overwrite the host
# config.h. Host tools come from wine/build-macos. Before the patches go in, the
# unpatched source is built once and compared with the tracked binary, so the log
# shows whether this tree reproduces it and any difference comes from the patches.
stage_wine_arm64ec() {
    compgen -G "patches/wine-arm64ec-*.patch" > /dev/null || { echo "no ARM64EC patches: tracked ntdll.dll kept"; return 0; }
    export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$MINGW_DIR/bin:$PATH"
    local B=wine/build-arm64ec-pe t=dlls/ntdll/arm64ec-windows/ntdll.dll
    local out=app/Madeira/arm64ec-windows/ntdll.dll p pending=0
    if [ ! -f "$B/config.status" ]; then
        mkdir -p "$B"
        (cd "$B" && ../configure --enable-archs=arm64ec --with-wine-tools="$R/wine/build-macos" \
            --without-x --without-vulkan --without-freetype --without-gnutls --disable-tests) \
            > "$LOGS/wine-arm64ec-configure.log" 2>&1 \
            || { tail -40 "$LOGS/wine-arm64ec-configure.log"; die "configuring the ARM64EC tree failed"; }
    fi
    grep -q "^$t" "$B/Makefile" || die "$B/Makefile has no rule for $t (no arm64ec compiler at configure?)"
    for p in patches/wine-arm64ec-*.patch; do
        git -C wine apply --reverse --check "$R/$p" 2>/dev/null || pending=1
    done
    if [ "$pending" = 1 ]; then
        if make -C "$B" -j"$JOBS" "$t" > "$LOGS/wine-arm64ec-unpatched.log" 2>&1; then
            { "$MINGW_DIR/bin/arm64ec-w64-mingw32-strip" -o "$LOGS/ntdll-unpatched.dll" "$B/$t" &&
              python3 tools/pe-sections.py pad-ntdll "$LOGS/ntdll-unpatched.dll" &&
              python3 tools/pe-sections.py compare "$LOGS/ntdll-unpatched.dll" "$out"; } \
                || echo "WARNING: could not compare the unpatched ARM64EC ntdll"
        else
            grep -E "error|Error" "$LOGS/wine-arm64ec-unpatched.log" | head -30 || true
            echo "WARNING: the unpatched ARM64EC ntdll did not build; no comparison"
        fi
    fi
    apply_wine_patches patches/wine-arm64ec-*.patch
    make -C "$B" -j"$JOBS" "$t" > "$LOGS/wine-arm64ec-ntdll.log" 2>&1 \
        || { grep -E "error|Error" "$LOGS/wine-arm64ec-ntdll.log" | head -30; die "building $t failed"; }
    "$MINGW_DIR/bin/arm64ec-w64-mingw32-strip" -o "$out.tmp" "$B/$t"
    python3 tools/pe-sections.py pad-ntdll "$out.tmp"
    # patches/wine-arm64ec-image-map-guard.patch reads this variable (a wide literal)
    python3 tools/pe-sections.py has-utf16 "$out.tmp" MADEIRA_IMAGE_MAP_GUARD \
        || die "the rebuilt ARM64EC ntdll.dll lacks the image-map guard"
    mv -f "$out.tmp" "$out"
    echo "rebuilt arm64ec-windows/ntdll.dll ($(wc -c < "$out" | tr -d ' ') bytes, image-map guard present)"
}

stage_pe() {
    [ "${BUILD_PE:-0}" = 1 ] || { echo "skipped: PE DLLs are tracked (set BUILD_PE=1 to rebuild)"; return 0; }
    build/fex-arm64ec/build.sh
    build/wine-pe/build-ntdll.sh
    build/madeira-d3d12/build-pe.sh
}

# Binary fixes to the tracked prebuilt PE modules (each script says what and why).
stage_pe_fixes() {
    python3 tools/patch-xtajit-cpuid.py
}

# Madeira Dock (docs/MADEIRA_DOCK.md): dockhost.exe is a gitignored build output;
# without it the app has no Dock button and the library no Steam section.
stage_dock() {
    # patches/madeira-dock-*.patch: the host's source changes this tree carries
    # ahead of the submodule pin (each patch says where it comes from).
    local p
    for p in patches/madeira-dock-*.patch; do
        [ -f "$p" ] || continue
        if git -C research/madeira-dock apply --reverse --check "$R/$p" 2>/dev/null; then
            echo "already applied: $p"
        else
            git -C research/madeira-dock apply "$R/$p" || die "cannot apply $p to research/madeira-dock"
            echo "applied: $p"
        fi
    done
    build/madeira-dock/build.sh
    [ -f app/Madeira/arm64ec-windows/dockhost.exe ] || die "dockhost.exe was not staged"
    # patches/madeira-dock-licence-wait.patch makes the poll pause alertable
    if [ -f patches/madeira-dock-licence-wait.patch ]; then
        grep -aq SleepEx app/Madeira/arm64ec-windows/dockhost.exe \
            || die "dockhost.exe lacks the alertable poll pause (SleepEx)"
        echo "dockhost.exe: alertable poll pause present"
    fi
}

stage_app() {
    local sign=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
    [ -z "${TEAM_ID:-}" ] || sign=(DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates)
    local rc=0
    # ENABLE_DEBUG_DYLIB=NO: since Xcode 15 a Debug build puts the code in
    # Madeira.debug.dylib behind a stub executable; keep it in the main binary, as an
    # archive/install build does, so DXMT's dlsym finds the macdrv exports there.
    xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath build/xcode "${sign[@]}" \
        ENABLE_DEBUG_DYLIB=NO build \
        > "$LOGS/xcodebuild.log" 2>&1 || rc=$?
    tail -5 "$LOGS/xcodebuild.log"
    if [ "$rc" != 0 ]; then
        # xcodebuild buries the diagnostics under huge compiler invocations, and linker
        # errors have no "error:" prefix (approach from madeira-bcd's build-ipa.yml).
        echo "===== compiler errors ====="
        grep -E "^[^ ].*: (error|fatal error):" "$LOGS/xcodebuild.log" | sort -u | head -30
        echo "===== linker diagnostics ====="
        grep -E "Undefined symbol|^ld: |symbol\(s\) not found|referenced from|duplicate symbol" \
            "$LOGS/xcodebuild.log" | head -40
        echo "===== failing build commands ====="
        sed -n '/The following build commands failed/,/failures)/p' "$LOGS/xcodebuild.log" | cut -c1-200 | head -15
        return "$rc"
    fi

    # DXMT finds the macdrv entry points with dlsym(RTLD_DEFAULT, ...), so they must be in
    # the main binary's export trie; if dead-stripped, every D3D11 game renders black with
    # no error (check from madeira-bcd's build-ipa.yml).
    local bin sym missing=""
    bin="$(find build/xcode/Build/Products -maxdepth 3 -path '*Madeira.app/Madeira' -type f | head -1)"
    ls -l "$(dirname "$bin")"/Madeira* 2>/dev/null
    xcrun dyld_info -exports "$bin" > "$LOGS/exports.txt" 2>&1 || true
    echo "dyld_info: $(wc -l < "$LOGS/exports.txt" | tr -d ' ') lines for $bin"
    for sym in macdrv_functions get_win_data release_win_data \
               macdrv_view_create_metal_view macdrv_view_get_metal_layer macdrv_view_release_metal_view; do
        grep -qE "_$sym\$" "$LOGS/exports.txt" && echo "  OK   $sym" || { echo "  MISS $sym"; missing="$missing $sym"; }
    done
    [ -z "$missing" ] || die "app binary does not export:$missing (DXMT would render black)"
}

stage_ipa() {
    local app; app="$(find build/xcode/Build/Products -maxdepth 2 -name Madeira.app | head -1)"
    [ -n "$app" ] || die "Madeira.app not found"
    rm -rf build/ipa && mkdir -p build/ipa/Payload
    cp -R "$app" build/ipa/Payload/
    # Update packs (docs/UPDATES.md): hash every Windows-side file in the bundle and
    # stamp the manifest's hash into Info.plist as this build's identity. A pack names
    # the build it was made for, and the app applies it only to that build.
    local a=build/ipa/Payload/Madeira.app base
    (cd "$a" && find aarch64-windows arm64ec-windows i386-windows -type f ! -name '.*' -print0 \
        | xargs -0 shasum -a 256 | LC_ALL=C sort -k2) > "$LOGS/pe-manifest.txt"
    base="$(shasum -a 256 "$LOGS/pe-manifest.txt" | cut -c1-64)"
    /usr/libexec/PlistBuddy -c "Delete :MadeiraPEBase" "$a/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :MadeiraPEBase string $base" "$a/Info.plist"
    echo "MadeiraPEBase=$base ($(wc -l < "$LOGS/pe-manifest.txt" | tr -d ' ') files)"
    # Unsigned builds carry no entitlements. Ad-hoc sign with the app's entitlements
    # (get-task-allow for StikDebug JIT attach, increased memory limit) so re-signing
    # tools like Sideloadly/AltStore see and keep them.
    if [ -z "${TEAM_ID:-}" ]; then
        codesign --force --sign - --entitlements app/Madeira/Madeira.entitlements build/ipa/Payload/Madeira.app
        codesign -d --entitlements - build/ipa/Payload/Madeira.app 2>/dev/null | head -20 || true
    fi
    (cd build/ipa && zip -qry Madeira.ipa Payload)
    ls -l build/ipa/Madeira.ipa
    echo "IPA: $R/build/ipa/Madeira.ipa (unsigned unless TEAM_ID was set; sign with Sideloadly/AltStore)"
}

for s in $ALL_STAGES; do run_stage "$s"; done
say "done"
