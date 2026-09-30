# gmsh-wheels

Reproducible builds of the [gmsh](https://gmsh.info) Python wheel for Linux on aarch64 (arm64).

PyPI publishes gmsh wheels for Linux x86-64, macOS and Windows, but none for Linux aarch64. StarCube
runs its tools on arm64 too (Docker on Apple silicon, and arm64 CI runners), so this repository
builds that one wheel from pinned sources and publishes it as a GitHub release asset. Consumers
pin the asset by its URL and sha256.

What is built:

- gmsh 4.15.2 as a shared library, with OpenCASCADE 7.8.1 linked statically inside it;
- inside a `quay.io/pypa/manylinux_2_28_aarch64` image pinned by digest, by `build-wheel.sh`,
  whose comments explain each build option;
- checked by `smoke.py`: an OpenCASCADE boolean fuse, Netgen optimisation, a 3D mesh and a
  `.msh` write.

The build leaves out options StarCube does not use (the FLTK GUI, OpenMP, MED, CGNS, PETSc), so it
is not identical in features to the PyPI wheels for other platforms. It also leaves out gmsh's
`contrib/untangle`, which this build would never call (its one caller uses the WinslowUntangler
instead) and two of whose files carry notices that restrict commercial use. The wheel's metadata
is gmsh's own, unchanged, so its description still suggests `gmsh.fltk.run()`; without FLTK that
call raises an error, "Fltk not available".

## How a release is made

A release comes from running the `gmsh wheel` workflow by hand (`workflow_dispatch`) on `main`,
with a build number. The workflow:

1. builds the wheel twice, from cold, on two separate GitHub arm64 runners;
2. fails if the two wheels differ in any byte;
3. installs the wheel with pip in a bare `python:3.12-slim` container, and with uv on the runner,
   and runs `smoke.py` in each (the container image and uv are both pinned);
4. creates the release `gmsh-4.15.2-<build>` as a draft, attaches its files, then publishes it.
   It uploads only files it names, and refuses unless the wheel hashes to exactly what step 2
   compared.

Immutable releases are turned on for this repository, so once a release is published its tag
and files cannot change. A later build (for example on a newer manylinux image) gets a new build
number, so a new tag and URL; an existing release is never replaced, and the workflow refuses a
build number whose tag already exists.

A pull request that changes the workflow, the build script or the smoke test runs every step
except the publish.

Each release carries:

- the wheel, `gmsh-4.15.2-py2.py3-none-manylinux_2_28_aarch64.whl`;
- `SHA256SUMS`, covering every other file in the release;
- `build-a.log` and `build-b.log`, the logs of the two builds;
- `gmsh-4.15.2-source.tgz` and `occt-7_8_1.tar.gz`, the exact sources built;
- `build-wheel.sh`, the script that built them.

## How to verify a release

Check the files against `SHA256SUMS`:

```sh
gh release download gmsh-4.15.2-1 --repo Starcube-Technologies/gmsh-wheels
sha256sum -c SHA256SUMS
```

GitHub also records an attestation for each immutable release, which recent versions of the gh
CLI can check:

```sh
gh release verify-asset gmsh-4.15.2-1 gmsh-4.15.2-py2.py3-none-manylinux_2_28_aarch64.whl \
  --repo Starcube-Technologies/gmsh-wheels
```

To rebuild the wheel yourself on an arm64 machine with Docker (Apple silicon works), put the two
source tarballs in `src/` next to `build-wheel.sh` (the script downloads them if they are
missing, and checks their sha256 either way), then run it in the image the release notes name:

```sh
mkdir -p src && mv gmsh-4.15.2-source.tgz occt-7_8_1.tar.gz src/
docker run --rm -e JOBS=4 -v "$PWD":/work -w /work <image from the release notes> bash build-wheel.sh
```

The last line it prints is the wheel's sha256, which should match `SHA256SUMS`. A build took about
20 minutes on 3 cores.

## Licenses

- gmsh is licensed under the GPL, version 2 or later, with an exception that allows combining it
  with Netgen, METIS and OpenCASCADE (see `LICENSE.txt` in the gmsh sources, also shipped inside
  the wheel).
- OpenCASCADE Technology is licensed under the LGPL 2.1 with the Open CASCADE exception
  (`LICENSE_LGPL_21.txt` and `OCCT_LGPL_EXCEPTION.txt` in its sources).
- The wheel also bundles other third-party code compiled into gmsh's library, each part under its
  own license: among them Netgen (LGPL 2.1), METIS (Apache 2.0), tinyobjloader (MIT), ANN, Eigen
  and Gmm++. The wheel carries all of their license texts and notices in
  `share/doc/gmsh/third-party/` (installed as `<venv>/share/doc/gmsh/third-party/`), where
  `INVENTORY.txt` lists every component, where it is in the sources, its license and its files.
  Step 3 of `build-wheel.sh` writes that folder.
- Each release attaches the exact source tarballs and the build script, as the corresponding source
  that the GPL and the LGPL ask for.
- This repository's own files (the build script, the smoke test and the workflow) are under the
  MIT license in `LICENSE`.
