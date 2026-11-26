-- Free Roam: omni-directional movement on the ordinary 2D overhead map, for
-- Generation 1, 2 and 3 of the recomp.
--
-- The engine walks a grid -- a fixed number of frames per cell, four
-- directions, input locked mid-step. This mod replaces that WALK and nothing
-- else. The player moves at any angle and slides along whatever they graze.
-- Nothing about the CAMERA changes: no free look, no pitch, no 3D. The view
-- stays the flat overhead one the engine always drew, following the player the
-- way it always did. (That is the whole point of writing this fresh rather
-- than lifting it out of the voxel mod, whose free walk only exists WHILE its
-- first/third-person camera is driving -- see README.)
--
-- Input shape:
--   keys / d-pad   the eight compass directions; down+left is a true 45-degree
--                  walk, not a stair-step; opposite keys cancel.
--   left stick     a full 360, read off the raw analog axes.
--   speed          CONSTANT whatever the deflection: the stick chooses a
--                  heading, never a velocity. Pace is taken from the engine's
--                  OWN step length, so the bicycle, Gen 3's running shoes, the
--                  Mach/Acro bikes and any movement.speed hook all carry
--                  through on their own rather than being restated here.
--
-- THE GRID IS STILL THE GAME. Every fact the world cares about is a fact about
-- cells -- what blocks, what warps, what rustles, what bites. This mod keeps
-- the player's logical cell synced to wherever the free walk stands and reuses
-- the engine's OWN per-generation machinery for every one of those questions.
-- It does that by patching, per generation, the real native module that owns
-- movement -- never the Gen-1-shaped compat facade, which has no pre-step seam
-- on Gold or FireRed. One arm per generation, because the three engines do not
-- share a movement shape:
--
--   Gen 1   src.world.OverworldController IS the live overworld; its
--           handleInput is the single choke point the grid walk reads the pad
--           through, so the arm wraps it and runs a pixel-continuous body.
--   Gen 2   src.world.gen2.World's stepBody runs once a frame; the arm moves
--           the body continuously inside it (the same model the Gen 1 arm
--           uses), keeps the cell honest through the engine's own landing
--           events, and leaves scripts, surf, ice and Cycling Road native.
--   Gen 3   src.core.game3.player's Player.update reads the pad and
--           Player.tryMove(dir, game, run, input) is the authentic single
--           step; the arm neuters the native direction read, lets update run
--           all its gates, and fires tryMove once per cell crossed.
--
-- Nothing here writes save state, rolls encounters or decides what a warp
-- does. It moves a point, keeps the cell honest, and lets the engine be the
-- engine. Turn the option off, or let any native assumption fall through, and
-- the grid walk is back on the next frame.

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules are loaded with mod:read + load, the sandbox-approved way: a
-- mod directory is not on package.path and may live inside a mounted archive
-- plain require cannot reach. Each module is loaded once, handed V as its
-- vararg (`local V = ...`).
local V = { mod = mod }

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local source = mod:read("lib/" .. name .. ".lua")
  if not source then
    error("free_roam: lib/" .. name .. ".lua is missing -- reinstall the mod", 0)
  end
  local chunk, err = load(source, "=free_roam/lib/" .. name)
  if not chunk then
    error("free_roam: lib/" .. name .. " did not compile: " .. tostring(err), 0)
  end
  local value = chunk(V)
  modules[name] = value
  return value
end

-- ------- options (shared by every arm)
mod.options:define({
  { key = "enabled",   label = "FREE ROAM",     type = "toggle", default = true },
  { key = "analog",    label = "STICK 360",     type = "toggle", default = true },
  { key = "diagonals", label = "KEY DIAGONALS", type = "toggle", default = true },
  { key = "touchpad",  label = "TOUCHPAD",      type = "choice", default = "default",
    choices = { { "DEFAULT", "default" }, { "DIAGONAL", "diagonal" }, { "360", "360" } } },
  { key = "truePace",  label = "TRUE PACE",     type = "toggle", default = false },
})

function V.option(key, default)
  local value = mod.options:get(key)
  if value == nil then return default end
  return value
end

-- ------- which generation are we on?
--
-- GameVersion is generation-neutral (it is what the loader itself reads to
-- pick a compat arm), so requiring it is safe on every boot. Absent / failing
-- reads as Gen 1, the engine's own default.
local function generation()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if ok and GameVersion and type(GameVersion.generation) == "function" then
    local n = GameVersion.generation()
    if n == 2 or n == 3 then return n end
  end
  return 1
end

V.core = V.require("core")
V.generation = generation()

-- the sub-pixel remainder the Gen 1 pixel walk drops when it writes a
-- whole-pixel player position; the smooth-scroll wrap rides it onto the world
-- blit so the camera scrolls between game-pixels. Zero on every other arm.
V.subpixel = { x = 0, y = 0 }

-- ------- dispatch: one arm, requiring only its own generation's natives
--
-- The require of each arm is lazy and branch-local, so a Gen 2 boot never
-- names src.world.OverworldController (a Gen-1-only module the loader would
-- otherwise reroute to the facade) and a Gen 1 boot never names a gen2/game3
-- tree. A failed install leaves the grid walk untouched rather than a
-- half-patched engine.
local arm
if V.generation == 2 then
  arm = V.require("gen2")
elseif V.generation == 3 then
  arm = V.require("gen3")
else
  arm = V.require("gen1")
end

local ok, err = pcall(arm.install, V)
if not ok then
  -- Never leave movement broken: report and stand down.
  if mod.log then mod.log("free_roam install failed: " .. tostring(err)) end
end

-- the phone d-pad as an 8-way / 360 heading (TOUCHPAD option)
local okTouch, errTouch = pcall(function() return V.require("touch").install() end)
if not okTouch and mod.log then
  mod.log("free_roam touch install failed: " .. tostring(errTouch))
end

-- sub-pixel smooth scroll (Gen 1 only in effect; a no-op where no remainder is
-- reported). Guarded: a render-wrap failure must never break movement.
local okScroll, errScroll = pcall(function() return V.require("smoothscroll").install() end)
if not okScroll and mod.log then
  mod.log("free_roam smoothscroll install failed: " .. tostring(errScroll))
end

-- ------- exports (uniform across arms)
mod.exports.version = "0.5.21"
mod.exports.generation = V.generation
mod.exports.active = function()
  return V.option("enabled", true) ~= false and arm.active ~= nil and arm.active()
end
mod.exports.position = function()
  if not arm.position then return nil end
  return arm.position()
end
-- named for the suite: the pure core and the active arm's internals, so each
-- generation's walk can be driven headlessly
mod.exports._internal = {
  core = V.core,
  generation = V.generation,
  arm = arm,
  subpixel = V.subpixel,
}
