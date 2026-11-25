-- FREE ROAM / core: the generation-agnostic movement math.
--
-- Nothing in here touches the engine. It turns raw input into a heading and
-- resolves a circular body against a 16-px cell grid, given a caller-supplied
-- verdict for whether a cell blocks. Every arm (Gen 1, 2, 3) leans on the same
-- pieces so the FEEL -- the deadzone, the constant speed, the true 45-degree
-- diagonal, the sticky facing -- is identical across all three, and so the one
-- place that math can go wrong is unit-tested once.
--
-- Loaded as a plain chunk: `local C = dofile-equivalent`. The mod passes its
-- namespace in, but core needs none of it, so it ignores the vararg.

local C = {}

C.RADIUS = 5.5        -- the body as a circle in the ground plane. Half a cell
                      -- is 8, so 5.5 clears every one-cell corridor while still
                      -- reading as a body against a wall.
C.EPS = 0.01
C.STICK_DEAD = 0.28   -- past this the stick is a heading; below it, idle.
C.TIE = 0.18          -- how close to a 45-degree tie keeps the old facing.

-- ------- the heading: a UNIT vector or nil
--
-- Every caller multiplies it by the engine's own pace, so the magnitude of a
-- stick push can never become a speed. A feather touch and a hard shove return
-- the same unit vector; only the ANGLE differs.

-- The left stick's raw axes, the only place a full 360 can come from (the
-- engine quantises them into d-pad presses for the grid walk).
function C.stickHeading(input, dead)
  local ax = input and input.stickAxis
  if not ax then return nil end
  local x, y = ax.x or 0, ax.y or 0
  local mag = math.sqrt(x * x + y * y)
  if mag <= (dead or C.STICK_DEAD) then return nil end
  return x / mag, y / mag
end

-- Keys, the on-screen d-pad and a real d-pad all arrive as held buttons: eight
-- directions, normalised so a diagonal is not faster than a straight line.
-- With diagonals off it collapses to four-way but stays off-grid, keeping the
-- axis the body already shows so a corner does not snap the facing.
function C.keyHeading(input, allowDiagonal, facing)
  local mx = (input:isDown("right") and 1 or 0) - (input:isDown("left") and 1 or 0)
  local my = (input:isDown("down") and 1 or 0) - (input:isDown("up") and 1 or 0)
  if mx == 0 and my == 0 then return nil end
  if mx ~= 0 and my ~= 0 then
    if not allowDiagonal then
      if facing == "left" or facing == "right" then my = 0 else mx = 0 end
    else
      local inv = 1 / math.sqrt(2)
      return mx * inv, my * inv
    end
  end
  return mx, my
end

-- The resolved heading: stick first when analog is on and deflected, else keys.
function C.heading(input, o)
  o = o or {}
  if o.analog ~= false then
    local sx, sy = C.stickHeading(input, o.dead)
    if sx then return sx, sy end
  end
  return C.keyHeading(input, o.diagonals ~= false, o.facing)
end

-- ------- facing: the heading as one of the grid's four directions
--
-- What the game (and the sprite sheet) reasons in: what A talks to, which way
-- a push leans, which walk frame draws. Near a 45-degree tie the body keeps
-- whichever point it already showed so a diagonal walk does not strobe; off a
-- tie the lead axis wins; on a tie with no prior match the vertical point wins
-- (the sheet has no diagonal, and a back/front view reads better than a
-- profile while walking into the screen).
function C.quantise(dx, dy, current, tie)
  tie = tie or C.TIE
  if dx == 0 and dy == 0 then return current or "down" end
  local ax, ay = math.abs(dx), math.abs(dy)
  local horiz = dx > 0 and "right" or "left"
  local vert = dy > 0 and "down" or "up"
  if dx == 0 then return vert end
  if dy == 0 then return horiz end
  if math.abs(ax - ay) <= tie * math.max(ax, ay)
     and (current == horiz or current == vert) then
    return current
  end
  return (ax > ay) and horiz or vert
end

-- The single dominant cardinal of a heading, for a native single-step call
-- that only understands up/down/left/right. Unlike quantise it has no sticky
-- tie: a native step wants the axis the body is actually travelling fastest
-- along this frame.
function C.cardinal(dx, dy)
  if (dx == 0 or dx == nil) and (dy == 0 or dy == nil) then return nil end
  if math.abs(dx) >= math.abs(dy) then
    return dx > 0 and "right" or "left"
  end
  return dy > 0 and "down" or "up"
end

-- ------- the slide: one axis at a time against a cell verdict
--
-- `blocked(cx, cz)` returns a reason string when that cell refuses the body or
-- nil when it may enter. Clamping at the first refusing cell's face is where
-- wall-sliding comes from: the blocked axis stops at the wall and the free one
-- keeps going, so a diagonal into a wall runs along it. Returns the new
-- coordinate and the refusal (or nil) so the caller can aim a push.

