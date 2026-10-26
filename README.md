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
- **Editor plugin "Retro Karting Tools"** (enabled in Project Settings → Plugins) adds two bottom-panel docks:
  - **Map Combiner:** choose segments from the source tracks (whole loop, cut section, or piece range). Place them by dragging, Shift-drag to rotate, wheel to zoom and right-drag to pan. "Pick" buttons set cut points and the start. Each connector can have a vertical loop. **Bake** runs `tools/bake/trackbake.py` (needs Python 3 with numpy, pillow, opencv-python, scikit-image, networkx and matplotlib; set the Python path in the dock). It writes `assets/maps/<id>/`.
  - **Character Importer:** put a model inside the project (e.g. `res://import/<name>/`) and enter its path. Set the type (runner or kart driver), which way it faces, the height and the split mode:
    - `auto`: biped split from the silhouette.
    - `nodes`: one part per mesh node, using the node origins as pivots.
    - `surfaces`: one part per surface.
    
    Then set roles per group and Export. This writes `assets/rigs/<id>.json`, its textures and `content/characters/<id>.json` with auto-detected paint zones. Test it: `godot --headless -s tools/test_importer.gd`.
- Demo imports: `mario_runner` (Mario OBJ, auto split, as a runner) and `sonic_kart` (Sonic DAE, node split, as a kart driver). Both finish a lap: `res://scenes/test_lap.tscn -- --roster=mario_runner,sonic_kart`.
- `tools/bake/bake_track.py` and `assets/tracks/merged` are superseded by `trackbake.py` and `assets/maps/`.
