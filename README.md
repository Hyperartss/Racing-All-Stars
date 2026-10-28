# Retro Karting — Mario Kart × Sonic R

Godot 4.7.2, GL Compatibility, rendered at 640×360 and scaled up (PS1/N64 look).
Open the project and press Play: Sonic (you) races Mario (AI) for 3 laps.

## Controls
| Key | Runner (Sonic) | Kart (Mario) |
|---|---|---|
| W / Up | run | accelerate |
| S | brake / back up | brake / reverse |
| A / D | steer | steer |
| Space | jump (hold for a higher jump) | — |
| Shift | dash (cooldown) | (drift, see below) |
| Ctrl or Shift (hold while steering) | — | hop + drift, release for a mini-turbo (blue 0.75 s, orange 1.6 s) |
| Q | look back | look back |
| Tab | switch camera between racers | |
| R | respawn | |

Scenes: `scenes/race.tscn` (Sonic + Mario), `scenes/test_runner.tscn` (Sonic alone),
`scenes/test_kart.tscn` (Mario alone). Command-line overrides after `--`:
`--roster=mario,sonic --player=1 --laps=1 --no-countdown` (`--player=-1` = all AI).

## The course (bake)
`tools/bake/bake_track.py` builds it from the untouched originals in `Tracks/`:

* **Mario Raceway** (×100 scale, MK64 layout), driven clockwise: start/finish on the arch
  straight, through the green pipe, NW esses, west side, SW hairpin, infield esses, south S-bends.
* **Connector A** (generated): leaves the arch straight heading east, **vertical loop**, then
  climbs into the island. Its road fades (dithered) from Raceway asphalt to island planks.
* **Resort Island Trk90→Trk195** (×2 scale): the NE hairpin, the long east side, the raised
  plateau, and the **alternate route** (Trk327→Trk384) that splits on the plateau and rejoins.
* **Connector B** (generated) drops back onto the Raceway at the bottom of the old start straight.

The Raceway's NE corner and start straight are what the detour replaces (they became grass).
Lap ≈ 1.42 km, 10 checkpoints (all must be passed in order).

Seams: road polygons are clipped exactly at the cut planes, and each connector's first/last
row is stitched to the exact cut vertices (`zip_strip`), so the road is one watertight surface.
The Raceway ground under the detour is subdivided and pushed below it (with a 45° embankment)
instead of deleted, so there are no holes. `scenes/check_floor.tscn` raycasts across the road
width at every centreline sample; current result: 8,899 rays, 5 misses, all at the outer edge
of the island plateau, where the real road is narrower than the 10 m the check assumes.

