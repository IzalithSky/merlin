# Long View Distance Terrain Notes

This project currently uses a small imported terrain test scene. That is fine for
initial camera/environment work, but aviation-scale view distances should not be
treated as one giant high-detail mesh with one giant collision shape.

## Short Answer

A flight-sim style world is usually built from streamed terrain tiles/chunks with
multiple levels of detail. The renderer draws nearby terrain at high resolution,
far terrain as lower-resolution tiles or clipmap rings, and objects as separate
LOD/visibility systems. Atmospheric haze, fog, clouds, and careful depth precision
hide transitions and reduce the need for visible detail at extreme distance.

For Godot, the realistic path is:

1. Keep the current static terrain as a test level only.
2. Move to chunked terrain scenes or generated `ArrayMesh` chunks.
3. Add manual HLOD/visibility ranges for chunks and distant object groups.
4. Stream chunks around the aircraft with `ResourceLoader` threaded loading.
5. Use a low-resolution far-terrain proxy or clipmap terrain for horizon scale.
6. Handle precision with origin shifting and/or a Large World Coordinates build if
   the playable world grows beyond normal single-precision comfort.

## Techniques

| Technique | What it solves | Godot support | Practical effort |
| --- | --- | --- | --- |
| Tiled terrain chunks | Avoids one huge mesh; allows culling, streaming, and per-tile LOD. | Supported through scenes, `MeshInstance3D`, `ArrayMesh`, resources, and normal frustum culling. | Medium. Needs a chunk manager and content pipeline. |
| Automatic mesh LOD | Reduces triangle cost for imported meshes and props. | Native mesh LOD exists for imported/generated meshes. | Low for props, less ideal as the whole terrain solution. |
| Manual HLOD / visibility ranges | Swaps many detailed objects or chunks for fewer coarse proxies. | Native `GeometryInstance3D` visibility ranges and visibility parent support. | Low to medium. Authoring good proxies is the main work. |
| Threaded streaming | Loads terrain/object chunks without blocking the frame. | Native `ResourceLoader.load_threaded_request()` and status polling. | Medium. Needs lifecycle, budgets, and cache management. |
| Clipmap terrain rings | Stable horizon rendering with concentric terrain grids around the viewer. | Not core Godot, but feasible; the Terrain3D plugin uses clipmap terrain. | Medium if using Terrain3D, high if custom-built. |
| Separate terrain/object systems | Terrain, buildings, vegetation, and gameplay objects have different LOD rules. | Native node organization, `MultiMeshInstance3D`, mesh LOD, and visibility ranges. | Medium. Requires discipline in scene/data layout. |
| Reverse-Z depth | Better depth precision for large `Camera3D.far` values. | Native in Godot 4.3+ renderers. | Low. Avoid shaders that assume old depth conventions. |
| Origin shifting / large coordinates | Avoids float precision issues far from world origin. | Large World Coordinates builds exist; origin shifting is custom. | Medium for origin shifting, higher if physics/networking depend on absolute coordinates. |
| Atmospheric hiding | Makes distant terrain believable while hiding LOD and tile transitions. | Environment fog/sky are native; custom atmospheric scattering is possible. | Low to medium. Mostly art direction and shader work. |

## Recommended Architecture For Merlin

Use a layered world model:

| Layer | Runtime representation | Notes |
| --- | --- | --- |
| Near terrain | High-detail chunk meshes with collision. | Only keep collision around the aircraft/player. |
| Mid terrain | Lower-detail chunk meshes, no collision. | Use visibility ranges or explicit chunk LOD selection. |
| Far terrain | Very low-detail proxy mesh, clipmap rings, or Terrain3D far LODs. | This is for the horizon silhouette and broad color only. |
| Objects | Separate scene/chunk system using HLOD and `MultiMeshInstance3D`. | Do not bake all objects into terrain. |
| Atmosphere | Sky, fog, aerial perspective, cloud layers. | Important for aviation because clear infinite visibility looks fake and expensive. |

The camera can have a long far plane, but the far plane is not the solution by
itself. The scene must avoid submitting high-detail geometry at that distance.

## Terrain Data Shape

Prefer regular heightfield-like tiles unless there is a strong reason not to.
They are easier to simplify, stream, collide, and texture than arbitrary sculpted
mega-meshes.

Suggested tile layout:

```text
terrain/
  region_x_y/
    lod0/
      tile_x_y.tscn
    lod1/
      tile_x_y.tscn
    lod2/
      tile_x_y.tscn
```

Each tile should have:

- A stable world-space tile coordinate.
- One or more visual LOD meshes.
- Collision only for near LODs.
- Material data that can be reused across many tiles.
- Optional metadata for bounds, min/max elevation, and streaming priority.

## Streaming Policy

At runtime, maintain a square or circular active set around the aircraft:

1. Convert aircraft position to tile coordinates.
2. Compute required tiles and LODs based on distance and screen size.
3. Request missing tile resources with threaded loading.
4. Add a small number of completed tiles to the scene per frame.
5. Keep old tiles briefly to avoid holes during transitions.
6. Free tiles outside the retention radius.

Do not stream purely by distance if the aircraft is fast. Bias loading in the
direction of velocity so terrain is ready before it enters the forward view.

## Precision Policy

For a normal test map, standard Godot coordinates are enough. For large aviation
areas, plan for one of these:

- Floating origin: keep the aircraft/camera near `(0, 0, 0)` and shift world
  chunks in the opposite direction when crossing a threshold.
- Large World Coordinates build: useful if the project truly needs large absolute
  positions in engine types, with a memory/performance tradeoff.
- Hybrid: keep authoritative navigation in double-precision custom coordinates,
  but render local offsets near the camera.

The hybrid approach is usually the most explicit and easiest to reason about for
flight code.

## What Not To Do

- Do not render the whole world as one mesh.
- Do not keep collision active for distant terrain.
- Do not rely only on `Camera3D.far` to get aviation-scale visuals.
- Do not mix terrain, objects, and gameplay entities into one baked scene.
- Do not ignore atmosphere; it is part of the view-distance budget.

## Useful Sources

- Godot visibility ranges / HLOD: <https://docs.godotengine.org/en/stable/tutorials/3d/visibility_ranges.html>
- Godot mesh LOD: <https://docs.godotengine.org/en/stable/tutorials/3d/mesh_lod.html>
- Godot threaded resource loading: <https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html>
- Godot Large World Coordinates: <https://docs.godotengine.org/en/stable/tutorials/physics/large_world_coordinates.html>
- Godot reverse-Z change: <https://godotengine.org/article/introducing-reverse-z/>
- Terrain3D clipmap terrain for Godot: <https://terrain3d.readthedocs.io/en/latest/api/class_terrain3d.html>
- FlightGear World Scenery 3.0 overview: <https://wiki.flightgear.org/World_Scenery_3.0>
- FlightGear World Scenery 3.0 roadmap: <https://wiki.flightgear.org/World_Scenery_3.0_roadmap>
- Cesium 3D Tiles specification: <https://github.com/CesiumGS/3d-tiles/blob/main/specification/README.adoc>
- GPU geometry clipmaps: <https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry>
