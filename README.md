# Free Roam

Walk and cycle in any direction on the normal overhead map, instead of one tile
at a time. Works on **Gen 1, Gen 2 and Gen 3**. The camera and view are
unchanged: same flat 2D overworld, just no longer locked to the grid.

- **Keys / d-pad:** eight directions. Hold two together for a true 45° diagonal.
- **Left stick:** a full 360°.
- **Constant speed:** the stick sets the direction, not the speed.
- **Bike and running shoes:** work at their usual speed.

## Install

**Easiest:** in the game's launcher, use **Import mod .zip** (or just drag
`free_roam.zip` onto the game window) and pick the zip from this download.
Works the same on Windows, Mac and Linux.

**Manually:** unzip `free_roam.zip` into a `free_roam` folder inside the
game's `mods` folder:

| OS | Mods folder |
| --- | --- |
| Windows | `%APPDATA%\LOVE\pokemon-love2d\mods\free_roam` |
| macOS | `~/Library/Application Support/LOVE/pokemon-love2d/mods/free_roam` |
| Linux | `~/.local/share/love/pokemon-love2d/mods/free_roam` |

(Portable installs keep `mods` in the game's own folder instead.)

Either way, finish by enabling **Free Roam** in the Mod Manager (`F10`) or a profile.

Supports Red/Blue/Yellow, Gold/Silver/Crystal, and
Ruby/Sapphire/Emerald/FireRed/LeafGreen.

## Options

| Option | What it does |
| --- | --- |
| `FREE ROAM` | Turns the mod on or off. Off gives you the normal grid walk back instantly. |
| `STICK 360` | On: the stick moves in any direction. Off: the stick acts like a d-pad. |
| `KEY DIAGONALS` | Off: keys and d-pad go four ways only (movement stays off-grid). |

## How it works

The game still runs on its tile grid. The mod moves the player smoothly between
tiles and keeps track of which tile they're standing on, so the game's own rules
still handle everything tied to tiles: walls, grass, encounters, warps, ledges,
trainers, scripts and cutscenes. Each generation has its own movement code, so
the mod hooks into the right one for the game you're playing.

On diagonals the screen scrolls smoothly at sub-pixel precision, the player
sprite stays steady, and the walk animation is slowed slightly so it matches
the actual speed.

## Things to know

- On Gen 3, the **bicycle, surfing and diving** still move a tile at a time
  (any direction still works, as a zig-zag). Walking and running are fully free.
- Ice, currents, Cycling Road's downhill slope and similar forced movement use
  the game's normal behaviour.
- If anything looks wrong, set `FREE ROAM` to off. The normal walk returns on
  the next frame.

## Credits

- **Theeohn**: author.
- Built for the Pokémon Gen 1 Recompilation Project by BOIS CLUB GAMES, LLC
  (https://github.com/bryanthaboi/gen1recomp).
