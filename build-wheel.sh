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
#          last line printed. The wheel carries the license texts of everything compiled into
#          it (step 3).
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
#    Untangle is off as well: its only caller (src/mesh/Generator.cpp:915-927) takes the
#    WinslowUntangler path whenever that is built, as it is here, so contrib/untangle would be
#    dead code in the library, and two of its files (HLBFGS, ICFS) carry notices that restrict
#    commercial use.
cmake -S "$B/gmsh-4.15.2-source" -B "$B/gmsh-build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$B/sdk" \
  -DCMAKE_PREFIX_PATH="$B/occt" \
  -DENABLE_BUILD_DYNAMIC=1 -DENABLE_BUILD_SHARED=1 \
  -DENABLE_OCC=1 -DENABLE_OCC_STATIC=1 -DENABLE_OCC_CAF=0 -DENABLE_OCC_TBB=0 \
  -DENABLE_FLTK=0 -DENABLE_OPENMP=0 -DENABLE_MED=0 -DENABLE_CGNS=0 -DENABLE_PETSC=0 \
  -DENABLE_SLEPC=0 -DENABLE_MMG=0 -DENABLE_CAIRO=0 -DENABLE_OSMESA=0 -DENABLE_GMP=0 \
  -DENABLE_UNTANGLE=0 \
  -DENABLE_NETGEN=1 -DENABLE_HXT=1 -DENABLE_EIGEN=1 -DENABLE_BLAS_LAPACK=0 \
  -DGMSH_HOST=starcube-ci -DGMSH_PACKAGER=starcube \
  -DGMSH_RELEASE=1 -DCMAKE_INSTALL_LIBDIR=lib
cmake --build "$B/gmsh-build" -j "$JOBS"
cmake --install "$B/gmsh-build"

# 3. License texts and notices for the third-party code compiled into libgmsh.so. gmsh's own
#    LICENSE.txt (the GPL with its linking exception) and CREDITS.txt are already in
#    sdk/share/doc/gmsh. sdktowheel.py:43-44 copies sdk/share whole into the wheel's
#    .data/data/share, but :72-73 takes only METADATA from the SDK's dist-info, so a PEP 639
#    dist-info/licenses folder would not reach the wheel. The texts therefore go next to gmsh's,
#    in share/doc/gmsh/third-party (<venv>/share/doc/gmsh/third-party once installed), with
#    INVENTORY.txt there naming each component, its license and its files. The list follows
#    what this build compiles (the "Building ... object" lines of its log) and links (the
#    library's symbol table), not every folder the sources carry. The line ranges are exact for
#    the pinned archives.
T=$B/sdk/share/doc/gmsh/third-party
G=$B/gmsh-4.15.2-source
O=$B/OCCT-7_8_1
# The GNU texts that gmm's COPYING names but the gmsh sources do not include (GPL 3, LGPL 3,
# the GCC Runtime Library Exception) are GCC's own copies, from the image's libgcc package.
GNU=/usr/share/licenses/libgcc
# licenses <folder> <file>...: copy whole license files.
licenses() {
  local dir=$T/$1
  shift
  mkdir -p "$dir"
  cp "$@" "$dir/"
}
# notice <folder> <file> <first> <last>: append a notice that lives in a source file's header.
notice() {
  mkdir -p "$T/$1"
  {
    echo "From ${2#"$B"/}, lines $3-$4:"
    echo
    sed -n "$3,$4p" "$2"
    echo
  } >> "$T/$1/NOTICE.txt"
}
licenses OpenCASCADE "$O/LICENSE_LGPL_21.txt" "$O/OCCT_LGPL_EXCEPTION.txt"
notice OpenCASCADE "$O/src/BRepMesh/delabella.cpp" 1 26
notice OpenCASCADE "$O/src/Standard/Standard_Strtod.cxx" 1 18
notice OpenCASCADE "$O/src/FlexLexer/FlexLexer.h" 1 28
licenses Netgen "$G/contrib/Netgen/LICENSE"
licenses METIS "$G/contrib/metis/LICENSE.txt"
cp "$G/contrib/eigen/COPYING.APACHE" "$T/METIS/LICENSE-2.0.txt"
licenses tinyobjloader "$G/contrib/tinyobjloader/LICENSE"
licenses ANN "$G/contrib/ANN/Copyright.txt" "$G/contrib/ANN/License.txt"
notice ALGLIB "$G/contrib/ALGLIB/ap.cpp" 1 18
notice bamg "$G/contrib/bamg/bamglib/Mesh2.cpp" 1 27
licenses blossom "$G/contrib/blossom/README.txt"
licenses MathEx "$G/contrib/MathEx/license.txt"
licenses kbipack "$G/contrib/kbipack/LICENSE"
licenses voro++ "$G/contrib/voro++/LICENSE"
licenses tinyxml2 "$G/contrib/tinyxml2/LICENSE.txt"
licenses hxt "$G/contrib/hxt/LICENSE.txt" "$G/contrib/hxt/CREDITS.txt"
licenses nii2mesh "$G/contrib/nii2mesh/LICENSE"
notice nii2mesh "$G/contrib/nii2mesh/src/base64.c" 1 7
notice nii2mesh "$G/contrib/nii2mesh/src/bwlabel.c" 17 23
notice nii2mesh "$G/contrib/nii2mesh/src/MarchingCubes.c" 5 17
notice nii2mesh "$G/contrib/nii2mesh/src/quadric.c" 1 13
notice nii2mesh "$G/contrib/nii2mesh/src/radixsort.c" 1 19
licenses gmm "$G/contrib/gmm/COPYING"
licenses Eigen "$G"/contrib/eigen/COPYING.*
notice robin_hood "$G/src/common/robin_hood.h" 1 31
notice libOL "$G/src/common/libol1.c" 1 35
notice QuadMeshingTools "$G/contrib/QuadMeshingTools/row_echelon_integer.cpp" 1 6
notice gmsh-contrib "$G/contrib/MeshOptimizer/MeshOpt.cpp" 1 25
notice gmsh-contrib "$G/contrib/HighOrderMeshOptimizer/HighOrderMeshOptimizer.cpp" 1 25
notice gmsh-contrib "$G/contrib/MeshQualityOptimizer/MeshQualityOptimizer.cpp" 1 23
notice gmsh-contrib "$G/src/common/onelab.h" 1 21
licenses GNU "$GNU/COPYING3" "$GNU/COPYING3.LIB" "$GNU/COPYING.RUNTIME"
cat > "$T/INVENTORY.txt" <<'EOF'
Third-party code in lib/libgmsh.so.4.15
=======================================

