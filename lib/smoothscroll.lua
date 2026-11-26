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
  --
  -- A pass may hold several player-anchored draws (Gen 3's surf blob, then the
  -- player): each capture opens a held segment (not shifted) and then a world
  -- segment (shifted) for whatever is drawn after it, so the composite is
  --   base | held 1 | world 1 | held 2 | world 2 | ...
  -- in the exact order the engine drew them.
  local L = {
    active = false,     -- this world pass may split
    hasP = false,       -- at least one player-anchored draw was captured
    A = nil,            -- the real worldCanvas the pass drew into
    base = nil,         -- before-player content (+ anything late), for the blit
    segs = {},          -- { canvas, held } in draw order
    pool = {},          -- reusable segment canvases
    held = {},          -- { from, to } sprite-redraw ranges of held draws
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

  -- fold the split back into the real canvas (A = before + every segment)
  local function merge()
    if not L.hasP then return end
    local g = G()
    L.base = sized(L.base, L.A:getWidth(), L.A:getHeight())
    stamp(g, L.base, L.A, true)          -- keep before-player content for the blit
    for i = 1, #L.segs do stamp(g, L.A, L.segs[i].canvas, false) end
    L.merged = true
  end

  -- a fresh, cleared segment canvas made current
  local function openSegment(g, held)
    local i = #L.segs + 1
    local c = sized(L.pool[i], L.A:getWidth(), L.A:getHeight())
    L.pool[i] = c
    L.segs[i] = { canvas = c, held = held }
    g.setCanvas(c)
    clearAll(g, 0, 0, 0, 0)
    return c
  end

  -- ---- WoobleView (gen3-hd-sprites) ----------------------------------------
  --
  -- WoobleView records some field sprites (overworld Pokemon, followers, HD
  -- people) while the world pass runs and draws them at window resolution
  -- when the world canvas is blitted, at that blit's origin. Two things
  -- follow. Splitting the pass into canvases of our own hides the draws after
  -- the player from its recorder (they land raw on a low-res canvas: a
  -- follower that "loses its shape"), and its sprites are placed from the
  -- blit's origin, so they only move with the world if the shift reaches
  -- them. So while it captures the field this mod does not split the pass.
  -- It shifts the whole composite (ours stays the outermost blit), and holds
  -- the player still a different way: the player's own draw is handed to
  -- WoobleView as a recorded draw too, moved by the same shift the other
  -- way, so it lands back on its spot to the physical pixel.
  local WOOBLE_RECHECK = 60
  local woobleApi, woobleFrame = nil, -WOOBLE_RECHECK
  local passCount = 0

  local function woobleExports()
    if passCount - woobleFrame < WOOBLE_RECHECK then return woobleApi end
    woobleFrame = passCount
    woobleApi = nil
    local mod = V.mod
    if mod and type(mod.find) == "function" then
      local ok, found = pcall(mod.find, mod, "gen3-hd-sprites")
      local ex = ok and type(found) == "table" and found.exports
      if type(ex) == "table" and type(ex.tag) == "function" and type(ex.tagOf) == "function" then
        woobleApi = ex
      end
    end
    return woobleApi
  end

  -- WoobleView is recording this frame's field pass
  local function woobleField()
    local ex = woobleExports()
    if not ex then return nil end
    local okA, active = pcall(ex.isActive)
    if not (okA and active) then return nil end
    if type(ex.enabled) == "function" then
      local okE, on = pcall(ex.enabled, "field")
      if not (okE and on) then return nil end
    end
    return ex
  end

  -- the shift the blit will apply, in game pixels (whole physical pixels,
  -- as the blit rounds it; the scale is the last blit's)
  local function shiftNow()
    local sp = V.subpixel
    local sx, sy = L.lastSx or 1, L.lastSy or 1
    local dx, dy = L.lastDpiX or 1, L.lastDpiY or 1
    local x = math.floor(sp.x * sx * dx + 0.5) / dx / sx
    local y = math.floor(sp.y * sy * dy + 0.5) / dy / sy
    return x, y
  end

  local function isImage(img)
    return type(img) == "userdata" and type(img.typeOf) == "function"
      and img:typeOf("Image")
  end

  -- the player's draw as WoobleView recorded draws, nudged back by the shift
  local function woobleCapture(g, ex, drawFn)
    local tx, ty = shiftNow()
    local draw = g.draw
    g.draw = function(img, ...)
      if isImage(img) then
        local okT, spec = pcall(ex.tagOf, img)
        if okT and spec == nil then pcall(ex.tag, img, { scale = 1, anchor = "feet" }) end
      end
      return draw(img, ...)
    end
    g.push()
    g.translate(tx, ty)
    local r = { n = 0 }
    local function keep(...) r = { n = select("#", ...), ... } end
    keep(pcall(drawFn))
    g.pop()
    g.draw = draw
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, r.n)
  end

  -- Called by an arm around a player-anchored draw (the player's sprite, the
  -- surf blob under it). Draws it into a held segment and points the rest of
  -- the pass at a new world segment; or, if this frame does not split, just
  -- draws. (With WoobleView recording the field: see woobleCapture.)
  function L.capture(drawFn)
    local g = G()
    if not (L.active and g and type(drawFn) == "function") then
      return drawFn()
    end
    if L.wooble then return woobleCapture(g, L.wooble, drawFn) end
    local cur = g.getCanvas()
    local R = L.renderer
    if not L.hasP then
      if not (R and cur and cur == R.worldCanvas and R.worldActive ~= false) then
        return drawFn()
      end
      L.A = cur
      for i = #L.segs, 1, -1 do L.segs[i] = nil end
      for i = #L.held, 1, -1 do L.held[i] = nil end
    else
      -- a later capture must find the pass still on the last world segment
      local last = L.segs[#L.segs]
      if not (last and not last.held and cur == last.canvas) then
        return drawFn()
      end
    end
    local list = redraws()
    local n0 = list and #list or 0
    openSegment(g, true)
    local r = { n = 0 }
    local function keep(...) r = { n = select("#", ...), ... } end
    keep(pcall(drawFn))
    list = redraws()
    L.held[#L.held + 1] = { n0 + 1, list and #list or 0 }
    openSegment(g, false)
    L.hasP = true
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, r.n)
  end

  local function heldRedraw(i)
    for _, h in ipairs(L.held) do
      if i >= h[1] and i <= h[2] then return true end
    end
    return false
  end

  -- ---- the blit ------------------------------------------------------------
  --
  -- One blit, wrapped round whatever blit is under it. It is kept the
  -- outermost wrapper (re-wrapped at a world pass when a mod has wrapped over
  -- it), so a compositor that places its own sprites from the blit's origin
  -- (WoobleView) is handed the shifted origin, and a re-entrant call from
  -- under it (that compositor's own blits of its layers) passes through
  -- untouched: nothing is ever shifted twice.
  local inBlit = false

  local function shiftedBlit(inner, self, canvas, sx, sy, zoneList, zoneSx, zoneSy,
                             bx, by, boxX, boxY, boxW, boxH, dpiX, dpiY)
    local sp = V.subpixel
    if inBlit or L.folded
       or not (sp and canvas == self.worldCanvas and (sp.x ~= 0 or sp.y ~= 0)) then
      return inner(self, canvas, sx, sy, zoneList, zoneSx, zoneSy,
                   bx, by, boxX, boxY, boxW, boxH, dpiX, dpiY)
    end
    -- The shift is snapped to whole PHYSICAL pixels, so every layer (and
    -- every sprite a compositor draws from this origin) lands on the same
    -- pixel grid each frame; the world still scrolls at one-physical-pixel
    -- resolution.
    local dx = (dpiX and dpiX > 0) and dpiX or 1
    local dy = (dpiY and dpiY > 0) and dpiY or 1
    L.lastSx, L.lastSy, L.lastDpiX, L.lastDpiY = sx, sy, dx, dy
    local shiftX = math.floor(sp.x * sx * dx + 0.5) / dx
    local shiftY = math.floor(sp.y * sy * dy + 0.5) / dy
    local wx, wy = bx - shiftX, by - shiftY

    -- GBC sprite-colour mode replays sprites on top after this blit, at the
    -- unshifted origin: glue every replay but the player's to the world
    if not L.shiftedRedraws then
      L.shiftedRedraws = true
      local list = redraws()
      if list then
        for i, rd in ipairs(list) do
          local own = L.hasP and heldRedraw(i)
          if not own and type(rd.x) == "number" and type(rd.y) == "number" then
            rd.x, rd.y = rd.x - shiftX / sx, rd.y - shiftY / sy
          end
        end
      end
    end

    inBlit = true
    local g = G()
    local mode, alphaMode
    local ok, err = pcall(function()
      if not (L.hasP and L.merged and canvas == L.A and L.base) then
        inner(self, canvas, sx, sy, zoneList, zoneSx, zoneSy,
              wx, wy, boxX, boxY, boxW, boxH, dpiX, dpiY)
        return
      end
      inner(self, L.base, sx, sy, zoneList, zoneSx, zoneSy,
            wx, wy, boxX, boxY, boxW, boxH, dpiX, dpiY)
      -- the segments were drawn onto transparent canvases, so their colour
      -- is premultiplied: composite them that way or translucent overlays
      -- (fog, flash darkness) come out darker than the engine drew them
      if g and g.getBlendMode then mode, alphaMode = g.getBlendMode() end
      if g and g.setBlendMode then g.setBlendMode("alpha", "premultiplied") end
      for _, seg in ipairs(L.segs) do
        local x, y = wx, wy
        if seg.held then x, y = bx, by end
        inner(self, seg.canvas, sx, sy, zoneList, zoneSx, zoneSy,
              x, y, boxX, boxY, boxW, boxH, dpiX, dpiY)
      end
    end)
    if g and g.setBlendMode and mode then g.setBlendMode(mode, alphaMode) end
    inBlit = false
    if not ok then error(err, 0) end
  end

  function L.wrapOutermost()
    local under = Renderer.blitCanvas
    if type(under) ~= "function" then return end
    local outer = function(self, ...) return shiftedBlit(under, self, ...) end
    L.outer = outer
    Renderer.blitCanvas = outer
  end
  L.wrapOutermost()

  -- ---- the pass seams ------------------------------------------------------

  local innerBegin = Renderer.beginWorldPass
  if type(innerBegin) == "function" then
    function Renderer:beginWorldPass(...)
      L.renderer = self
      L.hasP, L.merged, L.shiftedRedraws, L.folded = false, false, false, false
      for i = #L.segs, 1, -1 do L.segs[i] = nil end
      for i = #L.held, 1, -1 do L.held[i] = nil end
      if V.layerSerial ~= L.lastSerial then
        L.lastSerial, L.stale = V.layerSerial, 0
      else
        L.stale = L.stale + 1
      end
      L.active = subpixelOn() and L.stale <= STALE_DRAWS and G() ~= nil
      passCount = passCount + 1
      L.wooble = L.active and woobleField() or nil
      -- stay the outermost blit (a mod wrapped after us)
      if Renderer.blitCanvas ~= L.outer then L.wrapOutermost() end
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

  -- a mid-pass canvas swap (weather colour maps): fold the split back first so
  -- the swap sees the whole frame, and draw this frame unsplit and unshifted
  local innerExchange = Renderer.exchangeWorldCanvas
  if type(innerExchange) == "function" then
    function Renderer:exchangeWorldCanvas(current, replacement, ...)
      -- WoobleView flattens its recording into the canvas here, the player's
      -- nudge with it: that frame is drawn unshifted too
      if L.wooble then L.folded = true end
      if L.hasP and not L.merged then
        local g = G()
        pcall(merge)
        for _, seg in ipairs(L.segs) do
          if current == seg.canvas then current = L.A end
        end
        if g then g.setCanvas(L.A) end
        L.hasP = false
        -- the player is baked into the frame now: shifting it would wobble
        -- the player by the sub-pixel and make the whole world seem to
        -- jitter around it, so this one frame is drawn unshifted
        L.folded = true
      end
      return innerExchange(self, current, replacement, ...)
    end
  end

  Renderer.freeRoamSmoothHook = true
  return true
end

return M