function C.slideX(x, z, dx, radius, blocked)
  if dx == 0 then return x, nil end
  radius = radius or C.RADIUS
  local nx = x + dx
  local z0 = math.floor((z - radius + C.EPS) / 16)
  local z1 = math.floor((z + radius - C.EPS) / 16)
  local edge = dx > 0 and math.floor((nx + radius) / 16)
               or math.floor((nx - radius) / 16)
  local hit = nil
  for zc = z0, z1 do
    hit = blocked(edge, zc)
    if hit then break end
  end
  if hit then
    if dx > 0 then nx = math.min(nx, edge * 16 - radius - C.EPS)
    else nx = math.max(nx, (edge + 1) * 16 + radius + C.EPS) end
  end
  return nx, hit
end

function C.slideZ(x, z, dz, radius, blocked)
  if dz == 0 then return z, nil end
  radius = radius or C.RADIUS
  local nz = z + dz
  local x0 = math.floor((x - radius + C.EPS) / 16)
  local x1 = math.floor((x + radius - C.EPS) / 16)
  local edge = dz > 0 and math.floor((nz + radius) / 16)
               or math.floor((nz - radius) / 16)
  local hit = nil
  for xc = x0, x1 do
    hit = blocked(xc, edge)
    if hit then break end
  end
  if hit then
    if dz > 0 then nz = math.min(nz, edge * 16 - radius - C.EPS)
    else nz = math.max(nz, (edge + 1) * 16 + radius + C.EPS) end
  end
  return nz, hit
end

-- 16 px per cell over the engine's own frames-per-cell: the px-per-frame the
-- grid walk itself covers. Whatever folds the bicycle, Cycling Road slope or a
-- movement.speed hook into that frame count carries through untouched.
function C.pace(framesPerCell)
  local frames = tonumber(framesPerCell)
  if not frames or frames < 1 then frames = 16 end
  return 16 / frames
end

-- The walk-cycle (leg) cadence on a diagonal. A diagonal covers the same
-- ground per frame as a cardinal, but the sprite sheet has no diagonal frames,
-- so legs cycling at the full rate read as faster than the body is moving. The
-- cadence is scaled toward ANIM_DIAGONAL by how diagonal the heading is: 1.0 on
-- a cardinal, ANIM_DIAGONAL on a true 45, blended smoothly between so a stick
-- drifting off an axis never jolts the legs. Speed is untouched.
C.ANIM_DIAGONAL = 0.8
function C.animRate(hx, hz)
  local ax, az = math.abs(hx or 0), math.abs(hz or 0)
  local sum = ax + az
  if sum < 1e-9 then return 1 end
  local diag = 2 * math.min(ax, az) / sum          -- 0 cardinal .. 1 true 45
  return 1 - (1 - C.ANIM_DIAGONAL) * diag
end

-- ------- the stepper: a heading as a STREAM of cardinal steps
--
-- Gen 2 and Gen 3 both lock input for the whole of a native step, so the arms
-- there do not drive a pixel body -- they choose which cardinal the engine
-- should step next and let the untouched native step machine do the rest
-- (collision, encounters, warps, ledges, the bike and running-shoes pace, the
-- animation). A single heading cannot be one cardinal, so this turns it into
-- the right MIX over successive steps: a digital differential analyser. For a
-- 45-degree hold it alternates perfectly; for a 2-to-1 heading it spends two
-- steps on the long axis for every one on the short. The result tracks the
-- true heading at tile granularity. Deflection never enters -- the heading is
-- already a unit vector -- so the pace stays exactly the engine's own.
--
-- :choose is called once per step actually taken (callers gate it on the
-- player being idle), so the accumulator advances in step with the world and
-- does not drift while a step animates.
function C.newStepper()
  local ax, az = 0, 0
  return {
    reset = function() ax, az = 0, 0 end,
    choose = function(hx, hz)
      if not hx or (hx == 0 and hz == 0) then ax, az = 0, 0; return nil end
      -- L1-normalise the increments so they sum to exactly 1 each step; the
      -- long-run share of each axis is then |hx| : |hz|, and the accumulators
      -- stay bounded (summing the raw unit components, which total >1 on a
      -- diagonal, would let them drift and skew the ratio).
      local s = math.abs(hx) + math.abs(hz)
      ax = ax + math.abs(hx) / s
      az = az + math.abs(hz) / s
      local dir
      if ax >= az then
        dir = hx > 0 and "right" or "left"
        ax = ax - 1
      else
        dir = hz > 0 and "down" or "up"
        az = az - 1
      end
      return dir
    end,
  }
end

return C
