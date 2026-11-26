# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## [0.5.1] - 2026-11-26

### Fixed
- **Emerald (any Gen 3 game) with WoobleView: NPCs, overworld Pokémon and
  followers vibrating on diagonals, and the follower losing its shape.**
  WoobleView draws those sprites itself, at screen resolution, when the
  world is put on screen, and places them from where the world is drawn.
  Free Roam's smooth scroll moved the world but not their starting point, so
  they wobbled against the ground by up to a pixel; and its split of the
  frame around the player hid every sprite drawn after the player from
  WoobleView (that was the follower's broken shape when walking up). With
  WoobleView drawing the field, Free Roam now leaves the frame whole, moves
  WoobleView's sprites with the world, and keeps the player still by handing
  its sprite to WoobleView too, nudged back by the same amount. Without
  WoobleView nothing changes.
- The smooth scroll now stays the last word on where the world is drawn even
  when another mod wraps the same step after it, and never moves anything
  twice.

## [0.5] - 2026-11-25

### Added
- **TOUCHPAD option** (DEFAULT / DIAGONAL / 360) for the on-screen d-pad on
  phones and tablets. DIAGONAL turns your thumb's angle into eight
  directions; 360 walks exactly where your thumb points. DEFAULT is the
  game's own four directions.
- **Free surfing on all three generations.** On the water you move in any
  direction at Surf's own speed, with the same 8-way keys and 360° stick as
  on land. Stepping onto dry land ends the surf the way the game does
  (Gen 3's hop included).

### Fixed
- **Gen 3: NPCs, overworld Pokémon and grass jittering on diagonals.** The
  smooth scroll now moves the world in whole screen pixels, so sprites no
  longer shimmer against the steady player. The player is also held still
  when the game draws it through its fallback sprite path, with the surf bob,
  or under the surf blob, and on weather frames that recolour the screen.
- **Leaving a town for a route snapped the player onto a grid line.** At a
  map edge the player now carries on along the exact line they were walking
  (all 11 games). Doors and other warps are unchanged.

### Changed
- **Ice, currents, spinner arrows, slides, waterfalls and whirlpools** are
  entered through the game's own tile step on every game: the free walk
  treats them as a wall until you push straight in, lines you up with the
  tile, and hands over. The game then runs them tile by tile exactly as
  normal, so puzzles and story routes can't be broken.
- Engine steps that start from a push (forced tiles, Gen 3 ledges and the
  surf hop, map edges) begin from where you stand, not from the tile's edge.

## [0.4.4] - 2026-11-25

First public release.
