# Mesh -> SDF voxel grid spike: voxelize a mesh into a signed-distance volume
# via mathutils.bvhtree (nearest-surface distance + raycast-parity sign),
# dump raw float16 grid + JSON metadata. The raymarcher samples this as a 3D
# texture — mesh assets become just another DE in the SDF scene.
# Usage: Blender --background --python sdf_voxelize.py -- in.obj out_basename [res=96]
import bpy, bmesh, sys, os, json, struct
from mathutils import Vector
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--") + 1:]
src_path, out_base = argv[0], argv[1]
res = int(argv[2]) if len(argv) > 2 else 96

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=src_path)
obj = [o for o in bpy.context.scene.objects if o.type == 'MESH'][0]
bpy.context.view_layer.objects.active = obj
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# BVH in world space
dg = bpy.context.evaluated_depsgraph_get()
bvh = BVHTree.FromObject(obj, dg)

# grid bounds = object bounds + margin
bb = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
mn = Vector((min(v.x for v in bb), min(v.y for v in bb), min(v.z for v in bb)))
mx = Vector((max(v.x for v in bb), max(v.y for v in bb), max(v.z for v in bb)))
center = (mn + mx) / 2
half = max((mx - mn)) / 2 * 1.15   # cubic grid, 15% margin
mn, mx = center - Vector((half,)*3), center + Vector((half,)*3)
step = (mx - mn) / (res - 1)

max_d = half * 3  # clamp distance for outside voxels
grid = bytearray()
p = Vector()
for z in range(res):
    for y in range(res):
        for x in range(res):
            p.x, p.y, p.z = mn.x + x*step.x, mn.y + y*step.y, mn.z + z*step.z
            loc, norm, idx, dist = bvh.find_nearest(p)
            # sign: cast a ray along +X, count hits; odd = inside
            hits = 0
            origin = p + Vector((1e-6, 1e-6, 1e-6))  # avoid grazing
            d = Vector((1, 0, 0))
            for _ in range(8):  # march along hits
                h = bvh.ray_cast(origin, d)
                if h[0] is None:
                    break
                hits += 1
                origin = h[0] + d * 1e-5
            sign = -1.0 if hits % 2 == 1 else 1.0
            v = max(-max_d, min(max_d, sign * dist))
            grid += struct.pack('<e', v)

bin_path = out_base + ".sdf.f16"
with open(bin_path, 'wb') as f:
    f.write(grid)
meta = {"res": res, "min": list(mn), "voxel": list(step),
        "encoding": "float16-le", "order": "x-fastest, z-major",
        "clamp": max_d}
with open(out_base + ".sdf.json", 'w') as f:
    json.dump(meta, f)
print("SDF_REPORT " + json.dumps({"res": res, "bytes": len(grid), "meta": meta}))
