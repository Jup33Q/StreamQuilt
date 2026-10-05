# Metaball export spike: metaball family -> convert to mesh -> stats ->
# low-poly variant (voxel remesh) -> UV unwrap -> export high/low OBJ + low GLB.
# Usage: Blender --background --python metaball_spike.py -- /tmp/metaball_test
import bpy, bmesh, sys, os, json

out_dir = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/metaball_test"
os.makedirs(out_dir, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)

def mesh_stats(obj):
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    nonmanifold = sum(1 for e in bm.edges if not e.is_manifold)
    bm.free()
    bb = [v[:] for v in obj.bound_box]
    xs = [c[0] for c in bb]; ys = [c[1] for c in bb]; zs = [c[2] for c in bb]
    return {"verts": len(me.vertices), "faces": len(me.polygons),
            "nonmanifold_edges": nonmanifold, "uv_layers": len(me.uv_layers),
            "bounds": [round(max(xs)-min(xs),3), round(max(ys)-min(ys),3), round(max(zs)-min(zs),3)]}

# --- metaball family (5 blobs, overlapping -> fused implicit surface) ---
mb = bpy.data.metaballs.new("mb")
mb.resolution = 0.08          # viewport density
mb.render_resolution = 0.04   # density used by convert/render
src = bpy.data.objects.new("metaballs", mb)
bpy.context.scene.collection.objects.link(src)
for co, r in [((0,0,0),1.0), ((0.85,0.15,0.3),0.7), ((-0.5,0.75,0.2),0.55),
              ((0.2,-0.45,0.85),0.45), ((-0.3,-0.3,-0.7),0.5)]:
    e = mb.elements.new()
    e.co = co
    e.radius = r

bpy.context.view_layer.objects.active = src
src.select_set(True)
bpy.ops.object.convert(target='MESH')   # implicit surface -> polygon mesh
high = bpy.context.view_layer.objects.active
high.name = "metaball_high"
high_stats = mesh_stats(high)

# --- low-poly via voxel remesh (robust for organic fused surfaces) ---
low = high.copy()
low.data = high.data.copy()
bpy.context.scene.collection.objects.link(low)
low.name = "metaball_low"
bpy.context.view_layer.objects.active = low
low.select_set(True)
bpy.ops.object.modifier_add(type='REMESH')
mod = low.modifiers[-1]
mod.mode = 'VOXEL'
mod.voxel_size = 0.12
bpy.ops.object.modifier_apply(modifier=mod.name)
# UV: smart project (organic surface, no hard-edge discipline needed for a spike)
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.uv.smart_project(angle_limit=0.7, island_margin=0.02)
bpy.ops.object.mode_set(mode='OBJECT')
low_stats = mesh_stats(low)

# --- exports ---
bpy.ops.object.select_all(action='DESELECT')
high.select_set(True)
bpy.context.view_layer.objects.active = high
bpy.ops.wm.obj_export(filepath=os.path.join(out_dir, "high.obj"), export_selected_objects=True)
bpy.ops.object.select_all(action='DESELECT')
low.select_set(True)
bpy.context.view_layer.objects.active = low
bpy.ops.wm.obj_export(filepath=os.path.join(out_dir, "low.obj"), export_selected_objects=True)
bpy.ops.export_scene.gltf(filepath=os.path.join(out_dir, "low.glb"),
                          export_format='GLB', use_selection=True)

print("SPIKE_REPORT " + json.dumps({"high": high_stats, "low": low_stats,
      "exports": ["high.obj", "low.obj", "low.glb"]}))
