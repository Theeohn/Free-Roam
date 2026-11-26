-- FREE ROAM / Gen 2 arm (Gold / Silver / Crystal).
--
-- Gen 2's overworld is src.world.gen2.World. Its native loop, per frame, is:
--   World:pollInput(input)  sets self.heldDir from the d-pad only
--   World:stepBody()        when idle and heldDir is set, calls
--                           self:movePlayer(dir): one grid step, 16 frames,
--                           chained back-to-back while the d-pad is held.
--
-- That grid step is the reason the earlier arm did nothing useful on Gold: it
-- could only ever choose a cardinal per step, so a diagonal became a staircase
-- and the player stayed tied to the grid. This arm does what the Gen 1 arm does
-- and what Gold/Silver's own voxel free camera does: it moves the body
-- CONTINUOUSLY, once per frame, and never calls the grid step while free.
--
-- How a free frame runs (World:stepBody, after the native body):
--   * the heading (a unit vector from the stick, or the keys, normalised) is
--     multiplied by the engine's own pace: 16 px per cell over the frames the
--     native walk would take, so a walk is 1 px/frame and a bicycle is 2 px/frame
--     (Bike.stepFrames). Deflection never changes speed.
--   * the body is a circle slid one axis at a time against the engine's own cell
--     verdicts (bounds, walkability, the side-wall permission veto, NPCs and
--     entities), so walls stop the blocked axis and the free one keeps going.
--   * the body's cell is kept current, and each cell crossing runs the engine's
--     own landing pipeline (grass, trainer sight, step events, warps, coord
--     scripts, step counting, wild encounters), exactly once per cell.
--   * the sprite is driven from the same position: facing from the heading,
--     the walk leg from the distance travelled, and p.px/p.py rounded to whole
--     pixels so the tiles stay crisp.
--
-- Hand-offs to native, so nothing the engine owns is re-implemented:
--   * scripts, menus, text, field moves, fishing, headbutt, the map-setup chain
--     and the Cycling Road downhill all keep the native loop (free defers).
--   * Surfing is free like walking (the water's own permissions, the surf
--     step's own pace, stepping onto land ends it as the cart does). Forced
--     tiles (ice, currents, whirlpools, forced doors) stay native: the body
--     treats them as a wall, and a firm push lines it up and hands the step
--     to the engine, whose own permission and forced-direction logic owns
--     those cells.
--   * a blocked push into a ledge, a map edge (connection) or a boulder asks the
--     engine's own handler once (tryLedgeJump / tryConnection / tryPushBoulder).
--     If it took the push, free motion pauses briefly while the engine animates
--     the jump, connection or push, then resumes.
--
-- Fails safe: any surprise (a missing method, an error) defers to the native
-- step with its own direction, so the worst case is the stock grid walk.

local V = ...
local C = V.core

local M = {}

local RADIUS = C.RADIUS
local unpackResults = (table and table.unpack) or unpack
local WALK_FRAMES = 16
local PAUSE_FRAMES = 24     -- free motion rests while the engine animates a push

local function optional(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local function callOr(world, name, fallback, ...)
  local f = world[name]
  if type(f) ~= "function" then return fallback end
  local ok, out = pcall(f, world, ...)
  if not ok then return fallback end
  return out
end

local function busy(world)
  -- an error here means the engine's state is unclear: defer to native
  if type(world.busy) ~= "function" then return true end
  local ok, b = pcall(world.busy, world)
  return (not ok) or b == true
end

-- Gold/Silver's live game is the instance World belongs to. Free motion owns
-- the overworld only when that game's screen stack is empty (no text, menu or
-- battle on top) and this World is the one on screen.
local function driving(world)
  local game = world.game
  if not game or game.world ~= world then return false end
  local stack = game.stack
  local top = stack and type(stack.top) == "function" and stack:top() or nil
  return top == nil
end

function M.install()
  local World = optional("src.world.gen2.World")
  if not World then return end
  if World.freeRoamHook then return end
  if type(World.pollInput) ~= "function" or type(World.stepBody) ~= "function" then
    return
  end

  local innerPoll = World.pollInput
  local innerStep = World.stepBody

  local Permissions = optional("src.world.gen2.Permissions")
  local FieldMoves = optional("src.world.gen2.FieldMoves")
  local Bike = optional("src.world.gen2.Bike")
  local Player = optional("src.world.gen2.Player")
  local Runtime = optional("src.mods.Runtime")
  if Player and tonumber(Player.STEP_FRAMES) then
    WALK_FRAMES = tonumber(Player.STEP_FRAMES)
  end

  local function optionOn()
    return V.option("enabled", true) ~= false
  end

  -- ---- eligibility -------------------------------------------------------

  local function surfing(world)
    return FieldMoves and type(FieldMoves.isSurfing) == "function"
      and FieldMoves.isSurfing(world.playerState) or false
  end

  -- The cell's own direction rules belong to the engine. Returns true when
  -- the current cell forces a direction (current, door, ice, whirlpool).
  local function forcedHere(world)
    if not Permissions then return false end
    local coll = callOr(world, "playerCollision", nil)
    if coll == nil then return false end
    local function test(name)
      local f = Permissions[name]
      if type(f) ~= "function" then return false end
      local ok, out = pcall(f, coll)
      return ok and out and true or false
    end
    return test("currentDirection") or test("doorForcedDirection")
      or test("isIce") or test("isWhirlpool")
  end

  -- the same rules for any cell (the body's next one)
  local function forcedAt(world, cx, cy)
    if not Permissions or not world.map then return false end
    local ok, coll = pcall(world.map.cellCollision, world.map, cx, cy)
    if not ok or coll == nil then return false end
    for _, name in ipairs({ "currentDirection", "isIce", "isWhirlpool" }) do
      local f = Permissions[name]
      if type(f) == "function" then
        local okT, out = pcall(f, coll)
        if okT and out then return true end
      end
    end
    return false
  end

  -- Everything that must stay native, checked without moving anything.
  local function freeAllowed(world)
    if not optionOn() then return false end
    if not (world.map and world.player) then return false end
    if not driving(world) then return false end
    if busy(world) then return false end
    if world.mapSetup or world.moveState or world.fieldMove
       or world.fishing or world.headbutt then
      return false
    end
    if callOr(world, "downhill", false) then return false end
    if forcedHere(world) then return false end
    return true
  end

  -- ---- speed -------------------------------------------------------------

  -- frames per cell for this step, exactly as the native walk would take it:
  -- walk 16, bicycle 8, then any movement.speed mod hook on top.
  local function framesPerCell(world)
    local p = world.player
    local frames = WALK_FRAMES
    if Bike and type(Bike.stepFrames) == "function" then
      local ok, f = pcall(Bike.stepFrames, world.playerState, p.facing,
        false, WALK_FRAMES)
      if ok and tonumber(f) then frames = tonumber(f) end
    end
    if Runtime and type(Runtime.wantsHook) == "function"
       and Runtime.wantsHook("movement.speed") and type(Runtime.call) == "function" then
      local game = world.game
      local ok, out = pcall(Runtime.call, "movement.speed",
        function(v) return v end, frames, {
          onBike = FieldMoves and FieldMoves.isBiking
            and FieldMoves.isBiking(world.playerState) or false,
          surfing = surfing(world),
          downhill = false,
          playerState = world.playerState,
          player = p,
          input = game and game.input,
          save = game and game.save,
        })
      if ok and tonumber(out) then frames = math.max(1, math.floor(tonumber(out))) end
    end
    return frames
  end

  -- ---- body --------------------------------------------------------------

  -- The body's position is ours while free; the engine's player px/py are
  -- rewritten from it each frame. If the engine moved the player some other
  -- way (a warp, a script, a map change), adopt its position instead.
  local function adopt(world)
    local p = world.player
    local mapId = world.map and world.map.id
    local stale = world._frX == nil or world._frMap ~= mapId
      or p.px ~= world._frPx or p.py ~= world._frPy
    if stale then
      world._frX = (tonumber(p.px) or (p.cellX or 0) * 16) + 8
      world._frZ = (tonumber(p.py) or (p.cellY or 0) * 16) + 8
      world._frMap = mapId
      world._frPx, world._frPy = p.px, p.py
      world._frTrueX, world._frTrueY = nil, nil    -- no sub-pixel until it moves
    end
  end

  local function ensureWalkPhase(p)
    if p._frWalkPhase then return end
    p._frWalkPhase = true
    local engine = p.walkPhase
    p.walkPhase = function(self, ...)
      -- the engine's step phase reads Player.moving, which free motion never
      -- sets, so while free moves drive the leg from their own distance
      if self._frMoved then
        local t = (self.animClock or 0) % WALK_FRAMES
        return (t >= WALK_FRAMES / 4 and t < WALK_FRAMES * 3 / 4) and 1 or 0
      end
      if type(engine) == "function" then return engine(self, ...) end
      return 0
    end
  end

  -- the same landing pipeline the engine runs when a step lands
  local function landingEvents(world, p)
    if type(world.grassAt) == "function" then
      p.inGrass = callOr(world, "grassAt", nil, p.cellX, p.cellY)
      p.grassShake = p.inGrass or nil
    end
    if callOr(world, "checkTrainerBattle", false) then return true end
    if Runtime and type(Runtime.wants) == "function"
       and Runtime.wants("world.stepped") and world.map then
      Runtime.emit("world.stepped", { mapId = world.map.id,
        x = p.cellX, y = p.cellY,
        tile = world.map:cellCollision(p.cellX, p.cellY),
        tod = world.tod, daytime = world.daytime })
    end
    if type(world.clearWarpCooldownIfLeft) == "function" then
      pcall(world.clearWarpCooldownIfLeft, world)
    end
    if callOr(world, "checkWarpOnArrive", false) then return true end
    if not world.map then return true end
    if callOr(world, "tryCoordScript", false) then return true end
    if callOr(world, "countStep", false) then return true end
    if callOr(world, "tryWildEncounter", false) then return true end
    return false
  end

  -- can the engine's cell verdict let the body into (cx, cy)? nil = yes,
  -- otherwise the reason it refused
  local function cellVerdict(world, p, cx, cy, dir)
    local map = world.map
    if not map:inBounds(cx, cy) then return "bounds" end
    local walkable
    if surfing(world) then
      -- .CheckSurfPerms: water, or dry land to step out onto
      local okS, kind = pcall(function()
        return Permissions and Permissions.surfable(map:cellCollision(cx, cy))
      end)
      walkable = okS and kind ~= nil
    else
      walkable = map:isWalkable(cx, cy)
    end
    local permitted = true
    if walkable and dir and Permissions and type(Permissions.stepPermitted) == "function" then
      local ok, allowed = pcall(Permissions.stepPermitted,
        function(x, y)
          if type(world.cellCollisionAcross) == "function" then
            return world:cellCollisionAcross(map, x, y)
          end
          return map:cellCollision(x, y)
        end, p.cellX, p.cellY, dir)
      permitted = (not ok) or allowed ~= false
    end
    if not (walkable and permitted) then return "tile" end
    if forcedAt(world, cx, cy) then return "forced" end
    -- NPCs and entities block as a wall; the body is not a sprite
    local npc = callOr(world, "npcAt", nil, cx, cy)
    if npc and npc ~= p and not npc.passable then return "entity" end
    for _, e in ipairs(world.entities or {}) do
      if e ~= p and not e.passable
         and ((e.cellX == cx and e.cellY == cy)
           or (e.moving and e.targetX == cx and e.targetY == cy)) then
        return "entity"
      end
    end
    return nil
  end

  -- the movement.collision chain sees the boolean; a wrapper that flips it
  -- rewrites ctx.reason to say why -- the same shape Gen2's own Player:tryMove
  -- builds for a grid step (src/world/gen2/Player.lua), built here for one
  -- cell of the free walk's own sliding check. A mod that hooks that chain (a
  -- walk-through-walls cheat, a rule that adds a block) governs the free walk
  -- the same way it already governs the grid walk.
  local function passthrough(allowed) return allowed end

  local function blockedCell(world, p, cx, cy)
    if cx == p.cellX and cy == p.cellY then return nil end
    local dx, dy = cx - p.cellX, cy - p.cellY
    local dir = (dx == 1 and "right") or (dx == -1 and "left")
      or (dy == 1 and "down") or (dy == -1 and "up") or nil
    local why = cellVerdict(world, p, cx, cy, dir)
    if not (Runtime and type(Runtime.wantsHook) == "function"
       and Runtime.wantsHook("movement.collision") and type(Runtime.call) == "function") then
      return why
    end
    local ctx = { map = world.map, mover = p, dir = dir,
                  fromX = p.cellX, fromY = p.cellY, toX = cx, toY = cy,
                  reason = why }
    local ok, allowed = pcall(Runtime.call, "movement.collision", passthrough, why == nil, ctx)
    if not ok then return why end
    if allowed then return nil end
    return ctx.reason or why
  end

  -- start the engine's step (already begun) where the body stood along it,
  -- and draw it there this frame
  local function startAt(p, along)
    if not (p.moving and along and along > 0) then return end
    local frames = p.stepFrames or WALK_FRAMES
    local dx = (p.targetX or p.cellX) - p.cellX
    local dy = (p.targetY or p.cellY) - p.cellY
    local span = math.max(math.abs(dx), math.abs(dy), 1)
    p.progress = math.max(0, math.min(frames - 1, math.floor(along * frames / (16 * span))))
    local adv = math.floor(p.progress * 16 * span / frames)
    p.px = p.cellX * 16 + (dx / span) * adv
    p.py = p.cellY * 16 + (dy / span) * adv
  end

  local function sideways(dir) return dir == "left" or dir == "right" end

  -- The seam: the engine crosses a map edge by loading the next map and
  -- parking the player one cell before the landing cell, mid-step, on the
  -- grid line. The body's sideways offset rides that step and the body is
  -- rebuilt at the same offset when it lands, so leaving a town for a route
  -- never snaps the player onto a gridline.
  local function applySeam(world)
    local s = world._frSeam
    local p = world.player
    if not (s and p) then return end
    if p.moving then
      if p.targetX ~= s.tx or p.targetY ~= s.ty then world._frSeam = nil; return end
      local whole = math.floor(s.perp + 0.5)
      if sideways(s.dir) then p.py = p.cellY * 16 + whole
      else p.px = p.cellX * 16 + whole end
      world._frTrueX, world._frTrueY = nil, nil
      return
    end
    world._frSeam = nil
    if p.cellX ~= s.tx or p.cellY ~= s.ty then return end
    local x, z = p.cellX * 16 + 8, p.cellY * 16 + 8
    if sideways(s.dir) then z = z + s.perp else x = x + s.perp end
    world._frX, world._frZ = x, z
    world._frMap = world.map and world.map.id
    local rx, ry = math.floor(x - 8 + 0.5), math.floor(z - 8 + 0.5)
    p.px, p.py = rx, ry
    world._frPx, world._frPy = rx, ry
    world._frTrueX, world._frTrueY = x - 8, z - 8
  end

  local function pause(world)
    world._frPause = PAUSE_FRAMES
    world._frMoved = false
    if world.player then world.player._frMoved = false end
  end

  -- a firm push into a ledge, a map edge or a boulder: hand it to the engine's
  -- own handler once; true means the engine took it
  local function pushSpecial(world, p, dir, why, along, perp)
    if not dir then return false end
    if why == "bounds" and callOr(world, "tryConnection", false, dir) then
      if p.moving and p.targetX then
        startAt(p, along)
        world._frSeam = { dir = dir, perp = perp or 0, tx = p.targetX, ty = p.targetY }
        applySeam(world)
      end
      return true
    end
    if why == "forced" then
      -- the engine's own step onto the forced tile; its ice / current logic
      -- carries the player from there
      p.facing = dir
      p.turnArmed = false
      local result = callOr(world, "movePlayer", nil, dir)
      if result == "moved" and p.moving then
        startAt(p, along)
        return true
      end
      return false
    end
    if why == "tile" and callOr(world, "tryLedgeJump", false, dir) then
      return true
    end
    if why == "entity" and type(world.tryPushBoulder) == "function" then
      local d = ({ up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } })[dir]
      if d and callOr(world, "tryPushBoulder", false, dir,
          p.cellX + d[1], p.cellY + d[2]) then
        return true
      end
    end
    return false
  end

  -- surfing onto dry land ends the surf, the way the cart's .ExitWater does
  -- (GetOutOfWater, then PlayMapMusic swaps the surf theme back)
  local function exitWaterOnto(world, cx, cy)
    if not (surfing(world) and Permissions and type(Permissions.surfable) == "function") then
      return
    end
    local ok, kind = pcall(function()
      return Permissions.surfable(world.map:cellCollision(cx, cy))
    end)
    if not (ok and kind == "land") then return end
    if type(world.applyPlayerState) == "function" and FieldMoves then
      pcall(world.applyPlayerState, world, FieldMoves.PLAYER_NORMAL)
    end
    local data = world.game and world.game.data
    if data and data.audio and data.audio.runtime then
      pcall(function()
        local Music = require("src.core.Music")
        Music.playMap(data, world.map.id, nil, surfing(world), nil,
          type(world.mapMusicSong) == "function" and world:mapMusicSong(world.map.id) or nil)
      end)
    end
  end

  local function crossCell(world, p, cx, cy)
    exitWaterOnto(world, cx, cy)
    p.cellX, p.cellY = cx, cy
    local held = world.heldDir
    world.heldDir = p.facing
    local taken = landingEvents(world, p)
    world.heldDir = held
    return taken
  end

  -- one free frame of motion
  local function tick(world, hx, hy)
    local p = world.player
    adopt(world)
    ensureWalkPhase(p)

    p.facing = C.quantise(hx, hy, p.facing, C.TIE)
    local pace = C.pace(framesPerCell(world))
    local dx, dz = hx * pace, hy * pace
    local ox, oz = world._frX, world._frZ

    local function blocked(cx, cy) return blockedCell(world, p, cx, cy) end
    local nx, hitX = C.slideX(ox, oz, dx, RADIUS, blocked)
    local nz, hitZ = C.slideZ(nx, oz, dz, RADIUS, blocked)
    world._frX, world._frZ = nx, nz

    local mx, mz = nx - ox, nz - oz
    local moved = math.sqrt(mx * mx + mz * mz)
    p._frMoved = moved > 1e-6
    world._frMoved = p._frMoved
    if p._frMoved then
      -- the leg clock and the foot flip share one rate: slower on a diagonal
      -- (see core C.animRate), so the foot still changes once per leg cycle
      local rate = C.animRate(hx, hy)
      world._frAnimAcc = (world._frAnimAcc or 0) + rate
      if world._frAnimAcc >= 1 then
        world._frAnimAcc = world._frAnimAcc - 1
        p.animClock = (p.animClock or 0) + 1
      end
      world._frDist = (world._frDist or 0) + moved * rate
      while world._frDist >= 16 do
        world._frDist = world._frDist - 16
        p.stepFlip = not p.stepFlip
      end
    end

    -- whole pixels to the engine (crisp tiles); the cell is the one under the
    -- body's centre
    local rx = math.floor(nx - 8 + 0.5)
    local ry = math.floor(nz - 8 + 0.5)
    p.px, p.py = rx, ry
    world._frPx, world._frPy = rx, ry
    -- the exact position the whole-pixel write dropped the fraction of; only
    -- World:draw sees it (see the draw seam below)
    world._frTrueX, world._frTrueY = nx - 8, nz - 8

    local cx, cy = math.floor(nx / 16), math.floor(nz / 16)
    if cx ~= p.cellX or cy ~= p.cellY then
      if crossCell(world, p, cx, cy) then
        world._frX = nil          -- the engine took over; re-adopt next frame
        return
      end
    end

    -- a firm push: the body made no real progress into a wall
    local why, dir
    if hitX and (not hitZ or math.abs(dx) >= math.abs(dz)) then
      why, dir = hitX, dx > 0 and "right" or "left"
    elseif hitZ then
      why, dir = hitZ, dz > 0 and "down" or "up"
    end
    if why then
      local sx = (dir == "right" and 1) or (dir == "left" and -1) or 0
      local sy = (dir == "down" and 1) or (dir == "up" and -1) or 0
      local ccx, ccz = p.cellX * 16 + 8, p.cellY * 16 + 8
      if why == "forced" then
        -- along the edge slides; a push (nearly) straight in lines the body
        -- up with the cell (a glide), then hands the step to the engine
        local side = math.abs(sx ~= 0 and hy or hx)
        local sideHit
        if sx ~= 0 then sideHit = hitZ else sideHit = hitX end
        if side > 0.38 and not sideHit then return end
        local off = (sx ~= 0) and (ccz - world._frZ) or (ccx - world._frX)
        local step = math.min(math.abs(off), pace)
        if sx ~= 0 then world._frZ = world._frZ + (off > 0 and step or -step)
        else world._frX = world._frX + (off > 0 and step or -step) end
        local gx, gz = world._frX, world._frZ
        p.px, p.py = math.floor(gx - 8 + 0.5), math.floor(gz - 8 + 0.5)
        world._frPx, world._frPy = p.px, p.py
        world._frTrueX, world._frTrueY = gx - 8, gz - 8
        if math.abs(off) - step > 0.05 then return end
        if sx ~= 0 then world._frZ = ccz else world._frX = ccx end
      end
      p.facing = dir
      local along = (sx ~= 0) and (world._frX - ccx) * sx or (world._frZ - ccz) * sy
      local perp = (sx ~= 0) and (world._frZ - ccz) or (world._frX - ccx)
      if (moved < pace * 0.5 or why == "forced") and pushSpecial(world, p, dir, why, along, perp) then
        if why == "bounds" or why == "forced" then
          world._frX = nil          -- the engine's step now; re-adopt after it
          world._frMoved, p._frMoved = false, false
        else
          pause(world)
        end
      end
    end
  end

  -- The engine's cardinal for a frame that is not free (paused or deferred to
  -- an engine special), so the stick still steers the native step.
  local function nativeFallbackDir(world)
    local h = world._frHeading
    if not h or (world._frPause or 0) > 0 then return nil end
    return C.cardinal(h[1], h[2])
  end

  -- ---- the seams ---------------------------------------------------------

  -- pollInput: the native read stays authoritative for keys; the heading is
  -- stashed for stepBody to decide free versus native
  function World:pollInput(input)
    innerPoll(self, input)
    local hx, hy = nil, nil
    if optionOn() then
      hx, hy = C.heading(input, {
        analog = V.option("analog", true) ~= false,
        diagonals = V.option("diagonals", true) ~= false,
        facing = self.player and self.player.facing,
      })
    end
    self._frHeading = hx and { hx, hy } or nil
  end

  -- stepBody: free motion owns the frame when it is allowed; otherwise the
  -- native loop runs as it always does, with the stick steering its step
  function World:stepBody(...)
    local heading = self._frHeading
    local paused = (self._frPause or 0) > 0
    if paused then self._frPause = self._frPause - 1 end
    local wantFree = heading ~= nil and not paused and freeAllowed(self)

    if wantFree or paused then
      -- the native grid step must never start while the body moves freely, or
      -- while it rests for the engine's own jump/push animation
      self.heldDir = nil
    elseif heading and self.player and not self.player.moving then
      local dir = nativeFallbackDir(self)
      if dir then self.heldDir = dir end
    end

    local out = { innerStep(self, ...) }

    -- riding a map-connection step: keep the body's line, nothing else
    if self._frSeam then
      applySeam(self)
      if self.player then self.player._frMoved = false end
      self._frMoved = false
      return unpackResults(out)
    end

    if wantFree and self.player and not self.player.moving and freeAllowed(self) then
      tick(self, heading[1], heading[2])
    else
      self._frMoved = false
      if self.player then
        self.player._frMoved = false
        -- a native step owns the player now: its own whole pixels draw it
        if self.player.moving then self._frTrueX, self._frTrueY = nil, nil end
      end
    end
    return unpackResults(out)
  end

  -- ---- sub-pixel smooth scroll ---------------------------------------------
  -- Gold draws the map, its neighbours and the people straight to the window at
  -- floor((x - camera.x) * scale), with the camera centred on the player's px.
  -- With whole-pixel px, a diagonal at constant speed steps the camera unevenly
  -- (one axis moves, then both, then the other), which is the jagged scroll.
  -- For the draw only, the player's px/py carry the body's exact fractional
  -- position: the camera centres on it, the ground and NPCs scroll smoothly at
  -- window-pixel resolution, and the player stays fixed on screen. The whole
  -- pixels are put back the moment the draw returns, so no logic ever sees a
  -- fraction. Only while free motion owns the position (px still the value it
  -- wrote); otherwise the draw is untouched.
  local innerDraw = World.draw
  if type(innerDraw) == "function" then
    local packResults = table.pack or function(...)
      return { n = select("#", ...), ... }
    end
    function World:draw(...)
      local p = self.player
      local tx, ty = self._frTrueX, self._frTrueY
      if not (p and tx and optionOn() and not p.moving
              and p.px == self._frPx and p.py == self._frPy) then
        return innerDraw(self, ...)
      end
      local wx, wy = p.px, p.py
      p.px, p.py = tx, ty
      -- The player's own sprite. SpriteRenderer floors px to whole GAME pixels
      -- while the camera origin it is drawn from is floored at WINDOW pixels;
      -- with a fractional px the two roundings disagree and the sprite lands up
      -- to a game pixel off, differently every frame. So the sprite draws from
      -- its whole-pixel px, and the dropped fraction (plus the camera floor)
      -- moves into its window-pixel origin instead: the sprite lands on the
      -- same window pixel every frame, centred where the camera put it.
      local world = self
      local ownDraw = rawget(p, "draw")
      local baseDraw = p.draw
      if type(baseDraw) == "function" then
        p.draw = function(pl, ox, oy, scale, ...)
          local cam = world.camera
          local s = tonumber(scale) or 1
          if cam and tonumber(ox) and tonumber(oy) then
            -- where the sprite truly belongs, rounded once to a window pixel,
            -- minus the whole-pixel offset the sprite will add itself
            local camOx, camOy = -cam.x * s, -cam.y * s
            local landX = math.floor(ox + (camOx - math.floor(camOx)) + tx * s + 0.5)
            local landY = math.floor(oy + (camOy - math.floor(camOy)) + ty * s + 0.5)
            ox = landX - wx * s
            oy = landY - wy * s
          end
          pl.px, pl.py = wx, wy
          local rr = packResults(pcall(baseDraw, pl, ox, oy, scale, ...))
          pl.px, pl.py = tx, ty
          if not rr[1] then error(rr[2], 0) end
          return unpackResults(rr, 2, rr.n)
        end
      end
      local r = packResults(pcall(innerDraw, self, ...))
      p.draw = ownDraw
      p.px, p.py = wx, wy
      if not r[1] then error(r[2], 0) end
      return unpackResults(r, 2, r.n)
    end
  end

  World.freeRoamHook = true

  M.active = function() return optionOn() end
  M.position = function() return nil end
  M._internal = {
    freeAllowed = freeAllowed,
    framesPerCell = framesPerCell,
    blockedCell = blockedCell,
  }
end

M.active = function() return false end
M.position = function() return nil end

return M
