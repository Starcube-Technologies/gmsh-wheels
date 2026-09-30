#!/bin/bash
# Builds the gmsh 4.15.2 Linux wheel from pinned sources. Runs inside a pinned
# quay.io/pypa/manylinux_2_28_<arch> image; the workflow in .github/workflows/gmsh-wheel.yml holds
# the image digest, and each release's notes repeat it. Run it from the repository root:
#
#   docker run --rm -e JOBS=4 -v "$PWD":/work -w /work quay.io/pypa/manylinux_2_28_aarch64@sha256:... \
#     bash build-wheel.sh
#
#   bash build-wheel.sh --fetch-only    # on any host: download and verify the sources, then stop
#
# Inputs:  src/occt-7_8_1.tar.gz, src/gmsh-4.15.2-source.tgz (downloaded when missing; always
#          checked against the sha256 pinned below before anything else)
# Output:  wheelhouse/gmsh-4.15.2-py2.py3-none-manylinux_2_28_<arch>.whl, and its sha256 as the
#          last line printed
#
# Nothing here is specific to aarch64, so the same script also builds on x86-64. The comments
# below cite deepstar, StarCube's engineering tool that uses this wheel, for why an option is off.
set -euo pipefail

OCCT_URL=https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_8_1.tar.gz
OCCT_SHA256=7321af48c34dc253bf8aae3f0430e8cb10976961d534d8509e72516978aa82f5
GMSH_URL=https://gmsh.info/src/gmsh-4.15.2-source.tgz
GMSH_SHA256=be3f66f225d27ba9fa014f07e83169285da8a051b0e8ab7103d88066b39bdd3e

