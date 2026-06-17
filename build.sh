#!/bin/env bash

set -e
set -o pipefail

# ════════════════════════════════════════════════════════════════
#  S21 FE (Snapdragon - r9q2) Raw Image Kernel Build Script
# ════════════════════════════════════════════════════════════════


# ─────────────────────────────────────────────────────────────────
#  § 0 — CONFIGURATION
# ─────────────────────────────────────────────────────────────────

# ── Target Device Info ───────────────────────────────────────────
VARIANT="r9q2"
DEVICE="S21FE"
NK_DEFCONFIG="eureka/r9q_eur_openx2_defconfig"

# ── Base Stock Release ZIP URL ───────────────────────────────────
# Downloads the zip and extracts boot.img and vendor_boot.img from eureka/
NK_RELEASE_ZIP_URL="https://github.com/saadelasfur/eureka_releases/releases/download/20251229/Eureka_RKSU-v3.0.0_20251229_r9q2.zip"

# ── Clang Toolchain (Clang 19.0.0 - r530567) ─────────────────────
NK_CLANG_VERSION="clang-r530567"
NK_CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz"


# ─────────────────────────────────────────────────────────────────
#  § 1 — CONSTANTS & STYLES
# ─────────────────────────────────────────────────────────────────

BOLD="\e[1m";  RESET="\e[0m";  DIM="\e[2m"
CYAN="\e[1;36m";  GREEN="\e[1;32m";  YELLOW="\e[1;33m"
RED="\e[1;31m"


# ─────────────────────────────────────────────────────────────────
#  § 2 — LOGGING
# ─────────────────────────────────────────────────────────────────

log_group_start() {
    echo -e "\n${CYAN}${BOLD}╔════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  $1  $2${RESET}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${RESET}"
}
log_step() { echo -e "${GREEN}${BOLD}  ➤  $1${RESET}"; }
log_info() { echo -e "${DIM}       $1${RESET}"; }
log_ok()   { echo -e "${GREEN}  ✔   $1${RESET}"; }
log_err()  { echo -e "${RED}${BOLD}  ✖   $1${RESET}" >&2; }
log_kv()   { printf "  ${DIM}%-14s${RESET} ${BOLD}%s${RESET}\n" "$1" "$2"; }
log_sep()  { echo -e "${DIM}  ────────────────────────────────────────${RESET}"; }
elapsed()  { date -u -d @$(( $(date +%s) - $1 )) +'%-Mm %-Ss'; }
ts()       { date '+%H:%M:%S'; }


# ─────────────────────────────────────────────────────────────────
#  § 3 — CORE UTILITIES
# ─────────────────────────────────────────────────────────────────

check_dependencies() {
    log_group_start "🔍" "Dependency Check"
    local missing=false
    for tool in git curl wget unzip tar lz4 awk sed zip patch; do
        if command -v "$tool" &>/dev/null; then
            log_info "$(printf '%-14s' "$tool")✔  $(command -v "$tool")"
        else
            log_err "Missing tool: '$tool'"
            missing=true
        fi
    done
    $missing && { log_err "Install missing tools and retry."; exit 1; }
    log_ok "All dependencies satisfied"
}

init_vars() {
    SRC_DIR="$(pwd)"
    OUT_DIR="$SRC_DIR/out"
    TC_DIR="$HOME/toolchains"
    JOBS=$(nproc)
    
    CLANGVER="${NK_CLANG_VERSION}"
    CLANG_PREBUILT_BIN="$TC_DIR/$CLANGVER/bin/"
    export SRC_DIR OUT_DIR TC_DIR JOBS CLANGVER CLANG_PREBUILT_BIN
    export PATH="$TC_DIR:$CLANG_PREBUILT_BIN:$PATH"
}


# ─────────────────────────────────────────────────────────────────
#  § 4 — BUILD PHASES
# ─────────────────────────────────────────────────────────────────

