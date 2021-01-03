#!/usr/bin/env bash
set -eo pipefail

LIBAVIF_VERSION=${LIBAVIF_VERSION:-12e066686892df1c8201cfb0d8d6c68ad248c872}

LIBAVIF_CMAKE_FLAGS=()

if uname -s | grep -q Darwin; then
    PREFIX=/usr/local
else
    PREFIX=/usr
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

PKGCONFIG=${PKGCONFIG:-pkg-config}

mkdir -p libavif-$LIBAVIF_VERSION
curl -sLo - \
    https://github.com/AOMediaCodec/libavif/archive/$LIBAVIF_VERSION.tar.gz \
    | tar --strip-components=1 -C libavif-$LIBAVIF_VERSION -zxf -
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
pushd build
cmake .. \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    "${LIBAVIF_CMAKE_FLAGS[@]}"
make
make install || sudo make install
popd

popd
