-- FREE ROAM / touch: the on-screen d-pad as an 8-way or 360-degree heading.
--
-- The engine's touch d-pad (src/core/TouchControls.lua) turns the finger
-- into ONE held direction: whichever axis it leans on most, so a phone can
-- never walk a diagonal.  This module watches the same finger, keeps where it
-- sits relative to the d-pad's centre, and hands lib/core a heading built from
-- that vector instead of from the single held direction:
--
--   DEFAULT   the engine's own behaviour, untouched (four directions)
--   DIAGONAL  the finger's angle snapped to the eight compass points
--   360       the finger's exact angle, like the left stick
--
-- Speed never comes from the finger's distance: the heading is a unit
-- vector, exactly like the stick and the keys.  Inside the d-pad's centre
-- dead zone (the engine's own size) there is no heading, so lifting the
-- thumb to the middle stops the walk the way it always has.
--
-- Only the free walk reads this.  The engine still presses its own one
-- direction for menus, the grid walk with FREE ROAM off, and everything else.
-- Custom touch skins route their own controls and are left alone.

local V = ...
local C = V.core

local M = {}

local DEAD = 0.16           -- the engine's DPAD_DEAD, as a share of the d-pad width
local SQRT_HALF = 1 / math.sqrt(2)

-- the live d-pad finger: dx, dy from the d-pad centre and the pad width
local finger = nil

function M.mode()
  local m = V.option("touchpad", "default")
  if m == "diagonal" or m == "360" then return m end
  return "default"
end

-- the finger's heading under the current mode, or nil (no finger, the
-- dead zone, or DEFAULT)
function M.heading()
  local f = finger
  if not f then return nil end
  local mode = M.mode()
  if mode == "default" then return nil end
  local dx, dy, w = f.dx, f.dy, f.w
  local dead = (w or 0) * DEAD
  if math.abs(dx) < dead and math.abs(dy) < dead then return nil end
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return nil end
  if mode == "360" then return dx / len, dy / len end
  -- DIAGONAL: the nearest of eight 45-degree sectors
  local a = math.atan2(dy, dx)
  local k = math.floor(a / (math.pi / 4) + 0.5) % 8
  local HX = { 1, SQRT_HALF, 0, -SQRT_HALF, -1, -SQRT_HALF, 0, SQRT_HALF }
  local HY = { 0, SQRT_HALF, 1, SQRT_HALF, 0, -SQRT_HALF, -1, -SQRT_HALF }
  local hx, hy = HX[k + 1], HY[k + 1]
  if math.abs(hx) < 1e-9 then hx = 0 end
  if math.abs(hy) < 1e-9 then hy = 0 end
  return hx, hy
end

-- testing / other callers
function M._set(dx, dy, w) finger = dx and { dx = dx, dy = dy, w = w or 100 } or nil end
function M._finger() return finger end

local function track(self, id, x, y)
  local touch = self.touches and self.touches[id]
  if not (touch and touch.control == "dpad") then return end
  local ok, L = pcall(self.layout, self)
  local dz = ok and type(L) == "table" and L.dpad
  if not (dz and dz.cx and dz.cy) then return end
  finger = { id = id, dx = x - dz.cx, dy = y - dz.cy, w = dz.w or 100 }
end

function M.install()
  local ok, TC = pcall(require, "src.core.TouchControls")
  if not ok or type(TC) ~= "table" or TC.freeRoamTouchHook then return false end
  local pressed, moved, released, reset = TC.touchpressed, TC.touchmoved, TC.touchreleased, TC.reset
  if type(pressed) ~= "function" or type(moved) ~= "function"
     or type(released) ~= "function" then
    return false
  end

  TC.touchpressed = function(self, id, x, y, ...)
    local r = pressed(self, id, x, y, ...)
    pcall(track, self, id, x, y)
    return r
  end
  TC.touchmoved = function(self, id, x, y, ...)
    local r = moved(self, id, x, y, ...)
    pcall(track, self, id, x, y)
    return r
  end
  TC.touchreleased = function(self, id, x, y, ...)
    if finger and finger.id == id then finger = nil end
    return released(self, id, x, y, ...)
  end
  if type(reset) == "function" then
    TC.reset = function(self, ...)
      finger = nil
      return reset(self, ...)
    end
  end
  TC.freeRoamTouchHook = true

  -- lib/core's heading asks this first
  C.touchHeading = M.heading
  return true
end

return M
