-- FREE ROAM / smooth scroll: sub-pixel world scrolling for the pixel walk on
-- the engine's Renderer world canvas (Gen 1, and Gen 3's FireRed field view).
--
-- THE WORLD. The overworld is drawn into an offscreen worldCanvas at game
-- resolution with the camera floored to a whole game-pixel, and that canvas is
-- blitted to the window at an integer scale. At a constant diagonal speed
-- (0.707 px/frame per axis) a whole-pixel camera steps unevenly -- the judder.
-- So the scroll is split: the WHOLE-pixel part stays baked into the canvas
-- (tiles stay crisp) and the SUB-pixel remainder the arm reports (V.subpixel)
-- shifts the world canvas's blit origin, in window pixels. The two sum back to
-- the true position, so the world scrolls smoothly between game-pixels.
--
-- THE PLAYER. The player is drawn INTO that canvas at whole pixels, so shifting
-- the canvas also slides the player up to half a game-pixel each frame along
-- the direction of travel -- a jagged sprite. The fix splits the world pass at
-- the moment the player is drawn:
--   before  everything drawn before the player   -> shifted with the world
--   player  the player alone (its own canvas)    -> NOT shifted
--   after   everything drawn after the player    -> shifted with the world
-- and composites them in that order, so draw order is untouched: tall-grass
-- feet, roofs, NPCs in front and field effects still cover the player exactly
-- as before, but they stay glued to the world while the player stays fixed on
-- screen. At the end of the pass the three are merged back into the real
-- worldCanvas, so anything else that reads it (pipelines, mirrors, transitions,
-- other mods) sees the ordinary, complete frame.
--
-- The split only engages on frames the free walk is actually driving (the arm
-- bumps V.layerSerial each frame it runs), while the remainder is non-zero, in
-- the flat path (not tilt, not a pipeline, not a fade scratch canvas), and never
-- across a mid-pass canvas swap (FireRed weather): any of those, and the frame
-- is drawn exactly as before.

local V = ...
local unpack = table.unpack or unpack

local M = {}

local STALE_DRAWS = 6        -- draws without a free-walk frame before the split rests

local function G() return love and love.graphics end

