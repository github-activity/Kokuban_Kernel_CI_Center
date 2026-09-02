#!/usr/bin/env bash
#
# Build a statically linked OpenZFS userland (zpool/zfs/zdb/...) for Android arm64.
#
# Android uses bionic, not glibc, so the tools are linked fully static against
# musl instead. That needs the four libraries OpenZFS hard-requires for
# --with-config=user, cross-built first: zlib, libuuid + libblkid (util-linux),
# libtirpc (musl has no sunrpc XDR), and libcrypto (OpenSSL).
#
# usage: build_zfs_userland.sh <zfs-tag> <jobs> <output-dir>

set -euo pipefail

ZFS_TAG="${1:?usage: build_zfs_userland.sh <zfs-tag> <jobs> <output-dir>}"
JOBS="${2:-4}"
OUTDIR="${3:?output directory required}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

TRIPLE=aarch64-unknown-linux-musl
MUSL_CROSS_RELEASE="${MUSL_CROSS_RELEASE:-20260823}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
UTIL_LINUX_VER="${UTIL_LINUX_VER:-2.40.4}"
TIRPC_VER="${TIRPC_VER:-1.3.6}"
OPENSSL_VER="${OPENSSL_VER:-3.0.16}"

WORK="$PWD/.zfs_userland"
SYSROOT="$WORK/sysroot"
STAGE="$WORK/stage"

rm -rf "$WORK"
mkdir -p "$WORK/src" "$SYSROOT" "$STAGE"
cd "$WORK"

log() { printf '\n=== %s\n' "$*"; }

log "Fetching musl cross toolchain ($TRIPLE)"
curl -fsSL -o musl-cross.tar.xz \
  "https://github.com/cross-tools/musl-cross/releases/download/${MUSL_CROSS_RELEASE}/${TRIPLE}.tar.xz"
tar xf musl-cross.tar.xz
# Do not assume the archive's top-level directory name.
TOOLCHAIN_BIN="$(dirname "$(find "$WORK" -type f -name "${TRIPLE}-gcc" -perm -u+x | head -n1)")"
[ -n "$TOOLCHAIN_BIN" ] || { echo "musl toolchain not found after extraction" >&2; exit 1; }
export PATH="$TOOLCHAIN_BIN:$PATH"

export CC="${TRIPLE}-gcc"
export CXX="${TRIPLE}-g++"
export AR="${TRIPLE}-ar"
export RANLIB="${TRIPLE}-ranlib"
export STRIP="${TRIPLE}-strip"
export LD="${TRIPLE}-ld"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
export CPPFLAGS="-I$SYSROOT/include"
export LDFLAGS="-L$SYSROOT/lib"
"$CC" --version | head -n1

fetch() { curl -fsSL -o "src/$2" "$1" && tar xf "src/$2" -C src; }

log "Building zlib $ZLIB_VER"
fetch "https://zlib.net/fossils/zlib-${ZLIB_VER}.tar.gz" "zlib.tar.gz"
( cd "src/zlib-${ZLIB_VER}" && ./configure --static --prefix="$SYSROOT" && make -j"$JOBS" && make install )

log "Building util-linux $UTIL_LINUX_VER (libuuid + libblkid)"
UL_SERIES="${UTIL_LINUX_VER%.*}"
fetch "https://www.kernel.org/pub/linux/utils/util-linux/v${UL_SERIES}/util-linux-${UTIL_LINUX_VER}.tar.xz" "util-linux.tar.xz"
( cd "src/util-linux-${UTIL_LINUX_VER}" && ./configure \
    --host="$TRIPLE" --prefix="$SYSROOT" \
    --disable-shared --enable-static \
    --disable-all-programs --enable-libuuid --enable-libblkid \
    --disable-nls --without-python --without-systemd --without-udev \
  && make -j"$JOBS" && make install )

log "Building libtirpc $TIRPC_VER"
fetch "https://downloads.sourceforge.net/libtirpc/libtirpc-${TIRPC_VER}.tar.bz2" "libtirpc.tar.bz2"
( cd "src/libtirpc-${TIRPC_VER}" && ./configure \
    --host="$TRIPLE" --prefix="$SYSROOT" \
    --disable-shared --enable-static --disable-gssapi \
  && make -j"$JOBS" && make install )

log "Building OpenSSL $OPENSSL_VER (libcrypto)"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" "openssl.tar.gz"
( cd "src/openssl-${OPENSSL_VER}" && ./Configure linux-aarch64 \
    no-shared no-dso no-tests no-engine \
    --prefix="$SYSROOT" --openssldir="$SYSROOT/ssl" \
    --cross-compile-prefix="${TRIPLE}-" \
  && make -j"$JOBS" && make install_sw )

log "Building OpenZFS $ZFS_TAG userland"
git clone --depth 1 --branch "$ZFS_TAG" https://github.com/openzfs/zfs.git src/zfs
cd src/zfs
./autogen.sh
# /etc and /var are read-only on Android, so point the writable state
# (zpool.cache, hostid) somewhere the module loader can actually use.
./configure \
  --host="$TRIPLE" \
  --with-config=user \
  --enable-static --disable-shared \
  --prefix=/system \
  --sysconfdir=/data/adb/zfs/etc \
  --localstatedir=/data/adb/zfs/var \
  --with-tirpc \
  --disable-pam --without-python --disable-pyzfs \
  --disable-systemd --disable-sysvinit \
  --with-udevdir="$STAGE/udev" \
  --with-mounthelperdir="/system/bin" \
  LDFLAGS="$LDFLAGS -static"
make -j"$JOBS"
make install DESTDIR="$STAGE"

log "Collecting static binaries"
found=0
while IFS= read -r binary; do
  file "$binary" | grep -q "ELF 64-bit LSB.*ARM aarch64" || continue
  if ! file "$binary" | grep -q "statically linked"; then
    echo "REFUSING: $(basename "$binary") is not statically linked" >&2
    file "$binary" >&2
    exit 1
  fi
  "$STRIP" "$binary" 2>/dev/null || true
  cp "$binary" "$OUTDIR/"
  echo "  $(basename "$binary")  $(stat -c %s "$binary") bytes"
  found=$((found + 1))
done < <(find "$STAGE" -type f -perm -u+x)

[ "$found" -gt 0 ] || { echo "no userland binaries were produced" >&2; exit 1; }
log "Collected $found static binaries into $OUTDIR"
