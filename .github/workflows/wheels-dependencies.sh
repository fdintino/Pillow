#!/bin/bash
# Define custom utilities
# Test for macOS with [ -n "$IS_MACOS" ]
if [ -z "$IS_MACOS" ]; then
    export MB_ML_LIBC=${AUDITWHEEL_POLICY::9}
    export MB_ML_VER=${AUDITWHEEL_POLICY:9}
fi
export PLAT="${CIBW_ARCHS:-$AUDITWHEEL_ARCH}"
source wheels/multibuild/common_utils.sh
source wheels/multibuild/library_builders.sh
if [ -z "$IS_MACOS" ]; then
    source wheels/multibuild/manylinux_utils.sh
fi

ARCHIVE_SDIR=pillow-depends-main

# Package versions for fresh source builds
FREETYPE_VERSION=2.13.2
HARFBUZZ_VERSION=10.0.1
LIBPNG_VERSION=1.6.44
JPEGTURBO_VERSION=3.0.4
OPENJPEG_VERSION=2.5.2
XZ_VERSION=5.6.3
TIFF_VERSION=4.6.0
LCMS2_VERSION=2.16
if [[ -n "$IS_MACOS" ]]; then
    GIFLIB_VERSION=5.2.2
else
    GIFLIB_VERSION=5.2.1
fi
if [[ -n "$IS_MACOS" ]] || [[ "$MB_ML_VER" != 2014 ]]; then
    ZLIB_VERSION=1.3.1
else
    ZLIB_VERSION=1.2.8
fi
LIBWEBP_VERSION=1.4.0
BZIP2_VERSION=1.0.8
LIBXCB_VERSION=1.17.0
BROTLI_VERSION=1.1.0
LIBAVIF_VERSION=1.1.1
RAV1E_VERSION=0.7.1

