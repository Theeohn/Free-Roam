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
--   ON FOOT (walk, running shoes): a CONTINUOUS body, like the Gen 1 and Gen 2
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
--   ledges, stairs, warps, connections, boulder pushes and every other special
--   tryMove outcome drop the body and the native step takes over.
--
--   BICYCLE, SURF, UNDERWATER and mid-hop: the RSE bike is a per-frame d-pad
--   state machine (Mach speed-up and slow-down, Acro button history), and
--   surf/dive steps carry their own state, so these keep the engine's native
--   step and steer its DIRECTION. update asserts the heading's dominant
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

  local stepper = C.newStepper()
  local pendingHeading = nil      -- staircase path only: set around one update
  local body = nil                -- the one continuous foot body

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
      if ent then return nil end
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

  -- a firm push into a wall: ask native once so its own verbs (ledge hop,
  -- connection, boulder push, the collision sound) answer. A plain bump keeps
  -- the engine's sound but must not lock the body in its bump animation.
  local function pushWall(game, b, dir, run, input)
    local dx = (dir == "right" and 1) or (dir == "left" and -1) or 0
    local dz = (dir == "down" and 1) or (dir == "up" and -1) or 0
    if not blockedCell(game, Player.cellX + dx, Player.cellY + dz) then return false end
    b.cooldown = PUSH_COOLDOWN
    local kind, result = attempt(game, dir, run, input)
    if kind == nil then
      if Player.action and type(Player.cancelAction) == "function" then
        Player.cancelAction()
      end
      return false
    end
    dropBody(false)       -- native took it (special, or admitted what we refused)
    return true, result
  end

  -- one free frame of motion for a synced, idle body
  local function moveBody(game, input, b, hx, hz)
    local run = wantsRun(input)
    local frames = framesFor(run, game, C.cardinal(hx, hz), input)
    local pace = C.pace(frames)
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
        pushWall(game, b, dir, run, input)
      end
    end
  end

  -- ---- the foot frame ------------------------------------------------------

  local function footMode()
    return not (Player.biking or Player.surfing or Player.underwater
      or Player.surfHopping or Player.dismounting or Player.jumping)
  end

  local function footFrame(game, input, hx, hz)
    local polled = false
    local function onPoll() polled = true end
    local feed
    if hx then feed = blankDirs(input, onPoll) else feed = spyDirs(input, onPoll) end
    local result = innerUpdate(game, feed)

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
  local OwSprites = optional("src.core.game3.ow_sprites")
  if OwSprites and type(OwSprites.draw) == "function" and not OwSprites.freeRoamDrawHook then
    local innerOw = OwSprites.draw
    OwSprites.draw = function(graphicsId, px, py, ...)
      local L = V.layer
      if L and body and type(L.capture) == "function"
         and px == Player.px and py == Player.py then
        local args = { n = select("#", ...), ... }
        return L.capture(function()
          return innerOw(graphicsId, px, py, unpack(args, 1, args.n))
        end)
      end
      return innerOw(graphicsId, px, py, ...)
    end
    OwSprites.freeRoamDrawHook = true
  end

  Player.freeRoamHook = true

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
