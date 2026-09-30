"""Smoke test for the gmsh wheel: import, then a 3D OpenCASCADE mesh shaped like deepstar's.

Mirrors deepstar/src/projections/physics/mesh.py: OCC boxes and a cylinder, a boolean fuse,
Netgen optimisation, curvature sizing, generate(3), and a .msh write. Run in a bare
python:3.12-slim container (no apt libraries), so a library the wheel does not carry fails here.
"""

import sys
import tempfile
from pathlib import Path

import gmsh

gmsh.initialize()
gmsh.option.setNumber("General.Terminal", 0)
print(gmsh.option.getString("General.BuildInfo"))
options = gmsh.option.getString("General.BuildOptions").split()
missing = {"OpenCASCADE", "Netgen", "Hxt", "Mesh"} - set(options)
assert not missing, f"build lacks {sorted(missing)}"

gmsh.model.add("smoke")
a = gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)
b = gmsh.model.occ.addBox(0.5, 0.5, 0.5, 1, 1, 1)
c = gmsh.model.occ.addCylinder(1.5, 0.5, 0.5, 1.0, 0, 0, 0.1)
gmsh.model.occ.fuse([(3, a)], [(3, b), (3, c)])
gmsh.model.occ.synchronize()
gmsh.option.setNumber("Mesh.Optimize", 1)
gmsh.option.setNumber("Mesh.OptimizeNetgen", 1)
gmsh.option.setNumber("Mesh.MeshSizeFromCurvature", 12)
gmsh.model.mesh.generate(3)
_, tags, _ = gmsh.model.mesh.getElements(dim=3)
n3 = sum(len(t) for t in tags)
assert n3 > 0, "no 3D elements"
out = Path(tempfile.mkdtemp()) / "smoke.msh"
gmsh.write(str(out))
gmsh.finalize()
print(f"smoke ok: {n3} tetrahedra, {out.stat().st_size} bytes of .msh, python {sys.version.split()[0]}")
