-- GSI DEM Downloader v13-16 : cliff plugin CORE (fixed side - install once)
-- Map data (rows, edges, N, write) comes from a cliffdata_* plugin through City.getStorage().cliffwall_data.
-- The table is used only to FIND cliffs (where, which side is higher).
-- Heights are taken from the game's own terrain: ramps next to a cliff are flattened to the
-- game's top / bottom level and a wall is built between them.
local N = 64
local R = 4
local MAXD = 6
local MING = 5
local ROUNDS = 1
local WRITE = true
local SLIV = 0.25
local PID = "$cliffwall_gen"
local DONE = false
local LASTSTORE = nil
local ROWS = nil
local EDGES = ""
local WAITN = 0
local EXTRA = true -- v13-14 plan A: also wall every remaining flat-flat step on land
local JUNC = true -- v13-16: also wall flat-vs-slope junctions (flat tile lower than a sloped neighbour by >= 0.5)

-- byte of '0'-'9' (48-57) and 'a'-'f' (97-102) -> 0..15
local HV = {}
for i = 0, 9 do HV[48 + i] = i end
for i = 0, 5 do HV[97 + i] = 10 + i end

local DX = { -1, 0, 1, 0 } -- W, N, E, S
local DY = { 0, -1, 0, 1 }

local function log(s) pcall(function() Debug.log("[cliffwall] " .. s) end) end
local function toast(s) pcall(function() Debug.toast(s) end) end

local function gameH(x, y)
  local ok, v = pcall(function() return Tile.getTerrainHeight(x, y) end)
  if ok and type(v) == "number" then return v end
  return nil
end

local function gameLand(x, y)
  local ok, v = pcall(function() return Tile.isLand(x, y) end)
  if ok then return v end
  return nil
end

local function sizeMatches()
  local ok, w = pcall(function() return City.getWidth() end)
  if ok and type(w) == "number" and w ~= N then
    log("city width " .. tostring(w) .. " ~= " .. N .. " : skipped")
    return false
  end
  return true
end

local function inb(x, y) return x >= 0 and y >= 0 and x < N and y < N end
local function round(v) return math.floor(v + 0.5) end

