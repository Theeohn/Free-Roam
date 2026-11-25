# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## 0.4.3

### Fixed

- **A walk-through-walls cheat (e.g. goofwear's gameshark mod) worked on Gen 3
  but not Gen 1 or Gen 2.** Gen 3's foot body moves by chaining real native
  steps, so it was already asking the native Gen 3 collision check for every
  cell -- the same function a mod like that wraps -- and inherited the cheat
  for free. Gen 1 and Gen 2 ask their own cell-by-cell questions instead (map
  bounds, tile walkability, tile pairs, NPCs and entities), because free
  motion slides a continuous body rather than taking one grid step at a time,
  and that hand-rolled check never consulted the engine's `movement.collision`
  mod hook the way `Collision.canMove` (Gen 1) and `Player:tryMove` (Gen 2) do
  for a grid step. Both arms now fire that same hook for every cell they ask
  about, with the same `{ map, mover, dir, fromX, fromY, toX, toY, reason }`
  shape the native grid step builds, so a mod hooking it (a cheat that waives
  collision, or one that adds a block) governs the free walk exactly as it
  already governs the grid walk. Map edges are unaffected unless the hook
  itself chooses to waive them (`reason == "bounds"`), matching how the
  native grid step treats a hooked map edge.

### Notes

- 313 headless checks pass, including direct checks that a chain installed on
  `movement.collision` lets the free walk cross a cell it would otherwise
  refuse (and that map bounds are untouched unless the hook says otherwise),
  and that with no mod hooking anything the free walk's collision is
  unchanged from 0.4.2.

## 0.4.2

### Fixed

- **Gen 1 player sprite jittered on diagonals.** The 0.2.0 smooth scroll shifts
  the whole world canvas by the sub-pixel remainder, and the player is drawn
  into that canvas at whole pixels, so the shift also slid the player up to half
  a game pixel each frame along the direction of travel. The world pass is now
  split at the player's own draw call: before and after the player are shifted
  with the world, the player is not, and they are composited in that order, so
  tall-grass feet and anything else drawn over the player still cover it. The
  real world canvas is merged back to the complete frame for anything else that
  reads it.
- **Gen 3 overworld judder on diagonals (on foot).** FireRed's field view draws
  into the same game-resolution world canvas with a camera floored to the
  player's whole pixel. The Gen 3 foot body now reports its sub-pixel remainder,
  so the 0.2.0 smooth scroll applies, and the player gets the same layer so it
  holds still while the world scrolls. Standing still keeps the exact position,
  so there is no pop on stopping. The bicycle, surf and dive (native steps) are
  unchanged.
- In the GBC sprite-colour mode, sprites replayed over the world after the blit
  were not shifted with it. They now are, except the player's own.

### Notes

- The split only engages on frames the free walk is driving, in the flat path
  (not tilt, a render pipeline or a fade), and folds itself back before a
  mid-pass canvas swap such as FireRed's weather. Otherwise frames are drawn
  exactly as before.
- The player and after layers are composited premultiplied, so translucent
  overlays drawn after the player (fog, flash darkness) keep their exact colour.
- 306 headless checks pass, against a fake `love.graphics` that records every
  canvas's contents: the three-part composite and its order, the shift on the
  world parts only, the merged frame, GBC replays, the rest cases, a mid-pass
  swap, Gen 3's remainder, and the player holding one screen position across
  20- and 30-frame diagonals.

## 0.4.1

### Fixed

- **Gen 2 player sprite jittered on diagonals after 0.4.0's smooth scroll.**
  Gold's sprite renderer floors the sprite's position to whole game pixels,
  while the camera origin it is drawn from is floored at window pixels. With the
  fractional position 0.4.0 gives the draw, those two roundings disagreed by a
  different amount each frame, so the sprite jumped by up to a game pixel. The
  sprite now draws from its whole-pixel position and the fraction is folded into
  its window-pixel origin, rounded once, so the player lands on the same window
  pixel every frame while the world scrolls smoothly. The player's own draw
  function is restored after every frame.

### Notes

- 265 headless checks pass, including the sprite holding one window pixel over a
  40-frame diagonal at window scales 3, 2.5 and 4.

## 0.4.0

### Added

- **Sub-pixel smooth scroll on Gen 2 (Gold/Silver/Crystal).** Diagonals no
  longer make the overworld look jagged. Gold draws the world straight to the
  window, offset by a camera centred on the player's whole-pixel position, so
  at constant diagonal speed the camera stepped unevenly. `World:draw` is now
  wrapped: during the draw only, the player carries the body's exact fractional
  position, so the camera, map, neighbours and NPCs scroll smoothly at
  window-pixel resolution and the player stays fixed on screen. Whole pixels are
  restored as soon as the draw returns, including on error, so game logic never
  sees a fraction. It only applies while free motion owns the position; native
  steps, warps, scripts and the option being off draw exactly as before.

### Notes

- 255 headless checks pass, including that a 45 scrolls the camera the same
  0.707 px every frame, that px is whole again after every draw, and that the
  draw is untouched when free motion does not own the position.
- Gen 1 keeps its canvas-blit smooth scroll; Gen 3 is unchanged.

## 0.3.3

### Changed

- **Diagonal walk cadence eased from 0.70 to 0.80 of the cardinal rate** (all
  three generations). 0.3.2's cut was slightly too much. `C.ANIM_DIAGONAL` in
  `lib/core.lua` is still the one constant; the blend between a cardinal (1.0)
  and a true 45 is unchanged. Movement speed is untouched.

### Notes

- 242 headless checks pass. The cadence tests now derive their expectation from
  `ANIM_DIAGONAL` rather than a hard-coded 70, so a retune is a one-line change.

## 0.3.2

### Changed

- **Walk animation slowed on diagonals, in Gen 1, Gen 2 and Gen 3.** A diagonal
  covers the same ground per frame as a cardinal, but the legs cycling at the
  full rate looked faster than the body was moving. The leg cadence is now 1.0
  on a cardinal and 0.7 on a true 45, blended smoothly by how diagonal the
  heading is (`C.animRate` in `lib/core.lua`, one constant, `ANIM_DIAGONAL`).
  Movement speed is unchanged.
  - Gen 1 and Gen 2: only that share of the walk clock's per-frame ticks go
    through; Gen 2's foot flip follows the same rate so the foot still changes
    once per leg cycle.
  - Gen 3: the cycle was advanced by the sum of both axis distances, running a
    diagonal's legs 1.41 times fast. It now advances by the ground actually
    covered times the rate.
- The bicycle, surf and any step the engine owns keep the engine's animation.

### Notes

- 242 headless checks pass: the rate itself (cardinal, 45, blends, never speeds
  back up toward a 45), and each arm's leg clock for keys and for the stick. With
  any one arm's throttle removed its tests fail.

## 0.3.1

### Fixed

- **Gen 3 sprite flipped between its two sides on diagonals.** Walking down-left
  (or any diagonal) the body crosses cell lines on alternating axes, and each
  crossing starts a native step whose `tryMove` turns the player to that step's
  cardinal, so the sprite flickered between, say, the front and the left
  sprite. The arm now keeps the heading's sticky facing (the same rule Gen 1 and
  Gen 2 use) across the native step and across a wall push, so a diagonal holds
  one side steadily. Specials the engine owns (a ledge hop, stairs, a connection)
  still face the way the engine turns the player.