fetch_tools() {
    log_group_start "🧰" "Toolchain & Assets"
    mkdir -p "$TC_DIR"

    # Fetch Clang 19 (r530567) from AOSP upstream
    if [[ ! -d "$CLANG_PREBUILT_BIN" ]]; then
        log_step "Downloading Google AOSP Clang ($CLANGVER)..."
        mkdir -p "$TC_DIR/$CLANGVER"
        # Using curl for the GoogleSource web archive download stream
        curl -L "${NK_CLANG_URL}" -o "$TC_DIR/$CLANGVER.tar.gz"
        tar -xf "$TC_DIR/$CLANGVER.tar.gz" -C "$TC_DIR/$CLANGVER"
        rm -f "$TC_DIR/$CLANGVER.tar.gz"
        log_ok "Clang 19 ready"
    else
        log_ok "Clang 19 — cached ✓"
    fi

    # Fetch magiskboot
    if [[ ! -f "$TC_DIR/magiskboot" ]]; then
        log_step "Fetching magiskboot..."
        local apk_url
        apk_url="$(curl -s "https://api.github.com/repos/topjohnwu/Magisk/releases" \
            | grep -oE 'https://[^"]+\.apk' | grep 'Magisk[-.]v' | head -n1)"
        wget -q --show-progress "$apk_url" -O "$TC_DIR/magisk.apk"
        unzip -p "$TC_DIR/magisk.apk" "lib/x86_64/libmagiskboot.so" > "$TC_DIR/magiskboot"
        chmod +x "$TC_DIR/magiskboot"
        rm "$TC_DIR/magisk.apk"
        log_ok "magiskboot ready"
    else
        log_ok "magiskboot — cached ✓"
    fi

    # Fetch avbtool
    if [[ ! -f "$TC_DIR/avbtool" ]]; then
        log_step "Fetching avbtool..."
        curl -s "https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py?format=TEXT" \
            | base64 --decode > "$TC_DIR/avbtool"
        chmod +x "$TC_DIR/avbtool"
        log_ok "avbtool ready"
    else
        log_ok "avbtool — cached ✓"
    fi

    # Fetch and Extract Base Images from the Eureka ZIP
    log_step "Downloading baseline release zip..."
    local IMG_TARGET_DIR="$TC_DIR/images/$DEVICE"
    mkdir -p "$IMG_TARGET_DIR"
    
    local ZIP_PATH="$TC_DIR/eureka_base.zip"
    wget -q --show-progress "$NK_RELEASE_ZIP_URL" -O "$ZIP_PATH"
    
    log_step "Extracting boot images from zip structure (eureka/*.img)..."
    unzip -j -o "$ZIP_PATH" "eureka/boot.img" -d "$IMG_TARGET_DIR"
    unzip -j -o "$ZIP_PATH" "eureka/vendor_boot.img" -d "$IMG_TARGET_DIR"
    
    rm -f "$ZIP_PATH"
    log_ok "Base images successfully prepared from release zip."
}

build_kernel() {
    log_group_start "🔨" "Kernel Compile  [$(ts)]"
    export ARCH=arm64
    export CLANG_TRIPLE=aarch64-linux-gnu-
    export CROSS_COMPILE=aarch64-linux-gnu-

    # Setup standard QCOM flags matching your target architecture 
    export LLVM=1 DEPMOD=depmod
    export KCFLAGS="${KCFLAGS} -D__ANDROID_COMMON_KERNEL__ -fintegrated-as"
    
    COMREV=$(git rev-parse --short HEAD)
    export LOCALVERSION="-EurekaKernel-${COMREV}-${VARIANT}"

    log_sep
    log_kv "Device:"    "$DEVICE ($VARIANT)"
    log_kv "Defconfig:" "$NK_DEFCONFIG"
    log_kv "Version:"   "$LOCALVERSION"
    log_kv "Toolchain:" "$(clang --version | head -n1)"
    log_kv "Jobs:"      "$JOBS"
    log_sep

    local T0=$(date +%s)

    log_step "make clean..."
    [[ -d "$OUT_DIR" ]] && make -j"$JOBS" -C "$SRC_DIR" O="$OUT_DIR" clean 2>&1 | sed 's/^/       /'

    log_step "make defconfig..."
    make -j"$JOBS" -C "$SRC_DIR" O="$OUT_DIR" DEFCONFIG="$SRC_DIR/arch/arm64/configs/eureka/r9q_eur_openx2_defconfig" defconfig 2>&1 | sed 's/^/       /'
    
    log_step "make kernel..."
    make -j"$JOBS" -C "$SRC_DIR" O="$OUT_DIR" 2>&1 | sed 's/^/       /'

    log_ok "Kernel compiled in $(elapsed $T0)"
}