local function apply()
  -- map data comes from the data plugin through the city's own storage table
  local st0 = nil
  pcall(function() st0 = City.getStorage() end)
  local D = (type(st0) == "table") and st0.cliffwall_data or nil
  if type(D) ~= "table" or type(D.rows) ~= "table" or type(D.edges) ~= "string" then
    WAITN = WAITN + 1
    if WAITN == 1 or WAITN == 300 then log("waiting for cliff data in City storage (n=" .. WAITN .. ")") end
    return
  end
  ROWS = D.rows
  EDGES = D.edges
  if type(D.n) == "number" then N = D.n end
  if D.write ~= nil then WRITE = (D.write == true) end
  -- once per CITY (not once per app session): the city's own storage table identifies the city
  local store = nil
  pcall(function() store = City.getStorage() end)
  if type(store) == "table" then
    if store == LASTSTORE then return end
    LASTSTORE = store
  else
    if DONE then return end
    DONE = true
  end
  if not sizeMatches() then return end
  -- apply only once per city: the flag lives in the city's own storage table (saved with the city)
  if type(store) == "table" and store.cliffwall_done == PID then
    log("already applied (city storage flag): skipped")
    toast("cliffwall: already applied")
    return
  end
  log("v13-16 start: write=" .. tostring(WRITE) .. " rows=" .. #ROWS .. " N=" .. N .. " R=" .. R .. " minGameDrop=" .. MING .. " rounds=" .. ROUNDS .. " sliver=" .. SLIV .. " storage=" .. type(store))

  -- 1) read the game's own terrain BEFORE writing anything (+ per table level statistics)
  local G, GI, LAND, G0 = {}, {}, {}, {}
  local lvN, lvSum, lvMin, lvMax = {}, {}, {}, {}
  local unreadable, landCount = 0, 0
  for y = 0, N - 1 do
    local line = ROWS[y + 1] or ""
    for x = 0, N - 1 do
      local i = y * N + x
      local g = gameH(x, y)
      if g == nil then unreadable = unreadable + 1; g = 0 end
      local l = gameLand(x, y)
      local isL
      if l == nil then isL = g > 0 else isL = l end
      G[i] = g; GI[i] = round(g); LAND[i] = isL; G0[i] = g
      if isL then landCount = landCount + 1 end
      local tv = HV[string.byte(line, x + 1)] or 0
      lvN[tv] = (lvN[tv] or 0) + 1
      lvSum[tv] = (lvSum[tv] or 0) + g
      if lvMin[tv] == nil or g < lvMin[tv] then lvMin[tv] = g end
      if lvMax[tv] == nil or g > lvMax[tv] then lvMax[tv] = g end
    end
  end
  log("game terrain read: land=" .. landCount .. " unreadable=" .. unreadable)
  for tv = 0, 15 do
    if lvN[tv] then
      log("level " .. tv .. ": n=" .. lvN[tv] .. " meanGame=" .. string.format("%.2f", lvSum[tv] / lvN[tv]) .. " min=" .. string.format("%.2f", lvMin[tv]) .. " max=" .. string.format("%.2f", lvMax[tv]))
    end
  end

  -- 2) cliff edges from the table: flatten the ramp on both sides to the game's top / bottom level
  local role, val, coastLow = {}, {}, {}
  local C = { edges = 0, skipWater = 0, flat = 0, capped = 0, conflict = 0, noLow = 0, conflictSkip = 0 }
  local HIST = { 0, 0, 0, 0, 0, 0, 0 }
  local hiSet, loSet, hiN, loN = {}, {}, 0, 0
  local WALLEDGES, HIGHSET, EDGEDIR = {}, {}, {}

  local function propose(i, r, v)
    local cur = role[i]
    if cur == nil then
      role[i] = r; val[i] = v
    elseif cur == r then
      if r == "H" then
        if v > val[i] then val[i] = v end
      else
        if v < val[i] then val[i] = v end
      end
    else
      C.conflict = C.conflict + 1 -- keep the first role
    end
  end

  local function handleEdge(hx, hy, lx, ly)
    C.edges = C.edges + 1
    local ai, bi = hy * N + hx, ly * N + lx
    if not hiSet[ai] then hiSet[ai] = true; hiN = hiN + 1 end
    if not loSet[bi] then loSet[bi] = true; loN = loN + 1 end
    if not LAND[ai] then C.skipWater = C.skipWater + 1; return end
    local dx, dy = hx - lx, hy - ly
    -- high side: walk away from the cliff over land, remember the highest game level
    local hs, top = {}, -1
    if role[ai] == "L" then
      top = val[ai] -- already fixed as a lower level by another cliff: keep it, write nothing on this side
    else
      for s = 0, R - 1 do
        local x, y = hx + dx * s, hy + dy * s
        if not inb(x, y) then break end
        local i = y * N + x
        if not LAND[i] then break end
        if role[i] ~= nil and role[i] ~= "H" then break end
        hs[#hs + 1] = i
        if GI[i] > top then top = GI[i] end
      end
    end
    -- low side: a water tile (coast) is level 0 and is not written; land: walk away, remember the lowest level
    local ls, bot = {}, nil
    if not LAND[bi] then
      bot = 0
      coastLow[bi] = true
    elseif role[bi] == "H" then
      bot = val[bi] -- already fixed as an upper level by another cliff: keep it, write nothing on this side
    else
      for s = 0, R - 1 do
        local x, y = lx - dx * s, ly - dy * s
        if not inb(x, y) then break end
        local i = y * N + x
        if not LAND[i] then break end
        if role[i] ~= nil and role[i] ~= "L" then break end
        ls[#ls + 1] = i
        if bot == nil or GI[i] < bot then bot = GI[i] end
      end
    end
    if #hs == 0 and role[ai] ~= "L" then C.conflictSkip = C.conflictSkip + 1; return end
    if bot == nil then C.noLow = C.noLow + 1; return end
    local raw = top - bot
    local hb = raw
    if hb < 0 then hb = 0 end
    if hb > 6 then hb = 6 end
    HIST[hb + 1] = HIST[hb + 1] + 1
    if raw < MING then C.flat = C.flat + 1; return end
    local d = raw
    if d > MAXD then d = MAXD; C.capped = C.capped + 1 end
    local hv = bot + d
    if WRITE then
      for _, i in ipairs(hs) do propose(i, "H", hv) end
      for _, i in ipairs(ls) do propose(i, "L", bot) end
    else
      -- walls-only mode: no height is written; remember the cliff edge so a wall can be put on the lower tile
      WALLEDGES[#WALLEDGES + 1] = { ai, bi }
      HIGHSET[ai] = true
      if EDGEDIR[bi] == nil then EDGEDIR[bi] = {} end
      for k = 1, 4 do
        if lx + DX[k] == hx and ly + DY[k] == hy then EDGEDIR[bi][k] = true end
      end
    end
  end

  for a, b, c, d in string.gmatch(EDGES, "(%d+),(%d+),(%d+),(%d+)") do
    handleEdge(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
  end
  local touchedLand = 0
  for i in pairs(hiSet) do if LAND[i] then touchedLand = touchedLand + 1 end end
  for i in pairs(loSet) do if LAND[i] and not hiSet[i] then touchedLand = touchedLand + 1 end end
  local ratio = 0
  if landCount > 0 then ratio = 100 * touchedLand / landCount end
  log("edges: n=" .. C.edges .. " highTiles=" .. hiN .. " lowTiles=" .. loN .. " cliffLand=" .. touchedLand .. "/" .. landCount .. " (" .. string.format("%.1f", ratio) .. "%)")
  log("edges: skipHighWater=" .. C.skipWater .. " belowMin(flat)=" .. C.flat .. " capped=" .. C.capped .. " noLow=" .. C.noLow .. " roleClashSkip=" .. C.conflictSkip .. " roleConflict=" .. C.conflict)
  log("edge game-drop histogram (top-bottom in game steps): 0:" .. HIST[1] .. " 1:" .. HIST[2] .. " 2:" .. HIST[3] .. " 3:" .. HIST[4] .. " 4:" .. HIST[5] .. " 5:" .. HIST[6] .. " 6+:" .. HIST[7])

  -- 3) write the flattened heights
  local written, setN, err, proposals = {}, 0, nil, 0
  for i in pairs(role) do
    proposals = proposals + 1
    local x = i % N
    local y = math.floor(i / N)
    local ok, e = pcall(function() Builder.setTerrainHeight(x, y, val[i]) end)
    if ok then setN = setN + 1; written[i] = true elseif not err then err = tostring(e) end
  end
  log("heights: proposals=" .. proposals .. " set=" .. setN .. (err and (" ERR " .. err) or ""))

  local function Hf(i)
    if written[i] then return val[i] end
    if LAND[i] then return GI[i] end
    return 0
  end

  -- live height of an unwritten tile (re-read from the game, falls back to the value read before writing)
  local function cur(ni)
    local v = gameH(ni % N, math.floor(ni / N))
    if v == nil then v = G[ni] end
    return v
  end

  -- diagnostic: how far does the game's own reshaping spread? Compare EVERY unwritten tile before / after the writes,
  -- grouped by (4-neighbour) distance from the nearest written tile; land tiles split into coastal / inland.
  local function spreadDiag(label, src)
    src = src or written
    local dist, queue, qh = {}, {}, 1
    for i in pairs(src) do dist[i] = 0; queue[#queue + 1] = i end
    while qh <= #queue do
      local i = queue[qh]
      qh = qh + 1
      local d = dist[i]
      if d < 12 then
        local x = i % N
        local y = math.floor(i / N)
        for k = 1, 4 do
          local nx, ny = x + DX[k], y + DY[k]
          if inb(nx, ny) then
            local ni = ny * N + nx
            if dist[ni] == nil then dist[ni] = d + 1; queue[#queue + 1] = ni end
          end
        end
      end
    end
    local tot, chg, totC, chgC, maxd = {}, {}, {}, {}, {}
    for d = 1, 13 do tot[d] = 0; chg[d] = 0; totC[d] = 0; chgC[d] = 0; maxd[d] = 0 end
    local waterChg, waterTot = 0, 0
    for i = 0, N * N - 1 do
      if not src[i] then
        local delta = math.abs(cur(i) - G0[i])
        local changed = delta >= 0.25
        if not LAND[i] then
          waterTot = waterTot + 1
          if changed then waterChg = waterChg + 1 end
        else
          local d = dist[i]
          if d == nil or d > 12 then d = 13 end
          if d >= 1 then
            local x = i % N
            local y = math.floor(i / N)
            local coastal = false
            for k = 1, 4 do
              local nx, ny = x + DX[k], y + DY[k]
              if inb(nx, ny) and not LAND[ny * N + nx] then coastal = true end
            end
            tot[d] = tot[d] + 1
            if coastal then totC[d] = totC[d] + 1 end
            if changed then
              chg[d] = chg[d] + 1
              if coastal then chgC[d] = chgC[d] + 1 end
              if delta > maxd[d] then maxd[d] = delta end
            end
          end
        end
      end
    end
    log(label .. " (unwritten land tiles, changed = |after-before| >= 0.25, by distance from written tiles)")
    for d = 1, 13 do
      if tot[d] > 0 then
        log("  dist " .. (d == 13 and "13+" or tostring(d)) .. ": changed=" .. chg[d] .. "/" .. tot[d] .. " coastal=" .. chgC[d] .. "/" .. totC[d] .. " inland=" .. (chg[d] - chgC[d]) .. "/" .. (tot[d] - totC[d]) .. " maxDelta=" .. string.format("%.2f", maxd[d]))
      end
    end
    log("  water tiles changed=" .. waterChg .. "/" .. waterTot)
  end

  -- diagnostic: does an unwritten slope tile beside a written (flat) tile change shape after the write?
  do
    local seen, tot, chg, ex = {}, 0, 0, {}
    for i in pairs(written) do
      local x = i % N
      local y = math.floor(i / N)
      for k = 1, 4 do
        local nx, ny = x + DX[k], y + DY[k]
        if inb(nx, ny) then
          local ni = ny * N + nx
          if (not written[ni]) and LAND[ni] and not seen[ni] then
            seen[ni] = true
            tot = tot + 1
            local c = cur(ni)
            if math.abs(c - G[ni]) >= 0.25 then
              chg = chg + 1
              if #ex < 6 then ex[#ex + 1] = nx .. "," .. ny .. " before=" .. string.format("%.2f", G[ni]) .. " after=" .. string.format("%.2f", c) end
            end
          end
        end
      end
    end
    log("neighbor adaptation after write: unwrittenNeighbors=" .. tot .. " changed(>=0.25)=" .. chg)
    for _, e in ipairs(ex) do log("adapt " .. e) end
  end

  spreadDiag("spread after first write")

  -- 2b) an unwritten slope tile beside a written (flat) tile that is lower than it by a step, or differs by a fraction (>= SLIV),
  --     cannot get a wall (building on a slope flattens it) and leaves a gap: write it flat at its own rounded height.
  --     Uses live readings, so if the game reshapes the neighbours by itself nothing more is written. At most ROUNDS rounds.
  local extraN = 0
  for rd = 1, ROUNDS do
    local add = {}
    for i in pairs(written) do
      local x = i % N
      local y = math.floor(i / N)
      local h = Hf(i)
      for k = 1, 4 do
        local nx, ny = x + DX[k], y + DY[k]
        if inb(nx, ny) then
          local ni = ny * N + nx
          if (not written[ni]) and LAND[ni] and add[ni] == nil then
            local c = cur(ni)
            local ci = round(c)
            if ci - h < 1 and math.abs(h - c) >= SLIV then add[ni] = ci end
          end
        end
      end
    end
    local cnt = 0
    for ni, v in pairs(add) do
      local x = ni % N
      local y = math.floor(ni / N)
      local ok, e = pcall(function() Builder.setTerrainHeight(x, y, v) end)
      if ok then written[ni] = true; val[ni] = v; cnt = cnt + 1; extraN = extraN + 1 elseif not err then err = tostring(e) end
    end
    log("flatten round " .. rd .. ": tiles=" .. cnt)
    if cnt == 0 then break end
  end

  -- refresh the heights of the unwritten tiles beside written ones (they may have been reshaped by the writes)
  for i in pairs(written) do
    local x = i % N
    local y = math.floor(i / N)
    for k = 1, 4 do
      local nx, ny = x + DX[k], y + DY[k]
      if inb(nx, ny) then
        local ni = ny * N + nx
        if (not written[ni]) and LAND[ni] then
          local c = cur(ni)
          G[ni] = c; GI[ni] = round(c)
        end
      end
    end
  end

  -- diagnostic: what is left (live readings): written tile vs unwritten slope tile, |diff| >= 0.25 and no wall possible
  local sliverLow, sliverHigh = 0, 0
  for i in pairs(written) do
    local x = i % N
    local y = math.floor(i / N)
    for k = 1, 4 do
      local nx, ny = x + DX[k], y + DY[k]
      if inb(nx, ny) then
        local ni = ny * N + nx
        if (not written[ni]) and LAND[ni] then
          local d = Hf(i) - G[ni]
          if d >= 0.25 then sliverLow = sliverLow + 1
          elseif d <= -0.25 and GI[ni] - Hf(i) < 1 then sliverHigh = sliverHigh + 1 end
        end
      end
    end
  end
  log("sliver steps left (live): slopeLower=" .. sliverLow .. " slopeHigher=" .. sliverHigh)
  spreadDiag("spread after flatten rounds")

  -- verify: read back every written tile
  local checked, mism, msamples = 0, 0, {}
  for i in pairs(written) do
    local r = gameH(i % N, math.floor(i / N))
    if r then
      checked = checked + 1
      if math.abs(r - val[i]) > 0.01 then
        mism = mism + 1
        if #msamples < 8 then msamples[#msamples + 1] = (i % N) .. "," .. math.floor(i / N) .. " want=" .. val[i] .. " game=" .. string.format("%.2f", r) end
      end
    end
  end
  log("verify after write: checked=" .. checked .. " (extra flattened=" .. extraN .. ") mismatch=" .. mism)
  for _, sm in ipairs(msamples) do log("mismatch " .. sm) end

  if proposals > 0 and setN == 0 then
    log("no heights were written: walls skipped")
    toast("cliffwall: no heights written, walls skipped")
    return
  end

  -- steps from a written tile down to an UNWRITTEN land tile cannot get a wall (building on a slope flattens it)
  local unwalled = 0
  for i in pairs(written) do
    local x = i % N
    local y = math.floor(i / N)
    for k = 1, 4 do
      local nx, ny = x + DX[k], y + DY[k]
      if inb(nx, ny) then
        local ni = ny * N + nx
        if (not written[ni]) and LAND[ni] and Hf(i) - Hf(ni) >= 1 then unwalled = unwalled + 1 end
      end
    end
  end

  -- 4) walls on the lower side of every step (written land tiles, and water tiles next to a cliff)
  for i in pairs(written) do
    if Hf(i) >= 1 then
      local x = i % N
      local y = math.floor(i / N)
      for k = 1, 4 do
        local nx, ny = x + DX[k], y + DY[k]
        if inb(nx, ny) then
          local ni = ny * N + nx
          if not LAND[ni] then coastLow[ni] = true end
        end
      end
    end
  end
  local cand = {}
  for i in pairs(written) do cand[i] = true end
  for i in pairs(coastLow) do cand[i] = true end
  for _, e in ipairs(WALLEDGES) do cand[e[2]] = true end
  local buildTrue, buildFalse, buildNil, buildErr, berr, droppedDirs, wallTiles = 0, 0, 0, 0, nil, 0, 0
  local PLANNED, BUILTOK, DROPPED = {}, {}, {}
  local falseSamples = 0
  for i in pairs(cand) do
    local x = i % N
    local y = math.floor(i / N)
    local h = Hf(i)
    local t = { 0, 0, 0, 0 }
    local nz = 0
    for k = 1, 4 do
      local nx, ny = x + DX[k], y + DY[k]
      if inb(nx, ny) then
        local ni = ny * N + nx
        local use = true
        if WRITE then
          if (not LAND[i]) and not written[ni] then use = false end
        else
          use = (EDGEDIR[i] ~= nil and EDGEDIR[i][k] == true)
        end
        if use then
          local diff = Hf(ni) - h
          if diff >= 1 then
            if diff > MAXD then diff = MAXD end
            t[k] = diff; nz = nz + 1
          end
        end
      end
    end
    local mx = math.max(t[1], t[2], t[3], t[4])
    if nz > 2 and mx > 3 then
      local order = { 1, 2, 3, 4 }
      table.sort(order, function(a, b)
        if t[a] ~= t[b] then return t[a] > t[b] end
        return a < b
      end)
      local dr = {}
      if t[order[3]] > 0 then dr[order[3]] = true end
      if t[order[4]] > 0 then dr[order[4]] = true end
      DROPPED[i] = dr
      t[order[3]] = 0; t[order[4]] = 0
      droppedDirs = droppedDirs + 1
      nz = 2
    end
    if nz > 0 then
      wallTiles = wallTiles + 1
      local coast = not LAND[i]
      local id = PID .. "_" .. t[1] .. t[2] .. t[3] .. t[4] .. (coast and "c" or "i")
      PLANNED[i] = { t[1], t[2], t[3], t[4], id }
      local ok, res = pcall(function() return Builder.buildBuilding(id, x, y, 0) end)
      if ok and res == true then
        buildTrue = buildTrue + 1; BUILTOK[i] = true
      elseif ok and res == false then
        buildFalse = buildFalse + 1
        if falseSamples < 6 then
          falseSamples = falseSamples + 1
          local okQ, q = pcall(function() return Builder.isBuildingBuildable(id, x, y) end)
          log("buildBuilding returned false: id=" .. id .. " at " .. x .. "," .. y .. " isBuildingBuildable=" .. tostring(okQ and q))
        end
      elseif ok then
        buildNil = buildNil + 1
      else
        buildErr = buildErr + 1
        if not berr then berr = tostring(res) .. " id=" .. id end
      end
    end
  end
  -- v13-14 plan A: cover every remaining flat-flat step on land with a wall on the lower tile
  local extraTiles, extraTrue, extraFalse, extraDrop, juncDirs = 0, 0, 0, 0, 0
  if WRITE and EXTRA then
    local LH2, FL2 = {}, {}
    for i = 0, N * N - 1 do
      local x = i % N
      local y = math.floor(i / N)
      LH2[i] = cur(i)
      local okF, f = pcall(function() return Tile.isFlat(x, y) end)
      if okF then FL2[i] = f else FL2[i] = math.abs(LH2[i] - round(LH2[i])) < 0.001 end
    end
    for i = 0, N * N - 1 do
      if LAND[i] and FL2[i] and PLANNED[i] == nil then
        local x = i % N
        local y = math.floor(i / N)
        local t = { 0, 0, 0, 0 }
        local nz = 0
        for k = 1, 4 do
          local nx, ny = x + DX[k], y + DY[k]
          if inb(nx, ny) then
            local ni = ny * N + nx
            if FL2[ni] then
              local diff = round(LH2[ni]) - round(LH2[i])
              if diff >= 1 then
                if diff > MAXD then diff = MAXD end
                t[k] = diff
                nz = nz + 1
              end
            elseif JUNC and LAND[ni] then
              local dd = LH2[ni] - LH2[i]
              if dd >= 0.5 then
                local jd = round(dd)
                if jd < 1 then jd = 1 end
                if jd > 3 then jd = 3 end
                t[k] = jd
                nz = nz + 1
                juncDirs = juncDirs + 1
              end
            end
          end
        end
        local mx = math.max(t[1], t[2], t[3], t[4])
        if nz > 2 and mx > 3 then
          local order = { 1, 2, 3, 4 }
          table.sort(order, function(a, b)
            if t[a] ~= t[b] then return t[a] > t[b] end
            return a < b
          end)
          local dr = {}
          if t[order[3]] > 0 then dr[order[3]] = true end
          if t[order[4]] > 0 then dr[order[4]] = true end
          DROPPED[i] = dr
          t[order[3]] = 0
          t[order[4]] = 0
          droppedDirs = droppedDirs + 1
          extraDrop = extraDrop + 1
          nz = 2
        end
        if nz > 0 then
          wallTiles = wallTiles + 1
          extraTiles = extraTiles + 1
          local id = PID .. "_" .. t[1] .. t[2] .. t[3] .. t[4] .. "i"
          PLANNED[i] = { t[1], t[2], t[3], t[4], id }
          local ok, res = pcall(function() return Builder.buildBuilding(id, x, y, 0) end)
          if ok and res == true then
            buildTrue = buildTrue + 1
            extraTrue = extraTrue + 1
            BUILTOK[i] = true
          elseif ok and res == false then
            buildFalse = buildFalse + 1
            extraFalse = extraFalse + 1
          elseif ok then
            buildNil = buildNil + 1
          else
            buildErr = buildErr + 1
            if not berr then berr = tostring(res) .. " id=" .. id end
          end
        end
      end
    end
  end
  log("extra walls (plan A): tiles=" .. extraTiles .. " buildTrue=" .. extraTrue .. " buildFalse=" .. extraFalse .. " droppedExtraDirs=" .. extraDrop)
  log("junction walls (flat vs slope): dirs=" .. juncDirs .. " enabled=" .. tostring(JUNC))
  spreadDiag("spread after walls (distance from wall tiles)", PLANNED)
  log("walls: tiles=" .. wallTiles .. " buildTrue=" .. buildTrue .. " buildFalse=" .. buildFalse .. " buildNil=" .. buildNil .. " error=" .. buildErr .. " droppedExtraDirs=" .. droppedDirs .. " unwalledStepsToSlope=" .. unwalled .. (berr and (" ERR " .. berr) or ""))

  -- read back: is there really a building on every planned wall tile, and is it the planned draft?
  do
    local present, match, known, samples = 0, 0, 0, 0
    for i, pl in pairs(PLANNED) do
      local x = i % N
      local y = math.floor(i / N)
      local okB, isB = pcall(function() return Tile.isBuilding(x, y) end)
      if okB and isB then
        present = present + 1
        local okD, got = pcall(function()
          local d = Tile.getBuildingDraft(x, y)
          if d == nil then return nil end
          local okI, idv = pcall(function() return d:getId() end)
          if okI and idv then return idv end
          return tostring(d)
        end)
        if okD and type(got) == "string" then
          if string.sub(got, 1, #PID) == PID then known = known + 1 end
          if got == pl[5] then
            match = match + 1
          elseif samples < 6 then
            samples = samples + 1
            log("readback mismatch (" .. x .. "," .. y .. ") want=" .. pl[5] .. " got=" .. got)
          end
        end
      end
    end
    log("readback: planned=" .. wallTiles .. " isBuilding=" .. present .. " idMatch=" .. match .. " idStartsWithPlugin=" .. known)
  end

  -- final audit: every pair of neighbouring tiles that are both flat and differ by >= 1 step needs a wall on the lower tile
  do
    local LH, FL = {}, {}
    for i = 0, N * N - 1 do
      local x = i % N
      local y = math.floor(i / N)
      LH[i] = cur(i)
      local okF, f = pcall(function() return Tile.isFlat(x, y) end)
      if okF then FL[i] = f else FL[i] = math.abs(LH[i] - round(LH[i])) < 0.001 end
    end
    local OPP = { 3, 4, 1, 2 }
    local steps, covered, gapSlope, shore = 0, 0, 0, 0
    local why = { noWall = 0, dirDropped = 0, planZero = 0, buildFailed = 0, dropMismatch = 0 }
    local samples = {}
    local gapSamples = {}
    local NWD, NWW, NWZ, NWMARK, samples2 = {}, {}, 0, {}, {}
    for i = 0, N * N - 1 do
      local x = i % N
      local y = math.floor(i / N)
      for k = 3, 4 do
        local nx, ny = x + DX[k], y + DY[k]
        if inb(nx, ny) then
          local ni = ny * N + nx
          if FL[i] and FL[ni] then
            local diff = round(LH[ni]) - round(LH[i])
            if diff ~= 0 then
              steps = steps + 1
              local L, H, kd, dabs
              if diff > 0 then L = i; H = ni; kd = k; dabs = diff else L = ni; H = i; kd = OPP[k]; dabs = -diff end
              local pl = PLANNED[L]
              local reason = nil
              if pl == nil then reason = "noWall"
              elseif DROPPED[L] and DROPPED[L][kd] then reason = "dirDropped"
              elseif pl[kd] == 0 then reason = "planZero"
              elseif not BUILTOK[L] then reason = "buildFailed"
              else
                local want = dabs
                if want > MAXD then want = MAXD end
                if pl[kd] ~= want then reason = "dropMismatch" end
              end
              if reason == nil then
                covered = covered + 1
              elseif reason == "noWall" and not LAND[L] then
                shore = shore + 1
              else
                why[reason] = why[reason] + 1
                if reason == "noWall" then
                  local dk = dabs
                  if dk > 6 then dk = 6 end
                  NWD[dk] = (NWD[dk] or 0) + 1
                  local wc = (written[L] == true and 1 or 0) + (written[H] == true and 1 or 0)
                  NWW[wc] = (NWW[wc] or 0) + 1
                  if LH[L] < 0.5 then NWZ = NWZ + 1 end
                  NWMARK[L] = true
                  if #samples2 < 30 then
                    samples2[#samples2 + 1] = "L(" .. (L % N) .. "," .. math.floor(L / N) .. ") h=" .. string.format("%.1f", LH[L]) .. " -> H(" .. (H % N) .. "," .. math.floor(H / N) .. ") h=" .. string.format("%.1f", LH[H]) .. " d=" .. dabs .. " writtenL=" .. tostring(written[L] == true) .. " writtenH=" .. tostring(written[H] == true)
                  end
                end
                if reason == "noWall" and #samples < 6 then
                  samples[#samples + 1] = "L(" .. (L % N) .. "," .. math.floor(L / N) .. ") h=" .. string.format("%.1f", LH[L]) .. " written=" .. tostring(written[L] == true) .. " -> H(" .. (H % N) .. "," .. math.floor(H / N) .. ") h=" .. string.format("%.1f", LH[H])
                end
              end
            end
          elseif (FL[i] or FL[ni]) and math.abs(LH[i] - LH[ni]) >= 0.5 then
            gapSlope = gapSlope + 1
            if #gapSamples < 14 then
              local function cs(px, py)
                local r = {}
                for _, c in ipairs({ { px, py }, { px + 1, py }, { px, py + 1 }, { px + 1, py + 1 } }) do
                  local okC, v = pcall(function() return Tile.getCornerTerrainHeight(c[1], c[2]) end)
                  r[#r + 1] = okC and tostring(v) or "?"
                end
                return table.concat(r, ",")
              end
              gapSamples[#gapSamples + 1] = "A(" .. x .. "," .. y .. ") flat=" .. tostring(FL[i]) .. " h=" .. string.format("%.2f", LH[i]) .. " corners[" .. cs(x, y) .. "] | B(" .. nx .. "," .. ny .. ") flat=" .. tostring(FL[ni]) .. " h=" .. string.format("%.2f", LH[ni]) .. " corners[" .. cs(nx, ny) .. "]"
            end
          end
        end
      end
    end
    log("final audit: flatFlatSteps=" .. steps .. " covered=" .. covered .. " noWall(land)=" .. why.noWall .. " shoreline(water->land, not counted as a gap)=" .. shore .. " dirDropped=" .. why.dirDropped .. " planZero=" .. why.planZero .. " buildFailed=" .. why.buildFailed .. " dropMismatch=" .. why.dropMismatch .. " | flat-vs-slope gap>=0.5: " .. gapSlope)
    for _, sm in ipairs(samples) do log("audit noWall " .. sm) end
    for _, g in ipairs(gapSamples) do log("slopeGap " .. g) end
    local ds = {}
    for d = 1, 6 do ds[#ds + 1] = d .. ":" .. (NWD[d] or 0) end
    log("noWall diff histogram (steps, 6 = 6 or more): " .. table.concat(ds, " "))
    log("noWall by written flags: neitherWritten=" .. (NWW[0] or 0) .. " oneWritten=" .. (NWW[1] or 0) .. " bothWritten=" .. (NWW[2] or 0) .. " | lowTileAtSeaLevel(<0.5)=" .. NWZ)
    for _, sm in ipairs(samples2) do log("audit noWall2 " .. sm) end
    log("map legend: . water  , land  W wall  n noWall step (low tile)  | one line per row y, x = 0..N-1")
    for y = 0, N - 1 do
      local row = {}
      for x = 0, N - 1 do
        local i = y * N + x
        local ch = ","
        if not LAND[i] then ch = "." elseif BUILTOK[i] then ch = "W" elseif NWMARK[i] then ch = "n" end
        row[#row + 1] = ch
      end
      log("map " .. string.format("%02d", y) .. " " .. table.concat(row))
    end
  end
  if type(store) == "table" and setN > 0 then
    local okF = pcall(function() store.cliffwall_done = PID end)
    log("storage flag set: " .. tostring(okF))
  end
  toast("cliffwall: heights " .. setN .. " / walls " .. buildTrue)
end

function script:enterCity() apply() end
function script:update() apply() end
