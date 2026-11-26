-- FREE ROAM / Gen 1 arm.
--
-- On Gen 1 the overworld module src.world.OverworldController IS the running
-- singleton, and OverworldState:handleInput is the single frame-by-frame seam
-- the grid walk reads the pad through -- the same seam the engine's own
-- Cycling Road pull and collision warps live behind. So this arm wraps that
-- one method and runs a pixel-continuous body in its place, asking the
-- engine's own Collision the questions a grid step asks and firing the
-- engine's own landing pipeline (onStepComplete) once per cell crossed.
--
-- This is the original Free Roam behaviour, unchanged in substance; it now
-- draws its heading, facing, slide and pace from lib/core so all three
-- generations share one feel and one tested maths core.

local V = ...
local unpack = table.unpack or unpack
local C = V.core

local M = {}

function M.install()
  local Collision = require("src.world.Collision")
  local Runtime = require("src.mods.Runtime")

  -- the free position (player centre, world px) and the px/py we last wrote.
  -- If they differ from the player's, something else -- a warp, a script, a
  -- ledge hop -- moved them, and the free walk adopts rather than fights.
  local pos = nil
  local lastPx, lastPy = nil, nil
  local facing = nil
  local animAcc = 0       -- leg-cadence share carried between frames
  local layerPlayer = nil -- the player the free walk last drove
  local seam = nil        -- a map-connection step the free walk rides

  local function adopt(p)
    pos = { x = p.px + 8, z = p.py + 8 }
    lastPx, lastPy = p.px, p.py
    facing = p.facing
  end

  local function drop()
    pos = nil
    animAcc = 0
    -- hand the whole-pixel grid walk a clean (unshifted) world
    if V.subpixel then V.subpixel.x, V.subpixel.y = 0, 0 end
  end

  -- the same questions Collision.canMove asks for a grid step, asked of one
  -- cell; the player's OWN cell never blocks (it must always be free to leave
  -- wherever it stands). Returns "bounds" | "tile" | "entity" or nil.
  local function cellVerdict(state, p, cx, cy)
    local map = state.map
    if not map:inBounds(cx, cy) then return "bounds" end
    if not map:isWalkableCell(cx, cy) then
      if not (p.surfing and map:isWaterCell(cx, cy)) then return "tile" end
    end
    if Collision.pairBlocked
       and Collision.pairBlocked(map, p, p.cellX, p.cellY, cx, cy) then
      return "tile"
    end
    if Collision.occupied(state.entities, cx, cy, p) then return "entity" end
    return nil
  end

  -- the movement.collision chain sees the boolean; a wrapper that flips it
  -- rewrites ctx.reason to say why (the engine's own reasons are bounds /
  -- tile / entity), so the hook stays a single-value middleware -- the exact
  -- shape Collision.canMove builds for a grid step, built here for one cell
  -- of the free walk's own sliding check. A mod that hooks that chain (a
  -- walk-through-walls cheat, a rule that adds a block) governs the free
  -- walk the same way it already governs the grid walk.
  local function passthrough(allowed) return allowed end

  -- Cells the engine moves the player through on its own grid: the spinner
  -- arrows (Viridian Gym, Rocket Hideout) and Seafoam's surf currents. The
  -- free body treats them as a wall; a firm push hands the step to the
  -- engine, which then runs the arrow or current exactly as the cart does.
  local function inList(list, cx, cy)
    for _, c in ipairs(list or {}) do
      if c.x == cx and c.y == cy then return true end
    end
    return false
  end

  local function forcedCell(state, p, cx, cy)
    local Game = require("src.core.Game")
    local field = Game.data and Game.data.field
    if not field or not state.map then return false end
    local id = state.map.id
    if field.spinners and inList(field.spinners[id], cx, cy) then return true end
    local sf = field.seafoam and field.seafoam[id]
    if sf and p.surfing then
      if inList(sf.currents, cx, cy) then return true end
      local e = sf.entryCurrent
      if e and e.x == cx and e.y == cy then return true end
      if sf.forcedExit and inList(sf.forcedExit.coords, cx, cy) then return true end
    end
    return false
  end

  local function blockedCell(state, p, cx, cy)
    if cx == p.cellX and cy == p.cellY then return nil end
    local why = cellVerdict(state, p, cx, cy)
    if why == nil then
      local okF, forced = pcall(forcedCell, state, p, cx, cy)
      if okF and forced then why = "forced" end
    end
    if not Runtime.wantsHook("movement.collision") then return why end
    local dx, dy = cx - p.cellX, cy - p.cellY
    local dir = (dx == 1 and "right") or (dx == -1 and "left")
      or (dy == 1 and "down") or (dy == -1 and "up") or nil
    local ctx = { map = state.map, mover = p, dir = dir,
                  fromX = p.cellX, fromY = p.cellY, toX = cx, toY = cy,
                  reason = why }
    local allowed = Runtime.call("movement.collision", passthrough, why == nil, ctx)
    if allowed then return nil end
    return ctx.reason or why
  end

  local function heading(input)
    return C.heading(input, {
      analog = V.option("analog", true) ~= false,
      diagonals = V.option("diagonals", true) ~= false,
      facing = facing,
    })
  end

  local function quantise(dx, dy, current) return C.quantise(dx, dy, current) end

  -- pace from the engine, never restated: Player:stepLength folds in the
  -- bicycle, the Cycling Road slope rule and any movement.speed hook.
  local function paceOf(p, dir)
    local frames = 16
    if type(p.stepLength) == "function" then
      local ok, value = pcall(p.stepLength, p, dir)
      value = ok and tonumber(value) or nil
      if value and value >= 1 then frames = value end
    end
    return C.pace(frames)
  end

  -- the grid game's blocked step is where half its verbs live: the map-edge
  -- crossing, the ledge hop, the boulder shove, the route-gate warp. Hand the
  -- engine the quantised direction and let its own handlers decide; each
  -- validates itself. Returns true when one took the frame over. The bonk is
  -- deliberately NOT restated: a free walk grazes rather than presses, and the
  -- wall stopping you is the feedback.
  -- start the engine's step (already begun) where the body stood along it
  local function startAt(p, along)
    if not (p.moving and along and along > 0) then return end
    local stepLen = p.stepFramesCur or p.stepFrames or 16
    p.progress = math.max(0, math.min(stepLen - 1, math.floor(along * stepLen / 16)))
    local d = Collision.DELTA and Collision.DELTA[p.facing]
    if d then
      local adv = math.floor(p.progress * 16 / stepLen)
      p.px = p.cellX * 16 + d[1] * adv
      p.py = p.cellY * 16 + d[2] * adv
    end
  end

  local function sideways(dir) return dir == "left" or dir == "right" end

  local function pushSpecials(state, dir, why, along, perp)
    local p = state.player
    p.facing = dir
    if why == "bounds" and state:checkEdgeExit(dir) then
      -- a map connection: the engine parked the player one cell before the
      -- landing cell mid-step; ride that step at the body's sideways offset
      if p.moving and p.targetX then
        startAt(p, along)
        seam = { dir = dir, perp = perp or 0, tx = p.targetX, ty = p.targetY, player = p }
      end
      return true
    end
    if why == "forced" then
      p.turnArmed = false
      local result = p:tryMove(dir, state.map, state.entities)
      if result == "moved" then
        startAt(p, along)
        return true
      end
      return false
    end
    if state:checkLedgeHop(dir) then return true end
    if state:checkBoulderPush(dir) then return true end
    if why ~= "entity" and state:canCollisionWarp() and not p.surfing then
      local Game = require("src.core.Game")
      local Warp = require("src.world.Warp")
      local w = Warp.onCollision(state.map, Game.data.field.warpCarpets,
                                 p.cellX, p.cellY, dir)
      if w then
        state:takeWarp(w.def)
        return true
      end
    end
    return false
  end

  local function tick(state)
    local p = state.player
    local Game = require("src.core.Game")
    local input = Game.input

    state.bumpCooldown = math.max(0, (state.bumpCooldown or 0) - 1)

    if p.moving or p.inputLocked then
      drop()
      return
    end
    if not pos or p.px ~= lastPx or p.py ~= lastPy then adopt(p) end

    -- the free walk drives this frame: the smooth scroll may split the world
    -- pass around this player's sprite (lib/smoothscroll)
    V.layerSerial = (V.layerSerial or 0) + 1
    layerPlayer = p

    if input:wasPressed("a") then
      state:interact()
      return
    end
    if input:wasPressed("start") then
      require("src.core.Sound").play(Game.data, "Start_Menu")
      require("src.ui.Screens").push(Game, "StartMenu")
      return
    end

    local dx, dy = heading(input)
    local moving = dx ~= nil and (dx ~= 0 or dy ~= 0)

    -- Cycling Road's downhill pull: the free-walk restatement of the grid
    -- path's simulated PAD_DOWN, braked by holding A or B.
    if not moving and Game.save and Game.save.onBike
       and not (input:isDown("a") or input:isDown("b"))
       and state.onSlopeMap and state:onSlopeMap() then
      dx, dy, moving = 0, 1, true
    end

    if not moving then
      p.turnArmed = true
      return
    end

    facing = quantise(dx, dy, facing or p.facing)
    p.facing = facing

    -- TRUE PACE: walking slows to two thirds; the bicycle and surf never do
    local foot = C.footFactor(V.option("truePace", false) == true,
      not (Game.save and Game.save.onBike) and not p.surfing)
    local pace = paceOf(p, facing) * foot
    -- Constant speed in every direction (unit heading * pace): a diagonal moves
    -- 0.707 px/frame per axis, the same total speed as a cardinal, whatever the
    -- stick deflection. The diagonal JUDDER this used to cause is fixed at the
    -- pixel-write below, not by speeding the diagonal up.
    local vx, vy = dx * pace, dy * pace

    local blocked = function(cx, cy) return blockedCell(state, p, cx, cy) end
    local hitX, hitY
    pos.x, hitX = C.slideX(pos.x, pos.z, vx, C.RADIUS, blocked)
    pos.z, hitY = C.slideZ(pos.x, pos.z, vy, C.RADIUS, blocked)
    if foot ~= 1 then pos.x, pos.z = C.tidy(pos.x), C.tidy(pos.z) end

    p.bumpFrames = 2

    -- Leg cadence. The engine's wall-bonk clock ticks animClock once per frame
    -- while bumpFrames is set; on a diagonal let only a share of those ticks
    -- through, by cancelling the engine's tick on the others (speed untouched).
    -- (slowed by the same TRUE PACE factor, so the legs match the body)
    animAcc = animAcc + C.animRate(dx, dy) * foot
    if foot ~= 1 then animAcc = C.tidy(animAcc) end
    if animAcc >= 1 then
      animAcc = animAcc - 1
    elseif (p.animClock or 0) > 0 then
      p.animClock = p.animClock - 1
    end

    -- Whole-pixel write: px/py are the contract every consumer of them has (the
    -- camera, the sprite blit, overlay anchors), so they round to the nearest
    -- pixel. The fractional remainder the rounding drops is handed to the
    -- smooth-scroll wrap (lib/smoothscroll), which rides it onto the world blit
    -- as a sub-pixel shift -- so the WHOLE-pixel part scrolls the crisp tiles
    -- and the SUB-pixel part scrolls the camera smoothly between them, summing
    -- back to the true continuous position. That is what removes the diagonal
    -- judder while keeping the exact constant speed.
    p.px = math.floor(pos.x - 8 + 0.5)
    p.py = math.floor(pos.z - 8 + 0.5)
    if V.subpixel then
      V.subpixel.x = (pos.x - 8) - p.px
      V.subpixel.y = (pos.z - 8) - p.py
    end
    lastPx, lastPy = p.px, p.py

    local ncx = math.floor(pos.x / 16)
    local ncy = math.floor(pos.z / 16)
    if ncx ~= p.cellX or ncy ~= p.cellY then
      p.cellX, p.cellY = ncx, ncy
      state:onStepComplete()
      return
    end

    local why, dir
    if hitX and (not hitY or math.abs(vx) >= math.abs(vy)) then
      why, dir = hitX, (vx > 0 and "right" or "left")
    elseif hitY then
      why, dir = hitY, (vy > 0 and "down" or "up")
    end
    if why and math.max(math.abs(vx), math.abs(vy)) > 0.4 * pace then
      local sx = (dir == "right" and 1) or (dir == "left" and -1) or 0
      local sy = (dir == "down" and 1) or (dir == "up" and -1) or 0
      local cx, cz = p.cellX * 16 + 8, p.cellY * 16 + 8
      if why == "forced" then
        -- along the edge slides; a push (nearly) straight in lines the body
        -- up with the cell, a glide, then hands the step to the engine
        local side = math.abs(sx ~= 0 and dy or dx)
        local sideHit
        if sx ~= 0 then sideHit = hitY else sideHit = hitX end
        if side > 0.38 and not sideHit then p.facing = facing; return end
        local off = (sx ~= 0) and (cz - pos.z) or (cx - pos.x)
        local step = math.min(math.abs(off), pace)
        if sx ~= 0 then pos.z = pos.z + (off > 0 and step or -step)
        else pos.x = pos.x + (off > 0 and step or -step) end
        p.px = math.floor(pos.x - 8 + 0.5)
        p.py = math.floor(pos.z - 8 + 0.5)
        if V.subpixel then
          V.subpixel.x, V.subpixel.y = (pos.x - 8) - p.px, (pos.z - 8) - p.py
        end
        lastPx, lastPy = p.px, p.py
        if math.abs(off) - step > 0.05 then p.facing = facing; return end
        if sx ~= 0 then pos.z = cz else pos.x = cx end
      end
      local along = (sx ~= 0) and (pos.x - cx) * sx or (pos.z - cz) * sy
      local perp = (sx ~= 0) and (pos.z - cz) or (pos.x - cx)
      if pushSpecials(state, dir, why, along, perp) then
        drop()
        return
      end
      p.facing = facing
    end
  end

  -- the seam
  local OverworldState = require("src.world.OverworldController")
  if not OverworldState.freeRoamHook then
    local inner = OverworldState.handleInput
    function OverworldState:handleInput()
      if V.option("enabled", true) == false then
        if pos then
          local p = self.player
          p.px, p.py = p.cellX * 16, p.cellY * 16
          p.turnArmed = true
          drop()
        end
        return inner(self)
      end
      return tick(self)
    end
    OverworldState.freeRoamHook = true
  end

  -- The player's sprite draw. The smooth scroll shifts the world canvas by the
  -- sub-pixel remainder; the player, drawn into that canvas at whole pixels,
  -- would slide with it by up to half a game-pixel a frame. Handing the draw to
  -- the layer puts the player in its own unshifted canvas, between what was
  -- drawn before and after it, so it holds still on screen.
  -- the seam, after the engine's own step update each frame: the sideways
  -- offset back on the player (its fraction to the smooth scroll), and on
  -- landing the body rebuilt at that offset
  local function applySeam(p)
    local s = seam
    if not s or s.player ~= p then return end
    if p.moving then
      if p.targetX ~= s.tx or p.targetY ~= s.ty then seam = nil; return end
      local whole = math.floor(s.perp + 0.5)
      if sideways(s.dir) then
        p.py = p.cellY * 16 + whole
        if V.subpixel then V.subpixel.x, V.subpixel.y = 0, s.perp - whole end
      else
        p.px = p.cellX * 16 + whole
        if V.subpixel then V.subpixel.x, V.subpixel.y = s.perp - whole, 0 end
      end
      V.layerSerial = (V.layerSerial or 0) + 1
      layerPlayer = p
      return
    end
    seam = nil
    if p.cellX ~= s.tx or p.cellY ~= s.ty then return end
    local x, z = p.cellX * 16 + 8, p.cellY * 16 + 8
    if sideways(s.dir) then z = z + s.perp else x = x + s.perp end
    pos = { x = x, z = z }
    facing = p.facing
    p.px = math.floor(pos.x - 8 + 0.5)
    p.py = math.floor(pos.z - 8 + 0.5)
    if V.subpixel then
      V.subpixel.x, V.subpixel.y = (pos.x - 8) - p.px, (pos.z - 8) - p.py
    end
    lastPx, lastPy = p.px, p.py
    V.layerSerial = (V.layerSerial or 0) + 1
    layerPlayer = p
  end

  local okPl, PlayerCls = pcall(require, "src.world.Player")
  if okPl and type(PlayerCls) == "table" and type(PlayerCls.update) == "function"
     and not PlayerCls.freeRoamUpdateHook then
    local innerUpdate = PlayerCls.update
    function PlayerCls:update(...)
      local r1, r2 = innerUpdate(self, ...)
      if seam and seam.player == self then pcall(applySeam, self) end
      return r1, r2
    end
    PlayerCls.freeRoamUpdateHook = true
  end
  if okPl and type(PlayerCls) == "table" and type(PlayerCls.draw) == "function"
     and not PlayerCls.freeRoamDrawHook then
    local innerDraw = PlayerCls.draw
    function PlayerCls:draw(...)
      local L = V.layer
      if L and self == layerPlayer and (pos or seam) and type(L.capture) == "function" then
        local args = { n = select("#", ...), ... }
        return L.capture(function()
          return innerDraw(self, unpack(args, 1, args.n))
        end)
      end
      return innerDraw(self, ...)
    end
    PlayerCls.freeRoamDrawHook = true
  end

  -- live state the entry point exports read, plus the pure pieces the suite
  -- drives headlessly
  -- TRUE PACE for the party follower (Yellow's Pikachu, or a follower mod's
  -- companion, which rides the same seam): it walks each cell over the
  -- player's step length, read as the step starts, so hand it the slowed one
  -- for its own update and thin its per-frame leg clock to match. Only while
  -- the free walk is on and the player is on foot, exactly when the player
  -- itself is slowed.
  local okFol, Follower = pcall(require, "src.world.PikachuFollower")
  if okFol and type(Follower) == "table" and type(Follower.update) == "function"
     and not Follower.freeRoamPaceHook then
    local function slowNow(p)
      local Game = require("src.core.Game")
      return V.option("enabled", true) ~= false
        and C.footFactor(V.option("truePace", false) == true,
          not (Game.save and Game.save.onBike) and not p.surfing) ~= 1
    end
    local paced = C.paceFollowerUpdate(Follower.update,
      { "stepFramesCur", "stepFrames" }, slowNow,
      function(_, ow) return ow and ow.player end)
    local thinLegs = C.newLegThinner()
    Follower.update = function(game, ow, ...)
      local out = { paced(game, ow, ...) }
      local p = ow and ow.player
      local npc = type(Follower.current) == "function" and Follower.current(ow) or nil
      thinLegs(npc, p ~= nil and slowNow(p))
      return (table.unpack or unpack)(out)
    end
    Follower.freeRoamPaceHook = true
  end

  M.active = function() return pos ~= nil end
  M.position = function()
    if not pos then return nil end
    return pos.x, pos.z
  end
  M._internal = {
    tick = tick,
    quantise = quantise,
    heading = heading,
    blockedCell = blockedCell,
    paceOf = paceOf,
    position = function() return pos end,
    drop = drop,
    RADIUS = C.RADIUS,
    STICK_DEAD = C.STICK_DEAD,
  }
end

-- defaults before install (so exports are safe to call early)
M.active = function() return false end
M.position = function() return nil end

return M
