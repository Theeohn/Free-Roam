# Free Roam

Walk, run, cycle and surf in any direction on the normal overhead map, instead
of one tile at a time. Works on **Gen 1, Gen 2 and Gen 3**. The camera and view are
unchanged: same flat 2D overworld, just no longer locked to the grid.

- **Keys / d-pad:** eight directions. Hold two together for a true 45° diagonal.
- **Left stick:** a full 360°.
- **Phone touch d-pad:** eight directions or a full 360° (see `TOUCHPAD`).
- **Constant speed:** the stick sets the direction, not the speed.
- **Bike, running shoes and Surf:** work at their usual speed, and so do other
  mods that change walking speed.

## Install

**Easiest:** in the game's launcher, use **Import mod .zip** (or just drag
`Free-Roam_v0.5.1.zip` onto the game window). Works the same on Windows, Mac
and Linux.

**Manually:** unzip `Free-Roam_v0.5.1.zip` into a `Free-Roam` folder inside the
game's `mods` folder:

| OS | Mods folder |
| --- | --- |
| Windows | `%APPDATA%\LOVE\pokemon-love2d\mods\Free-Roam` |
| macOS | `~/Library/Application Support/LOVE/pokemon-love2d/mods/Free-Roam` |
| Linux | `~/.local/share/love/pokemon-love2d/mods/Free-Roam` |

(Portable installs keep `mods` in the game's own folder instead.)

Either way, finish by enabling **Free Roam** in the Mod Manager (`F10`) or a
profile.

Supports Red/Blue/Yellow, Gold/Silver/Crystal, and
Ruby/Sapphire/Emerald/FireRed/LeafGreen.

## Options

In the Mod Manager (`F10`) → **Free Roam** → **OPTIONS**.

| Option | Values | What it does |
| --- | --- | --- |
| `FREE ROAM` | ON / OFF | Turns the mod on or off. OFF gives you the normal grid walk back on the next frame, without restarting. |
| `STICK 360` | ON / OFF | ON: the left stick moves you in any direction. OFF: the stick acts like a d-pad (eight directions, or four with KEY DIAGONALS off). |
| `KEY DIAGONALS` | ON / OFF | ON: holding two directions on the keys or d-pad walks a true diagonal. OFF: keys and d-pad go four ways only, but you still move freely between tiles rather than snapping to the grid. |
| `TOUCHPAD` | DEFAULT / DIAGONAL / 360 | The on-screen d-pad on phones and tablets. DEFAULT: the game's own four directions. DIAGONAL: your thumb's angle picks one of eight directions. 360: you walk exactly where your thumb points, like a stick. Speed never depends on how far you push. |

`FREE ROAM`, `STICK 360` and `KEY DIAGONALS` start ON; `TOUCHPAD` starts on
DEFAULT. Menus and everything else still read the d-pad the normal way.

## How it works

The game still runs on its tile grid. The mod moves the player smoothly between
tiles and keeps track of which tile they're standing on, so the game's own rules
still handle everything tied to tiles: walls, grass, encounters, warps, ledges,
boulders, trainers, scripts and cutscenes. When you brush against a wall you
slide along it instead of stopping dead. Each generation has its own movement
code, so the mod hooks into the right one for the game you're playing.

Surfing works the same way: on the water you move freely at Surf's own speed,
and touching dry land steps you off as usual.

On diagonals the screen scrolls smoothly, the player sprite stays steady, and
the walk animation is slowed slightly so it matches the actual speed. Walking
from a town onto a route (or any other map edge) keeps you exactly where you
were walking, rather than putting you back on a tile line.

## Things to know

- On Gen 3, the **bicycle** still moves a tile at a time (any direction still
  works, as a zig-zag), because its Mach and Acro handling is the game's own.
  Walking, running, surfing and diving are fully free.
- **Ice, currents, spinner arrows, slides, waterfalls and whirlpools** keep the
  game's own tile-by-tile movement, so puzzles and story routes work exactly as
  intended. They act like a wall until you push straight into one; you are
  then lined up with the tile and the game takes over until you step off.
  Cycling Road's downhill slope also stays as normal.
- Ledge jumps, boulder pushes and (on Gen 3) the hop off the surf blob are the
  game's own moves. Pushing diagonally along a ledge or a shore slides you
  along it; push straight in to jump or land.
- Mods that change collision (such as a walk-through-walls cheat) work with the
  free walk the same way they work with the normal one.
- Works alongside [WoobleView](https://github.com/poooooby/gen3-hd-sprites)'s
  sharp overworld sprites (as used by Wilds of Hoenn): its Pokémon, followers
  and people scroll smoothly with the world.
- If anything looks wrong, set `FREE ROAM` to OFF. The normal walk returns on
  the next frame.

## Credits

**Contributors**

- **Theeohn**: author.
- **Claude** (Anthropic): co-developer.

**With thanks to**

- **absol89**: [DramaticShapeVoxelMod](https://github.com/absol89/DramaticShapeVoxelMod)
  and [Gen2Recomped-DramaticShapes](https://github.com/absol89/Gen2Recomped-DramaticShapes).
  Their free-walk movement is what Claude studied to work out how to make
  Free Roam work on Gen 3.
- Built for the Pokémon Gen 1 Recompilation Project by BOIS CLUB GAMES, LLC
  (https://github.com/bryanthaboi/gen1recomp).

## License

GPL-3.0 (see `LICENSE`), matching the project it builds on.