# Download to a .part file and rename only on success, so an interrupted download is never
# mistaken for a source that is already there. The retry flags are the ones the image's curl
# (7.61) has; --retry covers timeouts and HTTP 408, 429 and 5xx.
fetch() {
  local url=$1 dest=$2
  if [ -f "$dest" ]; then
    return
  fi
  echo "downloading $url"
  mkdir -p "$(dirname "$dest")"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 10 --retry-connrefused \
    --output "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

fetch "$OCCT_URL" src/occt-7_8_1.tar.gz
fetch "$GMSH_URL" src/gmsh-4.15.2-source.tgz
echo "$OCCT_SHA256  src/occt-7_8_1.tar.gz" | sha256sum -c -
echo "$GMSH_SHA256  src/gmsh-4.15.2-source.tgz" | sha256sum -c -

if [ "${1:-}" = "--fetch-only" ]; then
  exit 0
fi
# The steps below write to /build and expect the image's toolchain, Python and auditwheel; the
# manylinux images set AUDITWHEEL_PLAT, so its absence means this is not one of them.
if [ -z "${AUDITWHEEL_PLAT:-}" ]; then
  echo "run this inside a quay.io/pypa/manylinux_2_28 image (see the header), or pass --fetch-only" >&2
  exit 1
fi

ARCH=$(uname -m)
PLAT=manylinux_2_28_${ARCH}
JOBS=${JOBS:-2}
# gmsh 4.15.2's release day (its PyPI upload, 2026-03-24). CMake's string(TIMESTAMP), GCC's
# __DATE__/__TIME__ and auditwheel's zip entries all read it, so the build date is not "today".
export SOURCE_DATE_EPOCH=1774310400
# Fixed build path: debug and __FILE__ strings then do not depend on the checkout path.
B=/build

rm -rf "$B" && mkdir -p "$B"
tar -xzf src/occt-7_8_1.tar.gz -C "$B"
tar -xzf src/gmsh-4.15.2-source.tgz -C "$B"

# 1. OpenCASCADE 7.8.1 (the version PyPI's gmsh 4.15.2 reports in General.BuildInfo), static and
#    position-independent so it links into libgmsh.so and nothing of it ships as a separate
#    library. gmsh needs TKDESTEP (CMakeLists.txt:1327-1336), and 7.8's TKDESTEP compiles
#    against the XCAF drivers (STEPCAFControl_Provider.cxx includes BinXCAFDrivers.hxx), so the
#    DataExchange, ApplicationFramework and Visualization modules stay on; only Draw and DETools
#    go, with freetype, OpenGL, X11, Tk, TBB and VTK off. A static link pulls in only the objects
#    gmsh references.
cmake -S "$B/OCCT-7_8_1" -B "$B/occt-build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$B/occt" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_LIBRARY_TYPE=Static \
  -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_DETools=OFF \
  -DUSE_FREETYPE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF -DUSE_TK=OFF \
  -DUSE_FREEIMAGE=OFF -DUSE_FFMPEG=OFF -DUSE_OPENVR=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF \
  -DUSE_TBB=OFF -DUSE_VTK=OFF -DBUILD_DOC_Overview=OFF -DBUILD_SAMPLES_QT=OFF \
  -DINSTALL_DIR_LAYOUT=Unix
cmake --build "$B/occt-build" -j "$JOBS"
cmake --install "$B/occt-build"

# 2. gmsh 4.15.2 as a shared library with OCC static inside. No FLTK/OpenGL (deepstar uses the
#    API only), no OpenMP (deepstar never raises General.NumThreads above its default 1, and
#    libgomp is outside the manylinux allow-list, so it would have to be grafted), no MED/CGNS/
#    PETSc (external libraries deepstar does not use). Netgen and HXT stay on: mesh.py:326 sets
#    Mesh.OptimizeNetgen. GMSH_HOST/PACKAGER replace `hostname`/`whoami` (CMakeLists.txt:188-205).
#    GMSH_RELEASE makes the Python version 4.15.2 rather than 4.15.2.dev1 (CMakeLists.txt:1661),
#    and lib (not the manylinux image's lib64) is where sdktowheel.py:26 looks for the dist-info.
cmake -S "$B/gmsh-4.15.2-source" -B "$B/gmsh-build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$B/sdk" \
  -DCMAKE_PREFIX_PATH="$B/occt" \
  -DENABLE_BUILD_DYNAMIC=1 -DENABLE_BUILD_SHARED=1 \
  -DENABLE_OCC=1 -DENABLE_OCC_STATIC=1 -DENABLE_OCC_CAF=0 -DENABLE_OCC_TBB=0 \
  -DENABLE_FLTK=0 -DENABLE_OPENMP=0 -DENABLE_MED=0 -DENABLE_CGNS=0 -DENABLE_PETSC=0 \
  -DENABLE_SLEPC=0 -DENABLE_MMG=0 -DENABLE_CAIRO=0 -DENABLE_OSMESA=0 -DENABLE_GMP=0 \
  -DENABLE_NETGEN=1 -DENABLE_HXT=1 -DENABLE_EIGEN=1 -DENABLE_BLAS_LAPACK=0 \
  -DGMSH_HOST=starcube-ci -DGMSH_PACKAGER=starcube \
  -DGMSH_RELEASE=1 -DCMAKE_INSTALL_LIBDIR=lib
cmake --build "$B/gmsh-build" -j "$JOBS"
cmake --install "$B/gmsh-build"

# 3. Pack with gmsh's own packer (the layout of the PyPI wheels: gmsh.py at the top,
#    libgmsh.so under .data/data/lib, which gmsh.py finds as <venv>/lib), then let auditwheel
#    check it and write the final zip (sorted entries, SOURCE_DATE_EPOCH timestamps).
mkdir -p "$B/raw" wheelhouse
(cd "$B/raw" && python3.12 "$B/gmsh-4.15.2-source/utils/pypi/sdktowheel.py" "$B/sdk" "$PLAT")
ls -la "$B/raw"
auditwheel show "$B"/raw/*.whl
auditwheel repair --plat "$PLAT" --only-plat -w wheelhouse "$B"/raw/*.whl
# auditwheel copies anything outside the allow-list into gmsh.libs and points the RPATH of
# .data/data/lib/libgmsh.so at it relative to the archive, not to where a data file installs
# (auditwheel repair.py special-cases only .data/scripts). A grafted library would therefore
# not load, so the wheel must graft nothing.
if unzip -l wheelhouse/*.whl | grep -q 'gmsh.libs/'; then
  echo "auditwheel grafted libraries into the wheel; they would not load from .data/data/lib" >&2
  exit 1
fi
sha256sum wheelhouse/*.whl
