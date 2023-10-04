# Define custom utilities
# Test for macOS with [ -n "$IS_MACOS" ]

ARCHIVE_SDIR=pillow-depends-main

# Package versions for fresh source builds
FREETYPE_VERSION=2.13.2
HARFBUZZ_VERSION=8.2.0
LIBPNG_VERSION=1.6.40
JPEGTURBO_VERSION=3.0.0
OPENJPEG_VERSION=2.5.0
XZ_VERSION=5.4.4
TIFF_VERSION=4.5.1
LCMS2_VERSION=2.15
if [[ -n "$IS_MACOS" ]]; then
    GIFLIB_VERSION=5.1.4
else
    GIFLIB_VERSION=5.2.1
fi
if [[ -n "$IS_MACOS" ]] || [[ "$MB_ML_VER" != 2014 ]]; then
    ZLIB_VERSION=1.3
else
    ZLIB_VERSION=1.2.8
fi
LIBWEBP_VERSION=1.3.2
BZIP2_VERSION=1.0.8
LIBXCB_VERSION=1.16
BROTLI_VERSION=1.1.0
NASM_VERSION=2.15.05
DAV1D_VERSION=1.2.1
RAV1E_VERSION=p20230926
LIBYUV_SHA=464c51a0
LIBAVIF_VERSION=04bde5f331064112e230a4de2b0bcb7ebf82bb0c