### Notes

- 224 headless checks pass, including a diagonal-facing regression for SE, SW, key
  diagonals, a steep heading and a wall slide.

## 0.3.0

### Changed

- **Gen 3 on foot (Ruby/Sapphire/Emerald/FireRed/LeafGreen) now moves freely.**
  Walking and running shoes use a continuous body, like Gen 1 and Gen 2, instead
  of steering the direction of grid steps. Native `Player.update` runs with the
  d-pad blanked so every gate still runs; the heading times the engine's own pace
  (`ordinaryStepFrames`, so running shoes and any `movement.speed` mod carry
  through) moves the body, slid one axis at a time against `Collision.canEnter`.
  When the body's centre crosses a cell boundary the arm starts a real native
  one-cell step and primes it to land on the next tick, so `finishStep` does all
  the landing work (grass, step events, warps, encounters, save position).
- A plain wall bump keeps the engine's collision sound but is cancelled, so the
  body is never locked in the bump animation. Ledges, stairs, warp doors, map
  connections and Strength boulders are handed to the engine's own step whole.
- The walk leg and the stepping foot are driven from the distance walked, so the
  sprite animates and alternates feet.

### Unchanged

- **The Gen 3 bicycle, surfing, diving and mid-hop keep the engine's native step
  with its direction steered** (tile-granular). The RSE bike reads the d-pad every
  frame (Mach speed-up and slow-down, Acro button history), and driving it from a
  continuous body without a running game risked breaking it. Its speed is still the
  engine's own.