build_modules() {
    log_group_start "📦" "Modules Packing [$(ts)]"
    local T0=$(date +%s)

    make -j"$JOBS" -C "$SRC_DIR" O="$OUT_DIR" \
        INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install 2>&1 | sed 's/^/       /'

    MODOUT="$TC_DIR/EurekaOut/$DEVICE/modules"
    mkdir -p "$MODOUT"
    find "$OUT_DIR/modules" -name '*.ko' -exec cp '{}' "$MODOUT/" \;

    local KREL
    KREL=$(cat "$OUT_DIR/include/config/kernel.release")
    local MODLIB="$OUT_DIR/modules/lib/modules/$KREL"
    
    [[ -f "$MODLIB/modules.alias" ]] && cp "$MODLIB/modules.alias" "$MODOUT/"
    [[ -f "$MODLIB/modules.dep" ]] && cp "$MODLIB/modules.dep" "$MODOUT/"
    [[ -f "$MODLIB/modules.softdep" ]] && cp "$MODLIB/modules.softdep" "$MODOUT/"
    
    if [[ -f "$MODLIB/modules.order" ]]; then
        cp "$MODLIB/modules.order" "$MODOUT/modules.load"
        sed -i 's|.*\/||g' "$MODOUT/modules.load"
    fi

    if [[ -f "$MODOUT/modules.dep" ]]; then
        sed -i 's|\(kernel\/[^: ]*\/\)\([^: ]*\.ko\)|/lib/modules/\2|g' "$MODOUT/modules.dep"
    fi

    local KO_COUNT
    KO_COUNT=$(find "$MODOUT" -name '*.ko' | wc -l)
    log_ok "Modules processed — ${KO_COUNT} .ko files  ($(elapsed $T0))"
}

stage_artifacts() {
    log_group_start "🗂️" "Staging Flashable Structure"
    ZIP_DIR="$TC_DIR/EurekaOut/$DEVICE/ZIP"
    IMG_DIR="$ZIP_DIR/images"
    
    mkdir -p "$IMG_DIR" "$ZIP_DIR/META-INF/com/google/android"

    echo "# Dummy file" > "$ZIP_DIR/META-INF/com/google/android/updater-script"

cat >"$ZIP_DIR/META-INF/com/google/android/update-binary" <<'FLASH_EOF'
#!/sbin/sh
OUTFD=/proc/self/fd/$2
ZIPFILE="$3"
TMPDIR="/cache/eureka_tmp"

package_extract_dir() {
    local entry outfile
    for entry in $(unzip -l "$ZIPFILE" 2>/dev/null | tail -n+4 | grep -v '/$' \
                   | grep -o " $1.*$" | cut -c2-); do
        outfile="$(echo "$entry" | sed "s|${1}|${2}|")"
        mkdir -p "$(dirname "$outfile")"
        unzip -o "$ZIPFILE" "$entry" -p > "$outfile"
    done
}

ui_print() {
    echo "ui_print $1" >> "$OUTFD"
    echo "ui_print" >> "$OUTFD"
}

mount -o rw,remount -t auto /cache
mkdir -p "$TMPDIR"

ui_print "→ Extracting images..."
package_extract_dir "images" "$TMPDIR/"

ui_print "→ Flashing custom boot.img..."
dd if="$TMPDIR/boot.img" of=/dev/block/by-name/boot

ui_print "→ Flashing custom vendor_boot.img..."
dd if="$TMPDIR/vendor_boot.img" of=/dev/block/by-name/vendor_boot

rm -rf "$TMPDIR"
ui_print "→ Custom Kernel Installed Safely!"
FLASH_EOF

    chmod +x "$ZIP_DIR/META-INF/com/google/android/update-binary"
    log_ok "Installer architecture staged."
}

