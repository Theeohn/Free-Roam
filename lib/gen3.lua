-- FREE ROAM / Gen 3 arm (Ruby / Sapphire / Emerald / FireRed / LeafGreen).
--
-- FireRed's player is src.core.game3.player. Its per-frame entry is
-- Player.update(game, input): Player.tick finalises any step in flight (and
-- finishStep fires every arrival: grass, step events, warps, encounters, the
-- save position), then a long gate list runs (menus, scripts, warps, trainer
-- sight), and only then does it read one cardinal from the pad and call
-- Player.tryMove(dir, game, run, input) -- the authentic single cell step.
--
-- Two paths, chosen each frame:
--
--   ON FOOT AND ON THE WATER (walk, running shoes, surf, dive): a CONTINUOUS
--   body, like the Gen 1 and Gen 2
--   arms. Native update runs with the d-pad blanked, so every gate still runs
--   and nothing starts a step by itself; if native reached the pad read, the
--   frame is ours. The heading times the engine's own pace (16 px over
--   ordinaryStepFrames, so the walk, the running shoes and any movement.speed
--   mod are the engine's numbers, never restated) moves the body, slid one axis
--   at a time against Collision.canEnter. The body's centre crossing a cell
--   boundary starts a REAL native one-cell step (tryMove) and primes it to land
--   on the next tick, so finishStep does every bit of the landing work. The
--   sprite's px/py are the body's, rounded to whole pixels.
--
--   Anything that is not a plain ordinary step is left to the engine whole:
--   ledges, stairs, warps, boulder pushes, forced tiles (ice, currents,
--   spinners, slides), the hop off the surf blob and every other special
--   tryMove outcome drop the body and the native step takes over -- lined up
--   with the cell first, and started where the body already stood. A map
--   connection keeps the body's sideways offset through the engine's seam
--   step (see applySeam).
--
--   BICYCLE and mid-hop: the RSE bike is a per-frame d-pad state machine
--   (Mach speed-up and slow-down, Acro button history), so it keeps the
--   engine's native step and steers its DIRECTION. update asserts the heading's dominant
--   cardinal; tryMove swaps in a digital-differential stepper's cardinal so a
--   heading becomes an even staircase. The bicycle's speed is the engine's own.
--
-- Fails safe: no heading, a disabled option or any surprise, and native update
-- runs with the real pad and the grid walk is back.
--
-- NOTE: built against the real native contract and unit-tested at the seam;
-- not yet played on a real ROM in the build environment.

local V = ...
local unpack = table.unpack or unpack
local C = V.core

local DIRS = { up = true, down = true, left = true, right = true }

local RADIUS = C.RADIUS
local CELL = 16
local PUSH_COOLDOWN = 24     -- frames between asks of native tryMove at a wall
local PUSH_COMPONENT = 0.5   -- a push is firm when the heading leans on the wall

local M = {}