Output: `assets/tracks/merged/track.json` + `track.bin` (own format: avoids the OBJ importer's
256-surface cap and the island's fully-transparent materials), loaded by `src/track/track.gd`.
Collision is split by surface class (road / off-road / wall); decoration has none.

## Vertex animation
No Skeleton3D, Skin or AnimationPlayer anywhere. `tools/bake/bake_rigs.py` writes
`assets/rigs/*.json`: rest geometry where each vertex belongs to a part (polygon group) with a
pivot and parent. `src/rig/vertex_rig.gd` rotates parts about their pivots in code and moves
the vertices every frame (vertices on a seam follow both neighbouring parts 50/50 so elbows
and knees don't crack).

* **Sonic** (`sonic_visual.gd`): Sonic R's 11 rigid parts; joints = pivots. Idle (breathing,
  foot tap, look around), run (leg/arm swing and cadence scale with speed, lean, dash pose),
  jump (curled spin ball), hit (flail).
* **Kart + Mario** (`kart_visual.gd`): 4 wheels split from the tire mesh, each spinning by its
  own radius from speed; front wheels steer; body leans in turns, slides and hops on drifts.
  Mario is posed seated from his T-pose in code, head turns toward the steer, arms work the
  wheel, and he rides on the body's transform. Mario's mesh is the OBJ; the .dae's joints were
  used only for pivot positions and to decide which part each vertex belongs to.

## Adding a racer type (e.g. flyer)
1. `src/racers/movement/flyer_movement.gd` — `extends MovementModel`, implement `physics_step`
   (and `make_shape` / `surface_multiplier` if needed), fill `anim`.
2. `src/racers/visual/<name>_visual.gd` — `extends RacerVisual`, implement `update_visual`.
3. Add one entry to `TYPES` and one to `CHARACTERS` in `src/racers/racer_types.gd`.
Racer progress, laps, respawns, the loop, AI line-following, HUD and camera are shared.

## Tests
* `godot --headless --fixed-fps 60 --path . res://scenes/test_lap.tscn -- --roster=sonic,mario --laps=3 --player=-1`
  AI race; prints checkpoint splits, lap times, respawns and every animation state seen.
  Last run: both finished 3 laps (Sonic 47.6–53.4 s laps, Mario 59.3–76.2 s), 1 respawn
  (kart ran off the open edge at the island exit).
* `res://scenes/check_floor.tscn` — road gap check (above).
* `godot --headless --path . -s tools/test_map_editor.gd` — Map Editor smoke test: stamps
  a prop, deletes a connected part, uses the erase and restore brushes, paints a fill stroke
  (one sheet, shared corners, lifted off the ground, and a second stroke extending the same
  patch rather than stacking a coplanar one), saves and reloads `decor.json`, and loads a
  plain `Track` to check the prop spawns, the filled sheet is built and the erased triangle
  is gone from the course mesh. On `retro_circuit` it checks that Delete part refuses an
  oversized piece, that erasing a hole then painting over it works with the level taken
  from the erased face or the ground beside the hole, and that a gap between two vertical
  wall pieces takes the wall's plane and is closed by one flat sheet that stays inside the
  gap - while painting on the solid wall paints nothing. It also checks that Hole (7)
  closes a 4 x 4 m hole in one click, stays inside the outline, and refuses solid ground.
  Then it closes a 4 x 4 m hole with Edges (8): it picks the four rim edges with the
  camera, checks the live plan (2 triangles, 16 m², the rim surface's texture), fills it
  and checks the patch reuses the rim vertices (watertight seam), stays on the hole's
  plane and continues the neighbouring UVs. Shift+click must take a whole 16-edge rim
  loop in one go, matching the neighbours' 1 m edge length must split the fill into more
  triangles (max edge under 2 m), and two separate wall rims must be bridged across the
  gap only, keeping the wall class. It deletes the `decor.json` it wrote unless the map
  already had one.
* Visual: `scenes/capture_race.tscn`, `tools/render_rigs.gd`, `tools/render_track.gd`.

## Rebuilding assets
`pip install numpy pillow pycollada opencv-python scikit-image networkx matplotlib`, then from
the project root: `python3 tools/bake/bake_rigs.py` and `python3 tools/bake/bake_track.py`.
Tunables (cut points, island offset, loop radius, scales) are constants at the top of
`bake_track.py`; `out/track_top.png` shows the resulting layout.

## Placeholders used
* Connector roads, rails, skirts and the vertical loop: generated geometry using the source
  tracks' textures (Raceway asphalt + checker barrier, island plank tile).
* Start/finish stripe: generated quad with the Raceway's checker texture (the original start
  line was on the replaced straight).
* Ground layer under the detour area (Raceway grass texture).
* Sky colour, fog and a single sun instead of a skybox; no sound or music.
* Text-only HUD; checkpoints are invisible distance gates.
* The previous session's `assets/characters`, `assets/karts`, `assets/tracks/mario_raceway`
  and `assets/tracks/resort_island` copies are no longer used (`.gdignore` added). The old
  procedural track code is kept in `src/_old/`.

## Menu, customisation and editor tools

- **Main menu** (`scenes/main_menu.tscn`, now the start scene): pick a character, paint it (and its kart), pick a map, laps and opponents. Choices are saved in `user://profile.json`.
- **Content is data:** `content/characters`, `content/karts`, `content/maps`, `content/track_sources` (JSON). The menu lists whatever is in those folders.
- **Editor plugin "Retro Karting Tools"** (enabled in Project Settings → Plugins) adds four bottom-panel docks:
  - **Map Combiner:** choose segments from the source tracks (whole loop, cut section, or piece range). Place them by dragging, Shift-drag to rotate, wheel to zoom and right-drag to pan. "Pick" buttons set cut points and the start. Each connector can have a vertical loop. **Bake** runs `tools/bake/trackbake.py` (needs Python 3 with numpy, pillow, opencv-python, scikit-image, networkx and matplotlib). Press **Set up Python** once: it makes a private environment with those packages in the project's user data folder (`user://bake_venv`, outside the project) and Bake uses it automatically (on Mint/Ubuntu this needs `sudo apt install python3-venv` first). Bake runs in the background and writes `assets/maps/<id>/`; a map only appears in the game's menu once it has baked successfully.
  - **Map Editor:** open a baked map and edit the merge itself in 3D, then decorate it. The course is shown with the game's sky, fog and light; middle-drag orbits, Shift+middle pans, wheel zooms, **F** frames, double-click a spot to fly to it. Eight tools (a brush ring shows the erase/restore radius and the fill footprint; the rim edges around the cursor, including the rim of a gap the cursor points into, show as lines in Edges mode):
    - **Select (1)**: click a prop, then drag the gizmo to **move** (G, arrows), **rotate** (R, ring; Ctrl snaps to 15°) or **scale** (S, handle; drag up/down). Position/rotation/scale/colour are also in the panel; **Snap to ground** drops the prop onto the geometry below. **Delete** removes it, Ctrl+D duplicates, Ctrl+Z / Ctrl+Shift+Z undo.
    - **Place (2)**: pick a prop (tree, pine, palm, bush, rock, traffic cone, lamp post, sign), a colour, random yaw and size jitter, then click the course to stamp one (each click places a prop; **Add at view** stamps where the camera looks).
    - **Erase (3)**: drag a brush over baked geometry to erase triangles - floating scenery, z-fighting or leftover pieces. **Brush / fill size** sets the radius.
    - **Part (4)**: click one triangle and the whole connected piece around it goes (a tree, a sign, a floating chunk). Corners are welded by position, so it follows the real surface; pieces over 4,000 triangles are refused (use the brush) so a stray click cannot wipe the route.
    - **Fill (5)**: drag to close a gap, a hole or a seam, on the **ground or a wall**. It works in **cells**, not triangles, and by default **only paints empty space**: a cell that already has geometry on the level is skipped, so the sheet fills the hole and stops at its rim instead of lying over the surface (dragging over intact ground or a solid wall paints nothing and says so). Tick **Cover existing** to paint over geometry too (it sits 3.5 cm above it, so it still cannot z-fight) - that is the tool for an ugly strip that turns out to be a surface rather than a hole. The level it fills on is, in order: the surface under the cursor; **the face this editor erased there** (a gap you cut yourself still knows exactly which surface used to be in it, which is what makes wall gaps exact); the surface around the cursor, found by marching rays out from it in 12 directions and taking the plane that surrounds it on the most sides (so a wall gap takes the wall's plane, not the ground below or what is visible through it); otherwise the last level used. The sheet is built on the side you are looking from, so a wall or a ceiling seen from below gets its fill in front of it rather than buried in the solid. Painted cells show live while you drag; on release they become **one sheet** - shared corners, draped onto whatever surface is within 0.5 m of the plane and lifted 3.5 cm so it cannot z-fight or poke through the course - textured with the seed triangle's texture and UV scale, keeping its road grip. Painting again over a fill on the same plane **extends that patch** instead of laying a second coplanar one on top of it (which is what used to z-fight); **Fill texture** overrides the texture, **Remove patches** deletes them all. A gap wider than the brush is painted in a few strokes; they merge into one sheet.
    - **Restore (6)**: paint erased triangles back in (the inverse of Erase). The panel also lists every baked surface (texture + class) so a whole surface can be hidden, plus **Restore faces** / **Restore all**.
    - **Hole (7)**: click inside a gap and its **whole outline is filled at once** - the long tears that run beside a road, the break in a brick path, a chunk out of a wall, a missing piece between two connectors. It walks out from the click on the fill level, stopping at the surface around it. If the gap is **open along a side** (a break in a narrow path is open along both edges) it keeps only the strip that lies between surfaces on both sides - so the patch closes the break across the path instead of spilling into the void; the panel says so when it does that. A gap that has no surface within a few metres on one side is refused, and so is one over 2,000 cells - use **Fill (5)** for those. Same level rules, texture and merging as Fill; it reports the area it filled, and if it finds no closed outline at all it fills one brush stamp under the cursor instead of doing nothing. The line above the 3D view repeats every result, so a click always tells you what happened.
    - **Edges (8)**: the precise hole filler. Hover the course and its **rim edges** show up as thin lines (an edge used by only one triangle - the outline of a gap, a tear, or the open side of a wall; erasing triangles makes their neighbours rim edges, so a gap you cut can be closed this way too). **Click into the empty middle of a gap** and its whole rim is taken at once - the editor probes around the cursor to find the surface the gap is cut into, so a hole is clickable even though there is nothing in it to hit (aiming at a hole in a bridge hits the ground below it, and one in a wall hits whatever is behind). **Shift+click** does the same from a single edge, following the rim round the outline. Click edges to select them one at a time (yellow; click again to drop one). The panel then plans the fill before anything is written: how many edges, loops and **triangles**, the **area**, the **texture** and the edge length it will match - so a clip in the view line tells you exactly what you will get. **Fill edges** (Enter) builds it: the selected edges are chained into loops and **ear-clipped**, or two separate rims are **bridged** with a loft (a gap between two wall pieces, a tear with both sides picked); an open chain is closed with a straight edge and the panel says so. Unlike Fill (5) it does not sample a grid - the rim's **own vertices become the patch outline**, so the new surface meets the course exactly with no overlap and no crack. Texture, surface class (road grip / wall collision) and **UVs** are continued from the face the rim belongs to, so texels line up with the neighbouring tile instead of restarting. **Match tri density** (on by default) splits the fill until its triangles are about the size of the surface beside the rim, capped at 12,000 triangles. Each fill is saved as a normal `patches` entry, so the game builds and collides with it like any other patch; **Clear edges** drops the selection.

    Edits are written to `assets/maps/<id>/decor.json` with **Save** (Ctrl+S): `props` (type, pos, yaw in degrees, scale, tint), `hidden` (surface index -> erased face indices), `hidden_surfaces` and `patches` (texture, class, vertices, UVs, indices, plus the paint grid and cells so a later stroke can extend the sheet). `Track` reads it whenever the map loads - props spawn, patches are built into their own mesh and get collision, erased triangles and hidden surfaces are skipped - so the game shows exactly what the editor shows. Re-baking the map keeps `decor.json`, but surface indices change, so re-check the clean-up (and re-add patches, which store world positions) after a re-bake.
  - **Character Importer:** put a model inside the project (e.g. `res://import/<name>/`) and enter its path. Set the type (runner or kart driver), which way it faces, the height and the split mode:
    - `auto`: biped split from the silhouette.
    - `nodes`: one part per mesh node, using the node origins as pivots.
    - `surfaces`: one part per surface.
    
    Then set roles per group and Export. This writes `assets/rigs/<id>.json`, its textures and `content/characters/<id>.json` with auto-detected paint zones. Test it: `godot --headless -s tools/test_importer.gd`.
  - **Animation Editor:** pick a character, pick a clip (or **New**) and author it by keyframing the rig's parts. A new state clip is filled with the real built-in animation, so idle/run/jump/hit (or drive/hit for kart drivers) is visible and editable straight away; to restore an existing clip to its built-in animation, choose the state under **Standard** and press **Import**. Run clips are fitted to a whole number of cycles so they loop cleanly. Click/drag the timeline to scrub. Pose parts directly in the 3D preview: click the model or one of its pivot dots to select a part and a Blender-style gizmo appears on its pivot - drag a **ring** to rotate about that axis, or drag an **arrow** (**Move** tool, or **G**) to slide along it. A click without dragging only selects (no accidental pose), **Alt-click** selects a part through the gizmo, and **[** / **]** step through parts; a pivot dot highlights under the cursor before you click it. **R** / **G** switch tools, **X** / **Y** / **Z** lock an axis (**Esc** clears it), **Shift-drag** on a part rolls, and the number fields stay in sync. Middle-drag (or right-drag) orbits, **Shift+middle** pans, wheel zooms, double-click or **F** frames. Every clip change is undoable with **Ctrl+Z** / **Ctrl+Shift+Z** (buttons next to Save), and **Ctrl+S** saves; **?** in the dock lists the shortcuts. **Auto-key** (on by default) stores every change at the playhead, so you can pose, scrub, pose again like stop-motion; **Key pose** stores the whole pose explicitly and **Del key** (or right-click a key) removes one. Clips are saved into `content/characters/<id>.json` under `"animations"` (nothing is written until **Save**). A clip named after a state replaces that state's code pose:
    - runners: `idle`, `run`, `jump`, `hit` (run playback follows speed, the others play in real time);
    - kart drivers: `drive` (or `idle`) for the seated pose and `hit` for the hit-stun blend.
    Characters without clips keep their built-in animation. The format is read by `src/rig/rig_anim.gd`: each clip has `length` (s), `loop`, `fps` and `keys`, and each key stores a full pose (`part` -> `{rot: [x,y,z] radians, off: [x,y,z]}`).
- Demo imports: `mario_runner` (Mario OBJ, auto split, as a runner) and `sonic_kart` (Sonic DAE, node split, as a kart driver). Both finish a lap: `res://scenes/test_lap.tscn -- --roster=mario_runner,sonic_kart`.
- `tools/bake/bake_track.py` and `assets/tracks/merged` are superseded by `trackbake.py` and `assets/maps/`.