function build_brotli {
    local cmake=$(get_modern_cmake)
    local out_dir=$(fetch_unpack https://github.com/google/brotli/archive/v$BROTLI_VERSION.tar.gz brotli-$BROTLI_VERSION.tar.gz)
    (cd $out_dir \
        && $cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
        && make install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libbrotli* /usr/local/lib
        cp /usr/local/lib64/pkgconfig/libbrotli* /usr/local/lib/pkgconfig
    fi
}

function build_harfbuzz {
    python3 -m pip install meson ninja

    local out_dir=$(fetch_unpack https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/$HARFBUZZ_VERSION.tar.xz harfbuzz-$HARFBUZZ_VERSION.tar.xz)
    (cd $out_dir \
        && meson setup build --buildtype=release -Dfreetype=enabled -Dglib=disabled)
    (cd $out_dir/build \
        && meson install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libharfbuzz* /usr/local/lib
    fi
}

function install_rav1e {
    if [ -n "$IS_MACOS" ]; then
        suffix="macos"
        if [[ "$PLAT" == "arm64" ]]; then
            suffix+="-aarch64"
        fi
    else
        suffix="linux"
        if [[ "$PLAT" == "aarch64" ]]; then
            suffix+="-aarch64"
        else
            suffix+="-generic"
        fi
    fi

    curl -sLo - \
        https://github.com/xiph/rav1e/releases/download/v$RAV1E_VERSION/librav1e-$RAV1E_VERSION-$suffix.tar.gz \
        | tar -C $BUILD_PREFIX --exclude LICENSE --exclude LICENSE --exclude '*.so' --exclude '*.dylib' -zxf -

    if [ -z "$IS_MACOS" ]; then
        sed -i 's/-lgcc_s/-lgcc_eh/g' "${BUILD_PREFIX}/lib/pkgconfig/rav1e.pc"
    fi

    # Force libavif to treat system rav1e as if it were local
    mkdir -p /tmp/cmake/Modules
    cat <<EOF > /tmp/cmake/Modules/Findrav1e.cmake
    add_library(rav1e::rav1e STATIC IMPORTED GLOBAL)
    set_target_properties(rav1e::rav1e PROPERTIES
        IMPORTED_LOCATION "$BUILD_PREFIX/lib/librav1e.a"
        AVIF_LOCAL ON
        INTERFACE_INCLUDE_DIRECTORIES "$BUILD_PREFIX/include/rav1e"
    )
EOF
}

function build_libavif {
    install_rav1e
    python -m pip install meson ninja

    if [[ "$PLAT" == "x86_64" ]]; then
        build_simple nasm 2.16.03 https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/
    fi

    local cmake=$(get_modern_cmake)
    local out_dir=$(fetch_unpack https://github.com/AOMediaCodec/libavif/archive/refs/tags/v$LIBAVIF_VERSION.tar.gz libavif-$LIBAVIF_VERSION.tar.gz)

    (cd $out_dir \
        && $cmake \
            -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
            -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DAVIF_LIBSHARPYUV=LOCAL \
            -DAVIF_LIBYUV=LOCAL \
            -DAVIF_CODEC_RAV1E=SYSTEM \
            -DAVIF_CODEC_AOM=LOCAL \
            -DAVIF_CODEC_DAV1D=LOCAL \
            -DAVIF_CODEC_SVT=LOCAL \
            -DENABLE_NASM=ON \
            -DCMAKE_MODULE_PATH=/tmp/cmake/Modules \
            . \
        && make install)

    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libavif.a /usr/local/lib
        cp /usr/local/lib64/pkgconfig/libavif.pc /usr/local/lib/pkgconfig
    fi
}

function build {
    if [[ -n "$IS_MACOS" ]] && [[ "$CIBW_ARCHS" == "arm64" ]]; then
        sudo chown -R runner /usr/local
    fi
    build_xz
    if [ -z "$IS_ALPINE" ] && [ -z "$IS_MACOS" ]; then
        yum remove -y zlib-devel
    fi
    build_new_zlib

    ORIGINAL_LDFLAGS=$LDFLAGS
    if [[ -n "$IS_MACOS" ]] && [[ "$CIBW_ARCHS" == "arm64" ]]; then
        LDFLAGS="${LDFLAGS} -ld64"
    fi
    build_libavif
    LDFLAGS=$ORIGINAL_LDFLAGS

    build_simple xcb-proto 1.17.0 https://xorg.freedesktop.org/archive/individual/proto
    if [ -n "$IS_MACOS" ]; then
        build_simple xorgproto 2024.1 https://www.x.org/pub/individual/proto
        build_simple libXau 1.0.11 https://www.x.org/pub/individual/lib
        build_simple libpthread-stubs 0.5 https://xcb.freedesktop.org/dist
        if [[ "$CIBW_ARCHS" == "arm64" ]]; then
            cp /usr/local/share/pkgconfig/xcb-proto.pc /usr/local/lib/pkgconfig
        fi
    else
        sed s/\${pc_sysrootdir\}// /usr/local/share/pkgconfig/xcb-proto.pc > /usr/local/lib/pkgconfig/xcb-proto.pc
    fi
    build_simple libxcb $LIBXCB_VERSION https://www.x.org/releases/individual/lib

    build_libjpeg_turbo
    build_tiff
    build_libpng
    build_lcms2
    build_openjpeg
    if [ -f /usr/local/lib64/libopenjp2.so ]; then
        cp /usr/local/lib64/libopenjp2.so /usr/local/lib
    fi

    ORIGINAL_CFLAGS=$CFLAGS
    CFLAGS="$CFLAGS -O3 -DNDEBUG"
    if [[ -n "$IS_MACOS" ]]; then
        CFLAGS="$CFLAGS -Wl,-headerpad_max_install_names"
    fi
    build_libwebp
    CFLAGS=$ORIGINAL_CFLAGS

    build_brotli

    if [ -n "$IS_MACOS" ]; then
        # Custom freetype build
        build_simple freetype $FREETYPE_VERSION https://download.savannah.gnu.org/releases/freetype tar.gz --with-harfbuzz=no
    else
        build_freetype
    fi

    build_harfbuzz
}

# Any stuff that you need to do before you start building the wheels
# Runs in the root directory of this repository.
curl -fsSL -o pillow-depends-main.zip https://github.com/python-pillow/pillow-depends/archive/main.zip
untar pillow-depends-main.zip

if [[ -n "$IS_MACOS" ]]; then
  # libtiff and libxcb cause a conflict with building libtiff and libxcb
  # libxau and libxdmcp cause an issue on macOS < 11
  # remove cairo to fix building harfbuzz on arm64
  # remove lcms2 and libpng to fix building openjpeg on arm64
  # remove jpeg-turbo to avoid inclusion on arm64
  # remove webp and zstd to avoid inclusion on x86_64
  # remove aom and libavif to fix building on arm64
  # curl from brew requires zstd, use system curl
  brew remove --ignore-dependencies libpng libtiff libxcb libxau libxdmcp curl cairo lcms2 zstd
  if [[ "$CIBW_ARCHS" == "arm64" ]]; then
    brew remove --ignore-dependencies jpeg-turbo
  else
    brew remove --ignore-dependencies webp aom libavif
  fi

  brew install pkg-config

  # clear bash path cache for curl
  hash -d curl
fi

wrap_wheel_builder build

# Append licenses
for filename in wheels/dependency_licenses/*; do
  echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> LICENSE
  cat $filename >> LICENSE
done