This wheel is gmsh 4.15.2 with OpenCASCADE Technology 7.8.1 linked statically into its
library, built by build-wheel.sh in https://github.com/Starcube-Technologies/gmsh-wheels.
Each release there attaches the exact source archives and that script.

gmsh is licensed under the GPL, version 2 or later, with an exception for combining it with
OpenCASCADE, Netgen and METIS: see ../LICENSE.txt. ../CREDITS.txt credits gmsh's contributors
and holds several of the notices listed below.

This folder holds the license texts and notices of the other code compiled into the library.
Each entry names the component, where it is in the sources, its license, and its files here.
The list follows what the build compiles and links, so the optional parts of gmsh that the
build leaves out (FLTK, OpenMP, MED, CGNS, PETSc, MMG, contrib/untangle and others) are not in
it.

OpenCASCADE Technology 7.8.1 (OCCT-7_8_1), Open Cascade SAS
    LGPL 2.1 with the Open CASCADE exception. OpenCASCADE/LICENSE_LGPL_21.txt,
    OpenCASCADE/OCCT_LGPL_EXCEPTION.txt.
    Inside it, under their own terms (notices in OpenCASCADE/NOTICE.txt): DELABELLA
    (src/BRepMesh/delabella.cpp), Marcin Sokalski, MIT; strtod
    (src/Standard/Standard_Strtod.cxx), David M. Gay, Lucent Technologies; FlexLexer.h
    (src/FlexLexer), The Regents of the University of California, BSD.

Netgen (contrib/Netgen), Joachim Schoeberl
    LGPL 2.1. Netgen/LICENSE.

METIS and GKlib (contrib/metis), Regents of the University of Minnesota
    Apache License 2.0. METIS/LICENSE.txt, with the full license in METIS/LICENSE-2.0.txt
    (a copy of contrib/eigen/COPYING.APACHE).

tinyobjloader (contrib/tinyobjloader), Syoyo Fujita and many contributors
    MIT. tinyobjloader/LICENSE.

ANN 1.1.2 (contrib/ANN), University of Maryland, Sunil Arya and David Mount
    LGPL 2.1 or later. ANN/Copyright.txt, ANN/License.txt.

ALGLIB (contrib/ALGLIB), Sergey Bochkanov
    GPL 2 or later (the GPL text is in ../LICENSE.txt). ALGLIB/NOTICE.txt.

BAMG (contrib/bamg), Frederic Hecht, from FreeFem++
    LGPL 2.1 or later (the text is Netgen/LICENSE). bamg/NOTICE.txt.