local function optional(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

function M.install()
  local Player = require("src.core.game3.player")
  if Player.freeRoamHook then return end

  local innerUpdate = Player.update
  local innerTry = Player.tryMove
  if type(innerUpdate) ~= "function" or type(innerTry) ~= "function" then return end

  local Collision = optional("src.core.game3.collision")
  local MapMod = optional("src.core.game3.map")
  local ForcedMovement = optional("src.core.game3.forced_movement")

  local stepper = C.newStepper()
  local pendingHeading = nil      -- staircase path only: set around one update
  local body = nil                -- the one continuous foot body
  local seam = nil                -- a map-connection step the body rides

  local function enabled()
    return V.option("enabled", true) ~= false
  end

  local function headingOf(input)
    return C.heading(input, {
      analog = V.option("analog", true) ~= false,
      diagonals = V.option("diagonals", true) ~= false,
      facing = Player.facing,
    })
  end

  local function currentMap()
    return MapMod and MapMod.current or nil
  end

  -- ---- direction proxies ---------------------------------------------------

  -- a pad that answers true for exactly one direction and defers everything
  -- else to the real input (A/B/run/bike/Start reads pass straight through)
  local function assertDir(input, dir)
    local proxy = setmetatable({}, { __index = input })
    for _, method in ipairs({ "isDown", "wasPressed" }) do
      local real = input[method]
      if real then
        proxy[method] = function(_, key)
          if DIRS[key] then return key == dir end
          return real(input, key)
        end
      end
    end
    return proxy
  end

  -- a pad with every direction off; onPoll fires when native asks about one,
  -- which is how a frame learns that native got past all its gates
  local function blankDirs(input, onPoll)
    local proxy = setmetatable({}, { __index = input })
    for _, method in ipairs({ "isDown", "wasPressed" }) do
      local real = input[method]
      if real then
        proxy[method] = function(_, key)
          if DIRS[key] then
            if onPoll then onPoll() end
            return false
          end
          return real(input, key)
        end
      end
    end
    return proxy
  end

  -- the real pad, unchanged, that reports when native asks about a direction
  local function spyDirs(input, onPoll)
    local proxy = setmetatable({}, { __index = input })
    for _, method in ipairs({ "isDown", "wasPressed" }) do
      local real = input[method]
      if real then
        proxy[method] = function(_, key)
          if DIRS[key] and onPoll then onPoll() end
          return real(input, key)
        end
      end
    end
    return proxy
  end

  -- the free walk drives this frame: the smooth scroll may split the world
  -- pass around the player's sprite
  local function markDriven()
    V.layerSerial = (V.layerSerial or 0) + 1
  end

  -- ---- the foot body -------------------------------------------------------

  local function setSubpixel(x, y)
    if V.subpixel then V.subpixel.x, V.subpixel.y = x, y end
  end

  -- whole pixels to the engine (crisp tiles, the camera's own floor); the
  -- fraction the rounding drops goes to the smooth scroll (lib/smoothscroll)
  local function write(b)
    Player.px = math.floor(b.x - 8 + 0.5)
    Player.py = math.floor(b.z - 8 + 0.5)
    b.lastPx, b.lastPy = Player.px, Player.py
    setSubpixel((b.x - 8) - Player.px, (b.z - 8) - Player.py)
  end

  -- release the body. With snap, an idle player standing off-grid is put back
  -- on its cell's origin so a native step starts from where it expects to.
  local function dropBody(snap)
    local b = body
    body = nil
    setSubpixel(0, 0)
    if b and snap and not Player.moving
       and Player.px == b.lastPx and Player.py == b.lastPy then
      Player.px, Player.py = Player.cellX * CELL, Player.cellY * CELL
    end
  end

  -- Reconcile the body with whatever native did this frame. Returns the body,
  -- or nil when the player is mid-step in a way the body does not own.
  local function sync()
    local map = currentMap()
    local b = body
    if b and b.map ~= map then dropBody(false); b = nil end
    if b and b.pending then
      if Player.moving then return nil end            -- not landed yet
      local q = b.pending
      b.pending = nil
      if Player.cellX ~= q.x or Player.cellY ~= q.y
         or Player.px ~= Player.cellX * CELL or Player.py ~= Player.cellY * CELL then
        dropBody(false); b = nil                       -- something else moved us
      else
        write(b)                                       -- native landed: resume
      end
    elseif b and (Player.px ~= b.lastPx or Player.py ~= b.lastPy) then
      dropBody(false); b = nil                         -- warp, script, teleport
    end
    if not b then
      if Player.moving then return nil end
      b = { map = map, x = Player.px + 8, z = Player.py + 8,
        lastPx = Player.px, lastPy = Player.py, clock = 0, cooldown = 0 }
      body = b
    end
    return b
  end

  -- A cell the engine would let the player into but must move them through
  -- itself, on its own grid: ice, currents, spinners, slides, waterfalls,
  -- muddy slopes and cracked floors ("forced"), and dry land seen from the
  -- water ("dismount": the hop off the surf blob). The free body treats them
  -- as a wall; a firm push hands the step to the engine.
  local function specialCell(cx, cy)
    if ForcedMovement and type(ForcedMovement.isForcedMovementTile) == "function"
       and type(Collision.behavior) == "function" then
      local okB, beh = pcall(Collision.behavior, cx, cy)
      if okB and beh ~= nil then
        local okF, forced = pcall(ForcedMovement.isForcedMovementTile, beh)
        if okF and forced then return "forced" end
      end
    end
    if Player.surfing and not Player.underwater
       and type(Collision.isSurfDismount) == "function" then
      local ok, d = pcall(Collision.isSurfDismount, cx, cy, Player.currentElevation)
      if ok and d then return "dismount" end
    end
    return nil
  end

  -- can the engine let the body into cell (cx, cy)? nil = yes, else the reason.
  -- A diagonal cell must be reachable by both of its cardinal approaches, so a
  -- blocked corner is never cut and one-way tiles are respected.
  local function blockedCell(game, cx, cy)
    if not Collision or type(Collision.canEnter) ~= "function" then return "tile" end
    local fx, fy = Player.cellX, Player.cellY
    if cx == fx and cy == fy then return nil end
    local function hop(ax, ay, bx, by)
      local dir = (bx > ax and "right") or (bx < ax and "left")
        or (by > ay and "down") or "up"
      local ok, ent, why = pcall(Collision.canEnter, game, bx, by, {
        fromX = ax, fromY = ay, dir = dir,
        surfing = Player.surfing or Player.underwater,
        elevation = Player.currentElevation,
      })
      if not ok then return "tile" end
      if ent then return specialCell(bx, by) end
      return why or "tile"
    end
    if cx ~= fx and cy ~= fy then
      return hop(fx, fy, cx, fy) or hop(cx, fy, cx, cy)
        or hop(fx, fy, fx, cy) or hop(fx, cy, cx, cy)
    end
    return hop(fx, fy, cx, cy)
  end

  -- the engine's own frame count for an ordinary step (walk 16, running shoes
  -- 8, then any movement.speed mod hook on top)
  local function framesFor(run, game, dir, input)
    if type(Player.ordinaryStepFrames) == "function" then
      local ok, f = pcall(Player.ordinaryStepFrames, run, game, dir, input)
      if ok and tonumber(f) then return math.max(1, tonumber(f)) end
    end
    return run and 8 or 16
  end

  local function wantsRun(input)
    if not (input and type(input.isDown) == "function" and input:isDown("b")) then
      return false
    end
    if type(Player.canDash) ~= "function" then return false end
    local ok, can = pcall(Player.canDash)
    return ok and can == true
  end

  -- Ask native tryMove for a step in `dir`.
  --   "ordinary"  a plain one-cell step began (the body's to finish)
  --   "special"   a ledge / stairs / warp / connection / push began or fired
  --   nil         refused (wall bump, turn latch, busy): nothing started
  local function attempt(game, dir, run, input)
    -- tryMove turns the player to the step's cardinal. On a diagonal the body
    -- crosses cell lines on alternating axes, so letting that stand would flip
    -- the sprite between its two sides on every crossing. The sprite's facing
    -- is the heading's (sticky, like Gen 1 and 2); it is restored after any
    -- plain step or refusal and left to the engine only for a special move.
    local facing = Player.facing
    Player.facing = dir
    Player.turnArmed = false
    local result = innerTry(dir, game, run, input)
    local ordinary = result == "step" and Player.moving and not Player.jumping
       and not Player.biking and not Player.dismounting
       and math.abs((Player.targetX or 0) - Player.cellX)
         + math.abs((Player.targetY or 0) - Player.cellY) == 1
    if ordinary then
      if not Player.facingLocked then Player.facing = facing end
      return "ordinary", result
    end
    if result and result ~= "blocked" and result ~= "turned" then
      return "special", result
    end
    if not Player.facingLocked then Player.facing = facing end
    return nil, result
  end

  -- a started ordinary step: prime it to land on the next tick, where native's
  -- finishStep does the real landing work, and keep the body's px meanwhile
  local function commit(b, x, z, moved)
    b.x, b.z = x, z
    b.clock = b.clock + moved * b.animRate
    b.moving = true
    b.pending = { x = Player.targetX, y = Player.targetY }
    Player.progress = math.max(0, (Player.stepFrames or 16) - 1)
    write(b)
  end

  -- ---- the seam: a map-connection step keeps the body's line -------------
  --
  -- The engine crosses a map edge by loading the next map and parking the
  -- player one cell before the landing cell, mid-step, on the grid. The body
  -- was off the grid line, so riding that step as-is put the sprite back on
  -- a gridline the moment the route began. The seam keeps the body's
  -- sideways offset on the player for the whole step (and its fraction on
  -- the smooth scroll), starts the step where the body already stood along
  -- it, and rebuilds the body on landing at the same offset.
  local function sideways(dir) return dir == "left" or dir == "right" end

  local function applySeam(game)
    local s = seam
    if not s then return end
    if Player.moving then
      if Player.targetX ~= s.tx or Player.targetY ~= s.ty then seam = nil; return end
      local whole = math.floor(s.perp + 0.5)
      if sideways(s.dir) then
        Player.py = Player.cellY * CELL + whole
        setSubpixel(0, s.perp - whole)
      else
        Player.px = Player.cellX * CELL + whole
        setSubpixel(s.perp - whole, 0)
      end
      markDriven()
      return
    end
    seam = nil
    if Player.cellX ~= s.tx or Player.cellY ~= s.ty then setSubpixel(0, 0); return end
    -- land at the same sideways offset, unless the new map walls that side
    -- in closer than the body's radius allows
    local perp = s.perp
    local limit = CELL / 2 - RADIUS - C.EPS
    if math.abs(perp) > limit then
      local side = perp > 0 and 1 or -1
      local nx, ny = Player.cellX, Player.cellY
      if sideways(s.dir) then ny = ny + side else nx = nx + side end
      if blockedCell(game, nx, ny) then perp = side * limit end
    end
    local x, z = Player.cellX * CELL + 8, Player.cellY * CELL + 8
    if sideways(s.dir) then z = z + perp else x = x + perp end
    body = { map = currentMap(), x = x, z = z, clock = 0, cooldown = 0 }
    write(body)
    markDriven()
  end

  -- A firm push into a wall: ask native once so its own verbs (ledge hop,
  -- connection, boulder push, forced tiles, the hop off the surf blob, the
  -- collision sound) answer. A move the engine carries on its own grid first
  -- lines the body up with the cell (a glide, never a jump), and the engine's
  -- step then starts where the body already stands along it.
  local LINE_UP_SIDEWAYS = 0.38   -- a heading this far off the push only slides

  local function pushWall(game, b, dir, run, input, pace, hx, hz, sideBlocked)
    local dx = (dir == "right" and 1) or (dir == "left" and -1) or 0
    local dz = (dir == "down" and 1) or (dir == "up" and -1) or 0
    local why = blockedCell(game, Player.cellX + dx, Player.cellY + dz)
    if not why then return false end
    local ledge = false
    if why ~= "forced" and why ~= "dismount" and type(Collision.ledgeLanding) == "function" then
      local ok, lx = pcall(Collision.ledgeLanding, game, Player.cellX, Player.cellY, dir)
      ledge = ok and lx ~= nil
    end
    local cx, cz = Player.cellX * CELL + 8, Player.cellY * CELL + 8
    if why == "forced" or why == "dismount" or ledge then
      -- a heading that runs along the edge slides along it; only a push
      -- (nearly) straight in, or into a corner, takes the engine's move
      local side = math.abs((dx ~= 0) and (hz or 0) or (hx or 0))
      if side > LINE_UP_SIDEWAYS and not sideBlocked then return false end
      local off = (dx ~= 0) and (cz - b.z) or (cx - b.x)
      local step = math.min(math.abs(off), pace or 1)
      if dx ~= 0 then b.z = b.z + (off > 0 and step or -step)
      else b.x = b.x + (off > 0 and step or -step) end
      if step > 0 then
        b.moving = true
        b.clock = b.clock + step * (b.animRate or 1)
        write(b)
      end
      if math.abs(off) - step > 0.05 then return false end
      if dx ~= 0 then b.z = cz else b.x = cx end
    end
    local along = (dx ~= 0) and (b.x - cx) * dx or (b.z - cz) * dz
    local perp = (dx ~= 0) and (b.z - cz) or (b.x - cx)
    b.cooldown = PUSH_COOLDOWN
    local kind, result = attempt(game, dir, run, input)
    if kind == nil then
      if Player.action and type(Player.cancelAction) == "function" then
        Player.cancelAction()
      end
      return false
    end
    dropBody(false)       -- native took it (special, or admitted what we refused)
    if Player.moving then
      -- start the engine's step (or hop) where the body already stood along
      -- it, so it never steps back to the cell's edge first
      local frames = Player.stepFrames or 16
      local span = math.max(1, math.abs((Player.targetX or Player.cellX) - Player.cellX),
        math.abs((Player.targetY or Player.cellY) - Player.cellY))
      if along > 0 then
        Player.progress = math.max(0, math.min(frames - 1,
          math.floor(along * frames / (CELL * span))))
        -- and draw it there this frame too (the engine's own interpolation)
        local adv = math.floor(Player.progress * CELL * span / frames)
        local sx = ((Player.targetX or Player.cellX) - Player.cellX) / span
        local sy = ((Player.targetY or Player.cellY) - Player.cellY) / span
        Player.px = Player.cellX * CELL + sx * adv
        Player.py = Player.cellY * CELL + sy * adv
      end
      if result == "connection" and not Player.jumping and not Player.dismounting then
        seam = { dir = dir, perp = perp, tx = Player.targetX, ty = Player.targetY }
        applySeam(game)
      end
    end
    return true, result
  end

  -- one free frame of motion for a synced, idle body
  local function moveBody(game, input, b, hx, hz)
    local run = wantsRun(input)
    local frames = framesFor(run, game, C.cardinal(hx, hz), input)
    -- TRUE PACE: walking and the running shoes slow to two thirds; surf and
    -- dive (which this body also drives) never do. The leg clock below runs
    -- on distance, so it slows with the body by itself.
    local foot = C.footFactor(V.option("truePace", false) == true,
      not (Player.surfing or Player.underwater))
    local pace = C.pace(frames) * foot
    b.moving = false
    b.run = run
    b.animRate = C.animRate(hx, hz)
    b.cooldown = math.max(0, (b.cooldown or 0) - 1)

    if not Player.facingLocked then
      Player.facing = C.quantise(hx, hz, Player.facing, C.TIE)
    end

    local function blocked(cx, cy) return blockedCell(game, cx, cy) end
    local dx, dz = hx * pace, hz * pace
    local ox, oz = b.x, b.z

    -- x axis
    local started = false           -- a native step began this frame
    local nx, hitX = C.slideX(b.x, b.z, dx, RADIUS, blocked)
    if foot ~= 1 then nx = C.tidy(nx) end
    if math.floor(nx / CELL) ~= Player.cellX then
      local dir = nx > b.x and "right" or "left"
      local kind = attempt(game, dir, run, input)
      if kind == "special" then
        dropBody(false)
        return
      elseif kind == "ordinary" then
        started = true
      else
        nx = b.x                    -- refused: hold the line
      end
    end
    b.x = nx

    -- z axis, from the x the body now has. One native step per frame: if x
    -- started one, z keeps its motion (under a pixel past its line) and the
    -- next frame's landing lets its own crossing start, so no speed is lost.
    local nz, hitZ = C.slideZ(b.x, b.z, dz, RADIUS, blocked)
    if foot ~= 1 then nz = C.tidy(nz) end
    if math.floor(nz / CELL) ~= Player.cellY then
      if not started then
        local dir = nz > b.z and "down" or "up"
        local kind = attempt(game, dir, run, input)
        if kind == "special" then
          dropBody(false)
          return
        elseif kind == "ordinary" then
          started = true
        else
          nz = b.z
        end
      end
    end
    b.z = nz

    if started then
      commit(b, b.x, b.z, math.sqrt((b.x - ox) ^ 2 + (b.z - oz) ^ 2))
      return
    end

    -- the walk cycle follows the ground actually covered (Euclidean, not the sum
    -- of the two axes, which ran a diagonal's legs 1.41x fast), scaled by the
    -- diagonal cadence rate
    local moved = math.sqrt((b.x - ox) ^ 2 + (b.z - oz) ^ 2)
    b.moving = moved > 1e-6
    if b.moving then b.clock = b.clock + moved * b.animRate end
    write(b)

    -- a firm push: the heading leans on the wall the body is stopped by
    if b.cooldown == 0 then
      local dir, comp
      if hitX and (not hitZ or math.abs(dx) >= math.abs(dz)) then
        dir, comp = dx > 0 and "right" or "left", math.abs(hx)
      elseif hitZ then
        dir, comp = dz > 0 and "down" or "up", math.abs(hz)
      end
      if dir and comp >= PUSH_COMPONENT then
        local sideHit
        if dir == "right" or dir == "left" then sideHit = hitZ else sideHit = hitX end
        pushWall(game, b, dir, run, input, pace, hx, hz, sideHit ~= nil)
      end
    end
  end

  -- ---- the foot frame ------------------------------------------------------

  -- the free body walks, runs, surfs and dives; the bicycle (a per-frame
  -- d-pad state machine) and the hops on and off the surf blob stay native
  local function footMode()
    return not (Player.biking or Player.surfHopping or Player.dismounting
      or Player.jumping)
  end

  local function footFrame(game, input, hx, hz)
    local polled = false
    local function onPoll() polled = true end
    local feed
    if hx then feed = blankDirs(input, onPoll) else feed = spyDirs(input, onPoll) end
    local result = innerUpdate(game, feed)

    -- riding a map-connection step: keep the body's line, nothing else
    if seam then
      applySeam(game)
      return result
    end

    if not hx then
      -- nothing held: native ran the real pad. A body that was landing resumes.
      if body then
        body.moving = false
        if body.pending then sync() end
        if polled and not Player.moving and body then markDriven() end
      end
      return result
    end

    -- native did not reach the pad (menu, script, warp, sight check) or a step
    -- or an action owns the player: the body rests, or yields to a foreign move
    if not polled or Player.moving or Player.action or Player.boulderPush then
      if body then
        body.moving = false
        if Player.moving and not body.pending then dropBody(false) end
      end
      return result
    end

    local b = sync()
    if not b then return result end
    moveBody(game, input, b, hx, hz)
    if body and not Player.moving then markDriven() end
    return result
  end

  -- ---- the staircase path (bicycle, surf, underwater, hops) ---------------

  local function stairFrame(game, input, hx, hz)
    pendingHeading = { hx, hz }
    -- assert the dominant cardinal so dirs_from_input returns non-nil (stick
    -- included) and native reaches tryMove; tryMove swaps in the stepper's dir
    local result = innerUpdate(game, assertDir(input, C.cardinal(hx, hz)))
    pendingHeading = nil   -- consumed; never steer outside this frame
    return result
  end

  -- ---- the seams -----------------------------------------------------------

  Player.update = function(game, input)
    pendingHeading = nil
    if not enabled() or not input or type(input.isDown) ~= "function" then
      if body and not enabled() then dropBody(true) end
      return innerUpdate(game, input)
    end

    local hx, hz = headingOf(input)

    if not footMode() then
      seam = nil
      if body then dropBody(true) end
      setSubpixel(0, 0)
      if not hx then
        stepper.reset()
        return innerUpdate(game, input)
      end
      return stairFrame(game, input, hx, hz)
    end

    stepper.reset()
    return footFrame(game, input, hx, hz)
  end

  Player.tryMove = function(dir, game, run, input)
    local h = pendingHeading
    if h and enabled() and not Player.moving then
      local chosen = stepper.choose(h[1], h[2])
      if chosen then return innerTry(chosen, game, run, input) end
    end
    return innerTry(dir, game, run, input)
  end

  -- ---- the sprite ------------------------------------------------------------
  -- While the body walks natively the player is idle, so native would hold the
  -- standing pose and one foot. Drive both from the distance the body has
  -- travelled: 8 px per pose, the engine's own 8-frame walk cadence at 1 px a
  -- frame, alternating the stepping foot every cell.
  local walkPhase0 = Player.walkPhase
  local drawFlip0 = Player.drawFlip
  local runPose0 = Player.runPose

  local function travelled()
    local b = body
    if b and b.moving then return math.floor(b.clock / 8) end
    return nil
  end

  if type(walkPhase0) == "function" then
    Player.walkPhase = function(...)
      local n = travelled()
      if n and not body.run then return n % 2 end
      return walkPhase0(...)
    end
  end
  if type(drawFlip0) == "function" then
    Player.drawFlip = function(...)
      local n = travelled()
      if n then return n % 4 == 0 or n % 4 == 3 end
      return drawFlip0(...)
    end
  end
  if type(runPose0) == "function" then
    Player.runPose = function(...)
      local n = travelled()
      if n and body.run then return n % 2 end
      return runPose0(...)
    end
  end

  -- The player's sprite draw. FireRed draws actors straight into the world
  -- canvas the smooth scroll shifts; handing the player's own draw to the layer
  -- keeps it fixed on screen while everything before and after it (roofs, tall
  -- grass over the feet, NPCs) stays glued to the scrolling world.
  -- the player's sprite is drawn at its px/py plus the sprite offsets (the
  -- surf bob, a field-move nudge)
  local function isPlayerAt(px, py)
    local xo, yo = Player.spriteXOffset or 0, Player.spriteYOffset or 0
    return (px == Player.px or px == Player.px + xo)
      and (py == Player.py or py == Player.py + yo)
  end

  local OwSprites = optional("src.core.game3.ow_sprites")
  if OwSprites and type(OwSprites.draw) == "function" and not OwSprites.freeRoamDrawHook then
    local innerOw = OwSprites.draw
    OwSprites.draw = function(graphicsId, px, py, ...)
      local L = V.layer
      if L and (body or seam) and type(L.capture) == "function" and isPlayerAt(px, py) then
        local args = { n = select("#", ...), ... }
        return L.capture(function()
          return innerOw(graphicsId, px, py, unpack(args, 1, args.n))
        end)
      end
      return innerOw(graphicsId, px, py, ...)
    end
    OwSprites.freeRoamDrawHook = true
  end
  -- the same for the fallback sprite renderer the field view uses when the
  -- GBA overworld sprites are not ready: the player must be held still on
  -- either path, or the whole frame (player included) slides by the
  -- sub-pixel and the world appears to jitter around a wobbling player
  local SpriteRenderer = optional("src.render.SpriteRenderer")
  if SpriteRenderer and type(SpriteRenderer.draw) == "function"
     and not SpriteRenderer.freeRoamDrawHook then
    local innerSr = SpriteRenderer.draw
    SpriteRenderer.draw = function(self, px, py, ...)
      local L = V.layer
      if L and (body or seam) and type(L.capture) == "function" and isPlayerAt(px, py) then
        local args = { n = select("#", ...), ... }
        return L.capture(function()
          return innerSr(self, px, py, unpack(args, 1, args.n))
        end)
      end
      return innerSr(self, px, py, ...)
    end
    SpriteRenderer.freeRoamDrawHook = true
  end
  -- the surf blob rides under the player: held still with it, or it would
  -- slide under the steady sprite by the sub-pixel every frame
  local FieldEffects = optional("src.core.game3.field_effects")
  if FieldEffects and type(FieldEffects.drawSurfBlob) == "function"
     and not FieldEffects.freeRoamBlobHook then
    local innerBlob = FieldEffects.drawSurfBlob
    FieldEffects.drawSurfBlob = function(...)
      local L = V.layer
      if L and (body or seam) and type(L.capture) == "function" then
        local args = { n = select("#", ...), ... }
        return L.capture(function() return innerBlob(unpack(args, 1, args.n)) end)
      end
      return innerBlob(...)
    end
    FieldEffects.freeRoamBlobHook = true
  end

  Player.freeRoamHook = true

  -- TRUE PACE for the party follower (a follower mod's companion): it walks
  -- each cell over Player.stepFrames, read as the step starts, so hand it the
  -- slowed one for its own update. Its walk frame is just moving / still, so
  -- nothing else needs slowing. Only while the free walk is on and the player
  -- is on foot (not the bicycle, surf or dive), exactly when the player is.
  local GenFollower = optional("src.world.game3.Follower")
  if GenFollower and type(GenFollower.update) == "function"
     and not GenFollower.freeRoamPaceHook then
    GenFollower.update = C.paceFollowerUpdate(GenFollower.update,
      { "stepFrames" },
      function()
        return enabled() and not Player.biking
          and C.footFactor(V.option("truePace", false) == true,
            not (Player.surfing or Player.underwater)) ~= 1
      end,
      function() return Player end)
    GenFollower.freeRoamPaceHook = true
  end

  M.active = function() return enabled() end
  M.position = function()
    if body then return body.x, body.z end
    if type(Player.cellX) == "number" and type(Player.cellY) == "number" then
      return Player.cellX * CELL + 8, Player.cellY * CELL + 8
    end
    return nil
  end
  M._internal = {
    stepper = stepper,
    assertDir = assertDir,
    blankDirs = blankDirs,
    headingOf = headingOf,
    blockedCell = blockedCell,
    body = function() return body end,
  }
end

M.active = function() return false end
M.position = function() return nil end

return M