### Notes

- Built from the engine's real seams and from the reference Gen 3 free walk;
  unit-tested against a mock engine (215 headless checks). Not yet played on a ROM.
- Gen 2 and Gen 3 have no sub-pixel smooth scroll yet, so diagonals there show the
  whole-pixel scroll.
- `modkit validate` and `modkit lint` are clean; `gen3check` still reports the two
  documented false positives, both in the Gen-1-only file.

## 0.2.1

### Fixed

- **Gen 2 (Gold/Silver/Crystal) did not move freely.** 0.1.1 decided the
  direction once per native grid step, so a held diagonal became a staircase and
  the player was still tied to the grid. Gen 2 now uses the same continuous model
  as Gen 1: `World:stepBody` moves the body once a frame by the heading times the
  engine's own pace (1 px/frame on foot, 2 px/frame on the bicycle), slides it
  against the engine's cell verdicts, and runs the landing pipeline once per cell
  crossed. The native grid step never starts while the body is free.
- Gen 2 hands back to native for text, menus, scripts, field moves, fishing,
  headbutt, the map-setup chain, surf, forced tiles (ice, currents, whirlpools,
  forced doors) and Cycling Road. A firm push into a ledge, a map edge or a
  boulder asks the engine's own handler once, then rests for a few frames while
  the engine animates the jump or push.

### Notes

- The Gen 2 arm is built from the engine's own seams and from the reference
  Gold/Silver free walk, and it is unit-tested against a mock engine. It has not
  been re-played on Crystal yet.
- Gen 2 has no sub-pixel smooth scroll yet: Gold composites its world and UI into
  one canvas, so the Gen 1 blit shift does not apply there. Diagonals on Gen 2
  show the whole-pixel scroll.
- 166 headless checks pass; `modkit validate` and `modkit lint` are clean.

## 0.2.0

### Added

- **Sub-pixel smooth scroll (Gen 1) — constant speed *and* smooth.** The real
  fix for the diagonal judder. The overworld camera snaps to whole game-pixels,
  so at the true constant diagonal speed (0.707 px/frame per axis) the scroll
  steps unevenly and judders; 0.1.1 was smooth only because it sped diagonals up
  to a whole pixel per axis. This splits the scroll instead: the whole-pixel
  part stays baked into the world canvas (tiles stay crisp), and the sub-pixel
  remainder the pixel-write drops is ridden onto the world canvas's blit as a
  fractional, window-pixel shift (`lib/smoothscroll.lua` wraps
  `Renderer:blitCanvas`). The two sum back to the player's true continuous
  position, so the world scrolls smoothly *between* game-pixels at the exact
  speed, with no toggle. Only the world canvas is shifted — the UI stays
  pixel-locked — and the wrap is a no-op on Gen 2 / Gen 3 (whose motion is the
  native whole-cell step) and when free roam is off.

### Changed

- Gen 1 reverted 0.1.1's max-norm speed-up: diagonals are constant speed again
  (0.707 px/frame per axis, same as a cardinal, at any deflection). Smoothness
  now comes from the sub-pixel scroll above rather than from changing the speed.
- Suite grew to 148 checks, including the sub-pixel remainder (it reconstructs
  the true position exactly), the world-blit shift, the UI staying unshifted,
  and the remainder zeroing when the grid walk resumes.

### Notes

- Sub-pixel scrolling of nearest-filtered pixel art shifts the pixel blocks
  sub-block at the window scale: smooth motion, with at most a 1 window-pixel
  wobble in block width at tile boundaries (the inherent cost of the technique).
  If that reads oddly in game, `FREE ROAM = OFF` restores the vanilla grid walk.

## 0.1.1

Bug fixes from the first in-game testing (Yellow and Crystal).

### Fixed

- **Gen 2 (Gold/Silver/Crystal) did nothing.** The arm decided direction in
  `pollInput` gated on the player being idle, but Gold chains steps back-to-back
  so the player is never idle at poll time during a walk — the DDA stepper
  almost never ran and native's first-held cardinal drove every step, collapsing
  diagonals to one axis. The direction decision now happens at `World:movePlayer`,
  the hook that fires exactly once per step, so a heading becomes the right
  even staircase. (The Gen 3 arm had the same bug class and is rebuilt the same
  way, deciding at `Player.tryMove` driven through `Player.update`.)