Blossom IV and Concorde 97 (contrib/blossom), Bill Cook et al.
    Permission from Bill Cook for use within the Gmsh system. blossom/README.txt.

MathEx 0.2.3 (contrib/MathEx), Sadao Massago
    LGPL 2.1 or later, with static linking exceptions. MathEx/license.txt.
    As that license asks: gmsh is based in part on the work of the SSCILIB Library
    (http://sscilib.sourceforge.net/).

Kbipack (contrib/kbipack), Saku Suuriniemi
    GPL 2 or later. kbipack/LICENSE.

Voro++ (contrib/voro++), The Regents of the University of California, through Lawrence
Berkeley National Laboratory
    BSD-style. voro++/LICENSE.

TinyXML-2 (contrib/tinyxml2), Lee Thomason
    zlib. tinyxml2/LICENSE.txt.

HXT (contrib/hxt), Universite catholique de Louvain
    GPL 2 or later, with an exception for combining it with gmsh. hxt/LICENSE.txt,
    hxt/CREDITS.txt.

nii2mesh (contrib/nii2mesh), Chris Rorden, with code by Jesper Andersson, Jouni Malinen,
Thomas Lewiner, Ziad Saad, Sven Forstmann and Cameron Hart
    BSD 2-clause, with parts under BSD, MIT and zlib terms. nii2mesh/LICENSE,
    nii2mesh/NOTICE.txt.

Gmm++ 5.4.4 (contrib/gmm, headers only), Yves Renard
    LGPL 3 or later with the GCC Runtime Library Exception 3.1. gmm/COPYING, with the texts
    it names in GNU/COPYING3.LIB, GNU/COPYING3 and GNU/COPYING.RUNTIME.

Eigen (contrib/eigen, headers only)
    Mostly MPL 2.0, with some files under BSD, MINPACK and LGPL 2.1 terms. Eigen/COPYING.*,
    all of Eigen's license files (Eigen/COPYING.README explains them).

robin_hood (src/common/robin_hood.h), Martin Ankerl
    MIT. robin_hood/NOTICE.txt.

libOL (src/common/libol1.c), Loic Marechal / INRIA
    MIT. libOL/NOTICE.txt.

row_echelon_integer (contrib/QuadMeshingTools/row_echelon_integer.cpp), John Burkardt
    LGPL (its header links version 3, whose text is GNU/COPYING3.LIB).
    QuadMeshingTools/NOTICE.txt.

MeshOptimizer, HighOrderMeshOptimizer and MeshQualityOptimizer (contrib), UCLouvain-ULiege;
ONELAB (src/common/onelab.h, contrib/onelab), Universite de Liege - Universite catholique de
Louvain
    Permission notices that ask to be reproduced in the documentation. gmsh-contrib/NOTICE.txt.

In ../CREDITS.txt: the AVL tree code (src/common/avl.cpp), picojson (src/common/picojson.h),
nanoflann (src/numeric/nanoflann.hpp), and TetGen/BR (src/mesh/tetgenBR.cxx, also used by
contrib/hxt/tetBR), which is relicensed for gmsh under ../LICENSE.txt.

Placed in the public domain, or free for all uses, by their authors: J. R. Shewchuk's robust
predicates (src/numeric/robustPredicates.cpp, contrib/hxt/predicates) and the RTree template
(src/common/rtree.h).

Generated code: the parsers and scanners in src/parser (gmsh) and src/StepFile (OCCT) were
generated by GNU Bison and flex; each Bison parser carries Bison's exception in its header.

GCC runtime: the build image's compiler (gcc-toolset) links parts of libstdc++ and libgcc into
the library. GPL 3 with the GCC Runtime Library Exception 3.1: GNU/COPYING3,
GNU/COPYING.RUNTIME.

GNU/ holds GCC's copies of the GNU texts above, from the build image's
/usr/share/licenses/libgcc: COPYING3 (GPL 3), COPYING3.LIB (LGPL 3) and COPYING.RUNTIME (GCC
Runtime Library Exception 3.1).
EOF

# 4. Pack with gmsh's own packer (the layout of the PyPI wheels: gmsh.py at the top,
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
# not load, so the wheel must graft nothing. The listing is taken first and then searched, so
# that a failed listing stops the script (set -e) instead of reading as "nothing grafted".
entries=$(unzip -Z1 wheelhouse/*.whl)
if grep -qF 'gmsh.libs/' <<< "$entries"; then
  echo "auditwheel grafted libraries into the wheel; they would not load from .data/data/lib" >&2
  exit 1
fi
sha256sum wheelhouse/*.whl
