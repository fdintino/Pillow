#!/usr/bin/env bash
set -eo pipefail

LIBAVIF_VERSION=0.9.2

if uname -s | grep -q Darwin; then
    PREFIX=/usr/local
    MAKE_INSTALL=(make install)
else
    PREFIX=/usr
    MAKE_INSTALL=(sudo make install)
fi

PKGCONFIG=${PKGCONFIG:-pkg-config}

export CFLAGS="-fPIC -O3 $CFLAGS"
export CXXFLAGS="-fPIC -O3 $CXXFLAGS"

./download-and-extract.sh libavif-$LIBAVIF_VERSION https://github.com/AOMediaCodec/libavif/archive/v$LIBAVIF_VERSION.tar.gz

pushd libavif-$LIBAVIF_VERSION

HAS_DECODER=0
HAS_ENCODER=0

if $PKGCONFIG --exists dav1d; then
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_DAV1D=ON)
    HAS_DECODER=1
fi

if $PKGCONFIG --exists rav1e; then
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_RAV1E=ON)
    HAS_ENCODER=1
fi

if $PKGCONFIG --exists SvtAv1Enc; then
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_SVT=ON)
    HAS_ENCODER=1
fi

if $PKGCONFIG --exists libgav1; then
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_LIBGAV1=ON)
    HAS_DECODER=1
fi

if $PKGCONFIG --exists aom; then
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_AOM=ON)
    HAS_ENCODER=1
    HAS_DECODER=1
fi

if [ "$HAS_ENCODER" != 1 ] || [ "$HAS_DECODER" != 1 ]; then
    pushd ext > /dev/null
    bash aom.cmd
    popd > /dev/null
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_AOM=ON -DAVIF_LOCAL_AOM=ON)
fi

if uname -s | grep -q Darwin; then
    # Prevent cmake from using @rpath in install id, so that delocate can
    # find and bundle the libavif dylib
    LIBAVIF_CMAKE_FLAGS+=("-DCMAKE_INSTALL_NAME_DIR=$PREFIX/lib" -DCMAKE_MACOSX_RPATH=OFF)
fi

mkdir build
cd build
cmake .. \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DCMAKE_BUILD_TYPE=Release \
    "${LIBAVIF_CMAKE_FLAGS[@]}"
make && "${MAKE_INSTALL[@]}"
cd ..

popd