- **Gen 1 diagonal camera judder.** On a 45-degree walk both axes advanced
  0.707 px/frame in lockstep, so the whole-pixel, unsmoothed camera froze a
  frame every third frame. The velocity is now max-normed: the dominant axis
  moves a clean whole pixel per frame, so a 45 is (1,1) every frame — no frozen
  frames. The angle stays exact and speed is still independent of stick
  deflection; the one change is that a pure diagonal now travels up to ~1.41x
  the cardinal rate (the standard top-down trade for a judder-free scroll on a
  pixel-snapped camera).

### Changed

- Test suite grew to 118 checks, including the once-per-step regression
  (a held diagonal must stay an even stream across chained steps) on both Gen 2
  and Gen 3, and the max-norm maths.

## 0.1.0

First release. Omni-directional movement on the ordinary 2D overhead map,
across Gen 1, Gen 2 and Gen 3. No camera changes.

### Added

- Omni-directional overworld movement in place of the four-direction grid walk:
  keys, WASD and the d-pad give the eight compass directions (down+left is a
  true 45-degree walk, normalised so a diagonal covers the same ground as a
  straight line); a left stick gives a full 360 off its raw axes, with a
  deadzone, at a constant pace whatever the deflection — the stick picks a
  heading, never a velocity.
- **All three generations**, with one arm per generation patching that
  generation's own native movement module directly, bypassing the Gen-1-shaped
  compat facade (which has no pre-step seam on Gold or FireRed):
  - Gen 1 (`src/world/OverworldController.lua`): `handleInput` is wrapped and a
    pixel-continuous body runs in place of the grid step. The logical cell stays
    synced to the body, and `onStepComplete` fires once per cell crossed, so
    warps, spinners, badge gates, forced movement, encounters, poison and the
    step counters are the engine's own. Wall sliding comes from axis-separated
    resolution against the engine's collision verdicts (water passable while
    surfing, NPCs blocking via the occupancy test); firm blocked pushes hand off
    to `checkEdgeExit` / `checkLedgeHop` / `checkBoulderPush` and the collision
    warp.
  - Gen 2 (`src/world/gen2/World.lua`): `World:pollInput` is wrapped so the
    heading sets `heldDir`; the untouched native `stepBody`/`movePlayer` step
    machine does the rest. Cycling Road downhill is left native.
  - Gen 3 (`src/core/game3/player.lua`): `Player.update` is wrapped so the pad
    asserts the chosen cardinal while A/B (running shoes), the bikes and
    everything else pass through; the native `update` gates and calls `tryMove`
    itself.
- Bicycle support at the engine's own bike pace. Pace is read from the engine
  (Gen 1 `Player:stepLength`; Gen 2/Gen 3 let the native step compute its own
  frames), so the bicycle, the slope rule, Gen 3 running shoes, the Hoenn Mach
  and Acro Bikes, the single FR/LG bike and any other mod's `movement.speed`
  hook all carry through.
- A shared digital-differential-analyser stepper (`lib/core.lua`) that turns a
  360/eight-way heading into the correct stream of native cardinal steps, so Gen
  2 and Gen 3 are omni-directional at tile granularity at the engine's own,
  deflection-independent pace (Gen 1 is pixel-continuous).
- Four-direction facing quantisation with a sticky tie, so a diagonal walk does
  not strobe between two sprite facings.
- `FREE ROAM`, `STICK 360` and `KEY DIAGONALS` mod options; turning `FREE ROAM`
  off restores the native grid walk on the next frame.
- `active()`, `position()` and `generation()` exports for other mods.
- A 110-check headless suite (`tests/free_roam_test.lua`): the Gen 1 pixel walk,
  the shared core maths, and the Gen 2 and Gen 3 arm seams against mock engines.

### Notes

- Each per-generation file is load-isolated — only the arm matching the booted
  game is ever loaded.
- Gen 2 and Gen 3 are built to each engine's real native movement contract and
  verified by compile, the unit suite, `modkit validate` and `modkit lint`, but
  have not been played on a real ROM in the build environment. They fail safe to
  the native grid walk. `gen2check`/`gen3check` report `will not work`; that
  static scan cannot follow per-generation load isolation and fails the proven
  multi-gen reference the same way — see README, *Generations and how this was
  verified*.
