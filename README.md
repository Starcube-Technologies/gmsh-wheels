# gmsh-wheels

A reproducible build recipe for the [gmsh](https://gmsh.info) Python wheel on Linux aarch64 (arm64).
**No wheel is published from this repository.**

## Status

PyPI publishes gmsh wheels for Linux x86-64, macOS (x86-64 and arm64) and Windows, but none for
Linux aarch64. In September 2026 StarCube built that wheel here: gmsh 4.15.2 with OpenCASCADE 7.8.1
linked statically, in a pinned `manylinux_2_28_aarch64` image. Two cold builds on separate arm64
runners produced byte-identical wheels, and both passed a smoke test (an OpenCASCADE boolean fuse,
Netgen optimisation, a 3D mesh and a `.msh` write).

We decided not to publish it:

- A statically linked gmsh and OpenCASCADE wheel bundles about thirty third-party components under
  the GPL, the LGPL and other licenses. Whoever publishes it owns a complete notice inventory, the
  corresponding source and, for the statically linked LGPL code, the means to relink. Our inventory
  was not complete.
- Every gmsh or OpenCASCADE release would need a rebuild, a fresh inventory and a mesh regression
  check, and every consumer would pin a new URL and hash.
- The gmsh project already builds and publishes the wheels for every other platform, so a Linux
  aarch64 wheel belongs in its release process, not in a second publisher's.

## What StarCube does instead

- On Linux x86-64, macOS and Windows, the StarCube tools install gmsh from PyPI as usual.
- On Linux aarch64, the tools install without gmsh and refuse 3D mesh generation by name instead
  of failing on a missing module (tools-v0.95.0). Jobs that mesh run on x86-64.

## The recipe

The build script, smoke test and workflow are on the
[`wheel-workflow`](https://github.com/Starcube-Technologies/gmsh-wheels/tree/wheel-workflow) branch
([pull request #1](https://github.com/Starcube-Technologies/gmsh-wheels/pull/1), closed without
publishing). They are kept as material for asking the gmsh project to publish Linux aarch64 wheels.
They build only for testing; nothing here is a release.

## License

This repository's own files are under the MIT license in `LICENSE`. gmsh is licensed under the
GPL, version 2 or later, with an exception for combining it with OpenCASCADE and Netgen;
OpenCASCADE Technology under the LGPL 2.1 with the Open CASCADE exception.