function M.install()
  local ok, Renderer = pcall(require, "src.render.Renderer")
  if not ok or type(Renderer) ~= "table"
     or type(Renderer.blitCanvas) ~= "function" then
    return false
  end
  if Renderer.freeRoamSmoothHook then return true end

  local okP, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not okP or type(PaletteFX) ~= "table" then PaletteFX = nil end
  local okC, PixelCanvas = pcall(require, "src.render.PixelCanvas")
  if not okC or type(PixelCanvas) ~= "table" then PixelCanvas = nil end

  V.layerSerial = V.layerSerial or 0

  -- ---- the per-frame split state -------------------------------------------
  local L = {
    active = false,     -- this world pass may split
    hasP = false,       -- the player was captured this pass
    A = nil,            -- the real worldCanvas the pass drew into
    base = nil,         -- before-player content (+ anything late), for the blit
    P = nil, B = nil,   -- the player; everything after it
    pFrom = nil, pTo = nil,   -- the player's sprite-redraw entries (GBC mode)
    lastSerial = nil, stale = 0,
    shiftedRedraws = false,
  }
  V.layer = L

  local function subpixelOn()
    local sp = V.subpixel
    return sp and (sp.x ~= 0 or sp.y ~= 0)
  end

  local function redraws()
    if PaletteFX and type(PaletteFX.spriteRedraws) == "function" then
      local okR, list = pcall(PaletteFX.spriteRedraws)
      if okR and type(list) == "table" then return list end
    end
    return nil
  end

  local function sized(c, w, h)
    if c and c:getWidth() == w and c:getHeight() == h then return c end
    if c and c.release then c:release() end
    local g = G()
    if PixelCanvas and PixelCanvas.new then return PixelCanvas.new(w, h, "nearest") end
    local nc = g.newCanvas(w, h, { dpiscale = 1 })
    if nc.setFilter then nc:setFilter("nearest", "nearest") end
    return nc
  end

  -- clear the current canvas whole, whatever scissor the pass has set
  local function clearAll(g, r, gg, b, a)
    local sx, sy, sw, sh = g.getScissor()
    if sx then g.setScissor() end
    g.clear(r, gg, b, a)
    if sx then g.setScissor(sx, sy, sw, sh) end
  end

  -- draw `src` over `dst` 1:1, state untouched
  local function stamp(g, dst, src, replace)
    g.push("all")
    g.origin()
    g.setScissor()
    g.setShader()
    g.setColor(1, 1, 1, 1)
    g.setCanvas(dst)
    if replace then
      g.setBlendMode("replace", "premultiplied")
    else
      g.setBlendMode("alpha", "premultiplied")
    end
    g.draw(src, 0, 0)
    g.pop()
  end

  -- fold the split back into the real canvas (A = before + player + after)
  local function merge()
    if not L.hasP then return end
    local g = G()
    L.base = sized(L.base, L.A:getWidth(), L.A:getHeight())
    stamp(g, L.base, L.A, true)          -- keep before-player content for the blit
    stamp(g, L.A, L.P, false)
    stamp(g, L.A, L.B, false)
    L.merged = true
  end

  -- Called by an arm around its player's own draw call. Draws the player into
  -- the player canvas and points the rest of the pass at the after canvas; or,
  -- if this frame does not split, just draws.
  function L.capture(drawFn)
    local g = G()
    if not (L.active and not L.hasP and g and type(drawFn) == "function") then
      return drawFn()
    end
    local A = g.getCanvas()
    local R = L.renderer
    if not (R and A and A == R.worldCanvas and R.worldActive ~= false) then
      return drawFn()
    end
    local w, h = A:getWidth(), A:getHeight()
    L.P = sized(L.P, w, h)
    L.B = sized(L.B, w, h)
    L.A = A
    local list = redraws()
    local n0 = list and #list or 0
    g.setCanvas(L.P)
    clearAll(g, 0, 0, 0, 0)
    local r = { n = 0 }
    local function keep(...) r = { n = select("#", ...), ... } end
    keep(pcall(drawFn))
    list = redraws()
    L.pFrom, L.pTo = n0 + 1, list and #list or 0
    g.setCanvas(L.B)
    clearAll(g, 0, 0, 0, 0)
    L.hasP = true
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, r.n)
  end

  -- ---- the pass seams ------------------------------------------------------

  local innerBegin = Renderer.beginWorldPass
  if type(innerBegin) == "function" then
    function Renderer:beginWorldPass(...)
      L.renderer = self
      L.hasP, L.merged, L.shiftedRedraws = false, false, false
      L.pFrom, L.pTo = nil, nil
      if V.layerSerial ~= L.lastSerial then
        L.lastSerial, L.stale = V.layerSerial, 0
      else
        L.stale = L.stale + 1
      end
      L.active = subpixelOn() and L.stale <= STALE_DRAWS and G() ~= nil
      return innerBegin(self, ...)
    end
  end

  local innerEnd = Renderer.endWorldPass
  if type(innerEnd) == "function" then
    function Renderer:endWorldPass(...)
      if L.hasP and not L.merged then
        local okM = pcall(merge)
        if not okM then L.hasP = false end
      end
      return innerEnd(self, ...)
    end
  end

  -- a mid-pass canvas swap (FireRed weather): fold the split back first so the
  -- swap sees the whole frame, and draw this frame unsplit
  local innerExchange = Renderer.exchangeWorldCanvas
  if type(innerExchange) == "function" then
    function Renderer:exchangeWorldCanvas(current, replacement, ...)
      if L.hasP and not L.merged then
        local g = G()
        pcall(merge)
        if current == L.B then current = L.A end
        if g then g.setCanvas(L.A) end
        L.hasP = false
      end
      return innerExchange(self, current, replacement, ...)
    end
  end

  -- ---- the blit ------------------------------------------------------------

  local inner = Renderer.blitCanvas
  function Renderer:blitCanvas(canvas, sx, sy, zoneList, zoneSx, zoneSy,
                               bx, by, boxX, boxY, boxW, boxH, dpiX, dpiY)
    local sp = V.subpixel
    if not (sp and canvas == self.worldCanvas and (sp.x ~= 0 or sp.y ~= 0)) then
      return inner(self, canvas, sx, sy, zoneList, zoneSx, zoneSy,
                   bx, by, boxX, boxY, boxW, boxH, dpiX, dpiY)
    end
    local wx, wy = bx - sp.x * sx, by - sp.y * sy

    -- GBC sprite-colour mode replays sprites on top after this blit, at the
    -- unshifted origin: glue every replay but the player's to the world
    if not L.shiftedRedraws then
      L.shiftedRedraws = true
      local list = redraws()
      if list then
        for i, rd in ipairs(list) do
          local own = L.hasP and L.pFrom and i >= L.pFrom and i <= (L.pTo or 0)
          if not own and type(rd.x) == "number" and type(rd.y) == "number" then
            rd.x, rd.y = rd.x - sp.x, rd.y - sp.y
          end
        end
      end
    end

    if not (L.hasP and L.merged and canvas == L.A and L.base) then
      return inner(self, canvas, sx, sy, zoneList, zoneSx, zoneSy,
                   wx, wy, boxX, boxY, boxW, boxH, dpiX, dpiY)
    end
    inner(self, L.base, sx, sy, zoneList, zoneSx, zoneSy,
          wx, wy, boxX, boxY, boxW, boxH, dpiX, dpiY)
    -- the player and after parts were drawn onto transparent canvases, so their
    -- colour is premultiplied: composite them that way or translucent overlays
    -- (fog, flash darkness) come out darker than the engine drew them
    local g = G()
    local mode, alphaMode
    if g and g.getBlendMode then mode, alphaMode = g.getBlendMode() end
    if g and g.setBlendMode then g.setBlendMode("alpha", "premultiplied") end
    local okB, err = pcall(function()
      inner(self, L.P, sx, sy, zoneList, zoneSx, zoneSy,
            bx, by, boxX, boxY, boxW, boxH, dpiX, dpiY)
      inner(self, L.B, sx, sy, zoneList, zoneSx, zoneSy,
            wx, wy, boxX, boxY, boxW, boxH, dpiX, dpiY)
    end)
    if g and g.setBlendMode and mode then g.setBlendMode(mode, alphaMode) end
    if not okB then error(err, 0) end
  end

  Renderer.freeRoamSmoothHook = true
  return true
end

return M