if [[ -n "$IS_MACOS" ]] && [[ "$PLAT" == "x86_64" ]]; then
    function build_openjpeg {
        local out_dir=$(fetch_unpack https://github.com/uclouvain/openjpeg/archive/v${OPENJPEG_VERSION}.tar.gz)
        (cd $out_dir \
            && cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
            && make install)
        touch openjpeg-stamp
    }
fi

function build_brotli {
    local cmake=$(get_modern_cmake)
    local out_dir=$(fetch_unpack https://github.com/google/brotli/archive/v$BROTLI_VERSION.tar.gz)
    (cd $out_dir \
        && $cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
        && make install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libbrotli* /usr/local/lib
        cp /usr/local/lib64/pkgconfig/libbrotli* /usr/local/lib/pkgconfig
    fi
}

function build_nasm {
    if [ "$PLAT" == "arm64" ] || [ "$PLAT" == "aarch64" ]; then return; fi
    if [ -e nasm-stamp ]; then return; fi
    build_simple nasm $NASM_VERSION https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/
    touch nasm-stamp
}

function install_rav1e {
    if [ -n "$IS_MACOS" ] && [ "$PLAT" == "arm64" ]; then
        librav1e_tgz=librav1e-macos-aarch64.tar.gz
    elif [ -n "$IS_MACOS" ]; then
        librav1e_tgz=librav1e-macos.tar.gz
    elif [ "$PLAT" == "aarch64" ]; then
        librav1e_tgz=librav1e-linux-aarch64.tar.gz
    else
        librav1e_tgz=librav1e-linux-generic.tar.gz
    fi

    curl -sLo - \
        https://github.com/xiph/rav1e/releases/download/$RAV1E_VERSION/$librav1e_tgz \
        | tar -C $BUILD_PREFIX -zxf -

    if [ ! -n "$IS_MACOS" ]; then
        sed -i 's/-lgcc_s/-lgcc_eh/g' "${BUILD_PREFIX}/lib/pkgconfig/rav1e.pc"
        rm -rf $BUILD_PREFIX/lib/librav1e.so
    else
        rm -rf $BUILD_PREFIX/lib/librav1e.dylib
    fi
}

function install_ninja {
    if [ -e ninja-stamp ]; then return; fi
    if [ -n "$IS_MACOS" ]; then
        brew install ninja
    else
        $PYTHON_EXE -m pip install ninja
        ln -s $(type -P ninja) /usr/local/bin/ninja-build
    fi
    touch ninja-stamp
}

function build_dav1d {
    build_nasm
    install_ninja
    $PYTHON_EXE -m pip install meson

    local out_dir=$(fetch_unpack \
        "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.gz")

    local meson_flags=()
    if [ "$PLAT" == "arm64" ]; then
        meson_flags+=(--cross-file $(pwd -P)/wheels/dav1d-macos-arm64.cross)
    fi

    (cd $out_dir \
        && meson . build \
              "--prefix=${BUILD_PREFIX}" \
              --default-library=static \
              --buildtype=release \
              -D enable_tools=false \
              -D enable_tests=false \
             "${meson_flags[@]}" \
        && ninja -vC build install)
}

function build_libyuv {
    local cmake=$(get_modern_cmake)

    install_ninja

    mkdir -p libyuv-$LIBYUV_SHA
    (cd libyuv-$LIBYUV_SHA && \
        fetch_unpack "https://chromium.googlesource.com/libyuv/libyuv/+archive/$LIBYUV_SHA.tar.gz")
    mkdir -p libyuv-$LIBYUV_SHA/build
    (cd libyuv-$LIBYUV_SHA/build \
        && $cmake -G Ninja .. \
            -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
            -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        && ninja -v install)
    rm -rf $BUILD_PREFIX/lib/libyuv.{so,dylib}
}

function build_libavif {
    local cmake=$(get_modern_cmake)
    local cmake_flags=()

    build_libyuv
    build_dav1d
    install_rav1e

    if [ -n "$IS_MACOS" ]; then
        # Prevent cmake from using @rpath in install id, so that delocate can
        # find and bundle the libavif dylib
        cmake_flags+=(-DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib -DCMAKE_MACOSX_RPATH=OFF)
        if [ "$PLAT" == "arm64" ]; then
            cmake_flags+=(-DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64)
        fi
    fi

    local out_dir=$(fetch_unpack \
        "https://github.com/AOMediaCodec/libavif/archive/$LIBAVIF_VERSION.tar.gz" \
        "libavif-$LIBAVIF_VERSION.tar.gz")

    mkdir -p $out_dir/build
    (cd $out_dir/build \
        && $cmake .. \
            -G "Ninja" \
            -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DAVIF_CODEC_RAV1E=ON \
            -DAVIF_CODEC_DAV1D=ON \
            "${cmake_flags[@]}" \
        && ninja -v install)
}

function pre_build {
    # Any stuff that you need to do before you start building the wheels
    # Runs in the root directory of this repository.
    curl -fsSL -o pillow-depends-main.zip https://github.com/python-pillow/pillow-depends/archive/main.zip
    untar pillow-depends-main.zip

    build_xz
    if [ -z "$IS_ALPINE" ] && [ -z "$IS_MACOS" ]; then
        yum remove -y zlib-devel
    fi
    build_new_zlib

    if [ -n "$IS_MACOS" ]; then
        ORIGINAL_BUILD_PREFIX=$BUILD_PREFIX
        ORIGINAL_PKG_CONFIG_PATH=$PKG_CONFIG_PATH
        BUILD_PREFIX=`dirname $(dirname $(which python))`
        PKG_CONFIG_PATH="$BUILD_PREFIX/lib/pkgconfig"
    fi
    build_simple xcb-proto 1.16.0 https://xorg.freedesktop.org/archive/individual/proto
    if [ -n "$IS_MACOS" ]; then
        build_simple xorgproto 2023.2 https://www.x.org/pub/individual/proto
        build_simple libXau 1.0.11 https://www.x.org/pub/individual/lib
        build_simple libpthread-stubs 0.5 https://xcb.freedesktop.org/dist
        cp venv/share/pkgconfig/xcb-proto.pc venv/lib/pkgconfig/xcb-proto.pc
    else
        sed s/\${pc_sysrootdir\}// /usr/local/share/pkgconfig/xcb-proto.pc > /usr/local/lib/pkgconfig/xcb-proto.pc
    fi
    build_simple libxcb $LIBXCB_VERSION https://www.x.org/releases/individual/lib
    if [ -n "$IS_MACOS" ]; then
        BUILD_PREFIX=$ORIGINAL_BUILD_PREFIX
        PKG_CONFIG_PATH=$ORIGINAL_PKG_CONFIG_PATH
    fi

    build_libjpeg_turbo
    if [[ -n "$IS_MACOS" ]]; then
        rm /usr/local/lib/libjpeg.dylib
        if [[ "$PLAT" == "arm64" ]]; then
            rm /usr/local/lib/libjpeg.a
        fi
    fi
    build_tiff
    build_libpng
    build_lcms2
    build_openjpeg

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
        export FREETYPE_LIBS=''
        export FREETYPE_CFLAGS=''
    fi

    build_libavif

    # Append licenses
    for filename in wheels/dependency_licenses/*; do
      echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> LICENSE
      cat $filename >> LICENSE
    done
}

function pip_wheel_cmd {
    local abs_wheelhouse=$1
    if [ -z "$IS_MACOS" ]; then
        CFLAGS="$CFLAGS --std=c99"  # for Raqm
    fi
    python3 -m pip wheel $(pip_opts) \
        -C raqm=enable -C raqm=vendor -C fribidi=vendor \
        -w $abs_wheelhouse --no-deps .
}

function run_tests_in_repo {
    # Run Pillow tests from within source repo
    python3 selftest.py
    python3 -m pytest
}

EXP_CODECS="jpg jpg_2000 libtiff zlib"
EXP_MODULES="avif freetype2 littlecms2 pil tkinter webp"
EXP_FEATURES="fribidi harfbuzz libjpeg_turbo raqm transp_webp webp_anim webp_mux xcb"

function run_tests {
    if [ -n "$IS_MACOS" ]; then
        brew install fribidi
        export PKG_CONFIG_PATH="/usr/local/opt/openblas/lib/pkgconfig"
    elif [ -n "$IS_ALPINE" ]; then
        apk add curl fribidi
    else
        apt-get update
        apt-get install -y curl libfribidi0 libopenblas-dev pkg-config unzip
    fi
    if [ -z "$IS_ALPINE" ]; then
        python3 -m pip install numpy
    fi
    python3 -m pip install defusedxml olefile pyroma

    curl -fsSL -o pillow-test-images.zip https://github.com/python-pillow/test-images/archive/main.zip
    untar pillow-test-images.zip
    mv test-images-main/* ../Tests/images

    # Runs tests on installed distribution from an empty directory
    (cd .. && run_tests_in_repo)
    # Test against expected codecs, modules and features
    local ret=0
    local codecs=$(python3 -c 'from PIL.features import *; print(" ".join(sorted(get_supported_codecs())))')
    if [ "$codecs" != "$EXP_CODECS" ]; then
        echo "Codecs should be: '$EXP_CODECS'; but are '$codecs'"
        ret=1
    fi
    local modules=$(python3 -c 'from PIL.features import *; print(" ".join(sorted(get_supported_modules())))')
    if [ "$modules" != "$EXP_MODULES" ]; then
        echo "Modules should be: '$EXP_MODULES'; but are '$modules'"
        ret=1
    fi
    local features=$(python3 -c 'from PIL.features import *; print(" ".join(sorted(get_supported_features())))')
    if [ "$features" != "$EXP_FEATURES" ]; then
        echo "Features should be: '$EXP_FEATURES'; but are '$features'"
        ret=1
    fi
    return $ret
}