gki_repack() {
    log_group_start "🖼️" "Image Repack with magiskboot"
    local T0=$(date +%s)
    local DEST="$TC_DIR/EurekaOut/$DEVICE"
    mkdir -p "$DEST"

    log_step "Modifying boot.img..."
    cp "$TC_DIR/images/$DEVICE/boot.img" "$DEST/boot.img"
    avbtool erase_footer --image "$DEST/boot.img"
    (
        mkdir -p "$DEST/tmp" && cd "$DEST/tmp"
        magiskboot unpack ../boot.img
        rm -f kernel && cp "$OUT_DIR/arch/arm64/boot/Image" kernel
        magiskboot repack ../boot.img boot.img
        rm ../boot.img && mv boot.img ../boot.img
        cd .. && rm -rf tmp
    )

    log_step "Modifying vendor_boot.img..."
    cp "$TC_DIR/images/$DEVICE/vendor_boot.img" "$DEST/vendor_boot.img"
    avbtool erase_footer --image "$DEST/vendor_boot.img"
    (
        mkdir -p "$DEST/tmp" && cd "$DEST/tmp"
        magiskboot unpack -h ../vendor_boot.img || true
        
        # Strip old modules and insert the freshly built ones
        magiskboot cpio ramdisk.cpio "rm -r lib/modules"
        magiskboot cpio ramdisk.cpio "mkdir 0755 lib/modules"
        for f in "$DEST/modules/"*; do
            magiskboot cpio ramdisk.cpio "add 0644 lib/modules/$(basename "$f") $f"
        done

        magiskboot repack ../vendor_boot.img vendor_boot.img
        rm ../vendor_boot.img && mv vendor_boot.img ../vendor_boot.img
        cd .. && rm -rf tmp
    )
    log_ok "Images safely repacked in $(elapsed $T0)"
}

gen_zip() {
    log_group_start "🤐" "Packaging Flashable Zip File"
    local T0=$(date +%s)
    local REPACK_SRC="$TC_DIR/EurekaOut/$DEVICE"
    
    cp -a "$REPACK_SRC/boot.img"        "$IMG_DIR/"
    cp -a "$REPACK_SRC/vendor_boot.img" "$IMG_DIR/"

    local ZIPNAME="EurekaKernel_$(date +%Y%m%d)_${VARIANT}.zip"
    local ZIPOUT="$REPACK_SRC/$ZIPNAME"

    log_step "Zipping payload into $ZIPNAME..."
    ( cd "$ZIP_DIR"; zip -r -9 "$ZIPOUT" images META-INF )
    rm -rf "$ZIP_DIR"

    local SIZE SHA
    SIZE=$(du -sh "$ZIPOUT" | cut -f1)
    SHA=$(sha256sum "$ZIPOUT" | awk '{print $1}')

    log_sep
    log_kv "📦 Output:"  "$ZIPNAME"
    log_kv "📏 Size:"    "$SIZE"
    log_kv "🔑 SHA256:"  "${SHA:0:16}...${SHA: -8}"
    log_kv "⏱  Time:"   "$(elapsed $T0)"
    log_sep
}


# ─────────────────────────────────────────────────────────────────
#  § 5 — ENTRY POINT
# ─────────────────────────────────────────────────────────────────

check_dependencies
init_vars
fetch_tools
build_kernel
build_modules
stage_artifacts
gki_repack
gen_zip

echo -e "\n${GREEN}${BOLD} 🚀 Build Task Successfully Executed Without Interruptions!${RESET}\n"
