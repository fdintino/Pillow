#!/bin/bash
# Define custom utilities
# Test for macOS with [ -n "$IS_MACOS" ]
if [ -z "$IS_MACOS" ]; then
    export MB_ML_LIBC=${AUDITWHEEL_POLICY::9}
    export MB_ML_VER=${AUDITWHEEL_POLICY:9}
fi
export PLAT=$CIBW_ARCHS
source wheels/multibuild/common_utils.sh
source wheels/multibuild/library_builders.sh
if [ -z "$IS_MACOS" ]; then
    source wheels/multibuild/manylinux_utils.sh
fi

ARCHIVE_SDIR=pillow-depends-main

# Package versions for fresh source builds
FREETYPE_VERSION=2.13.2
HARFBUZZ_VERSION=8.5.0
LIBPNG_VERSION=1.6.43
JPEGTURBO_VERSION=3.0.3
OPENJPEG_VERSION=2.5.2
XZ_VERSION=5.4.5
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

if [[ -n "$IS_MACOS" ]] && [[ "$CIBW_ARCHS" == "x86_64" ]]; then
    function build_openjpeg {
        local out_dir=$(fetch_unpack https://github.com/uclouvain/openjpeg/archive/v${OPENJPEG_VERSION}.tar.gz openjpeg-${OPENJPEG_VERSION}.tar.gz)
        (cd $out_dir \
            && cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
            && make install)
        touch openjpeg-stamp
    }
fi

function build_brotli {
    local cmake=$(get_modern_cmake)
    local out_dir=$(fetch_unpack https://github.com/google/brotli/archive/v$BROTLI_VERSION.tar.gz brotli-1.1.0.tar.gz)
    (cd $out_dir \
        && $cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
        && make install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libbrotli* /usr/local/lib
        cp /usr/local/lib64/pkgconfig/libbrotli* /usr/local/lib/pkgconfig
    fi
}

function install_rav1e {
    if [[ -n "$IS_MACOS" ]] && [[ "$CIBW_ARCHS" == "arm64" ]]; then
        librav1e_tgz=librav1e-${RAV1E_VERSION}-macos-aarch64.tar.gz
    elif [ -n "$IS_MACOS" ]; then
        librav1e_tgz=librav1e-${RAV1E_VERSION}-macos.tar.gz
    elif [ "$CIBW_ARCHS" == "aarch64" ]; then
        librav1e_tgz=librav1e-${RAV1E_VERSION}-linux-aarch64.tar.gz
    else
        librav1e_tgz=librav1e-${RAV1E_VERSION}-linux-generic.tar.gz
    fi

    curl -sLo - \
        https://github.com/xiph/rav1e/releases/download/v$RAV1E_VERSION/$librav1e_tgz \
        | tar -C $BUILD_PREFIX --exclude LICENSE --exclude LICENSE --exclude '*.so' --exclude '*.dylib' -zxf -

    if [ ! -n "$IS_MACOS" ]; then
        sed -i 's/-lgcc_s/-lgcc_eh/g' "${BUILD_PREFIX}/lib/pkgconfig/rav1e.pc"
    fi

    # Force libavif to treat system rav1e as if it were local
    local cmake=$(get_modern_cmake)
    local cmake_root=`$cmake --system-information 2>&1 | grep CMAKE_ROOT | grep -v CMAKE_ROOT:INTERNAL | sed -e s/\"//g -e 's/CMAKE_ROOT //g'`
    cat <<EOF > $cmake_root/Modules/Findrav1e.cmake
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
    $PYTHON_EXE -m pip install meson

    if [[ "$CIBW_ARCHS" != "arm64" ]]; then
        build_simple nasm 2.15.05 https://www.nasm.us/pub/nasm/releasebuilds/2.15.05/
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
            -DCMAKE_MACOSX_RPATH=OFF \
            . \
        && make install)
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

    if [ -z "$IS_MACOS" ]; then
        export FREETYPE_LIBS=-lfreetype
        export FREETYPE_CFLAGS=-I/usr/local/include/freetype2/
    fi
    build_simple harfbuzz $HARFBUZZ_VERSION https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION tar.xz --with-freetype=yes --with-glib=no
    if [ -z "$IS_MACOS" ]; then
        export FREETYPE_LIBS=""
        export FREETYPE_CFLAGS=""
    fi
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
  brew remove --ignore-dependencies libpng libtiff libxcb libxau libxdmcp curl cairo lcms2 zstd aom libavif
  if [[ "$CIBW_ARCHS" == "arm64" ]]; then
    brew remove --ignore-dependencies jpeg-turbo
  else
    brew remove --ignore-dependencies webp
  fi

  brew install pkg-config
fi

wrap_wheel_builder build

# Append licenses
for filename in wheels/dependency_licenses/*; do
  echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> LICENSE
  cat $filename >> LICENSE
done
