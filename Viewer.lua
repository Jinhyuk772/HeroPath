-- Hero's Path · Viewer: 월드맵과 별개인 독립 창
-- · 월드맵 타일(C_Map.GetMapArtLayerTextures)을 직접 깔고 그 위에 선(Line 텍스처)을 그린다 → 확대 · 축소해도 에셋과 정합
-- · 마우스 휠 = 커서 중심 확대/축소, 드래그 = 이동, 슬라이더 = 시간, 재생 속도 1x~30m/s, 공백 건너뜀
-- · 다른 지도에서 찍힌 점은 월드 좌표를 거쳐 보는 지도 위로 변환 (대륙 지도에 지역 발자취, 던전 층 지도 등)
local NS = select(2, ...)
local V = {}
NS.Viewer = V

local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local MAX_LINES = 2500
local MAX_MARKERS = 400
local LINE_W = 3
local SPEEDS = { 1, 10, 60, 300, 1800 }
local EVENT_ICON = {
  DEATH    = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", size = 22, label = "사망" },
  LEVEL    = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", size = 18, label = "레벨업" },
  LOGIN    = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4", size = 14, label = "로그인" },
  LOGOUT   = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2", size = 14, label = "로그아웃" },
  INST_IN  = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", size = 18, label = "던전 입장" },
  INST_OUT = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", size = 14, label = "던전 퇴장" },
  QUEST    = { tex = "Interface\\GossipFrame\\ActiveQuestIcon", size = 14, label = "퀘스트 완료" },
  HEARTH   = { tex = "Interface\\Icons\\INV_Misc_Rune_01", size = 16, label = "귀환석" },
  TAXI_ON  = { tex = "Interface\\TaxiFrame\\UI-Taxi-Icon-Green", size = 16, label = "비행 출발" },
  BOSS     = { tex = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull", size = 20, label = "보스 처치" },
  KILL     = { tex = "Interface\\TargetingFrame\\UI-TargetingFrame-Rare", size = 18, label = "희귀 처치" },
  FIRST    = { tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6", size = 12, label = "첫 방문" },
  GOLD     = { tex = "Interface\\Icons\\INV_Misc_Coin_01", size = 14, label = "골드" },
}

local F, VP, CV                   -- 창 · 뷰포트 · 캔버스
local st = {                      -- 보기 상태
  charKey = nil,                  -- nil = 모두
  viewMap = nil,
  range = "all",                  -- all · today · week · {세션}
  T = 0, tMin = 0, tMax = 0,
  playing = false, speed = 60, live = false, skipIdle = true,
  zoom = 1, zmin = 0.1, zmax = 12, px = 0, py = 0,
  follow = false, showEvents = true, stride = 1,
}
local layer = { W = 1002, H = 668, tiles = nil, tw = 256, th = 256, cols = 0 }
local tracks = {}                 -- {sess, who, color, cache, taken, lastIdx, evIdx}
local lines, nLines = {}, 0       -- 선 풀 · 쓰는 개수
local lineData = {}               -- i → {x1, y1, x2, y2} (캔버스 단위, 확대 전)
local markers, nMarkers = {}, 0
local heads = {}
local tileTex = {}
local dropdowns = {}
local projCache = setmetatable({}, { __mode = "k" })  -- 세션 → {[viewMap] = {cx, cy, n}}
local GAP = 180

---------------------------------------------------------------- 지도 타일
local function loadLayer(map)
  layer.tiles = nil
  if not (C_Map and C_Map.GetMapArtLayers) then return false end
  local ok, L = pcall(C_Map.GetMapArtLayers, map)
  if not ok or not L or #L == 0 then return false end
  local best, bi = nil, 1
  for i, l in ipairs(L) do
    if not best or (l.layerWidth or 0) > (best.layerWidth or 0) then best, bi = l, i end
  end
  local ok2, tex = pcall(C_Map.GetMapArtLayerTextures, map, bi)
  if not ok2 or not tex or #tex == 0 then return false end
  layer.W, layer.H = best.layerWidth, best.layerHeight
  layer.tw, layer.th = best.tileWidth, best.tileHeight
  layer.cols = ceil(layer.W / layer.tw)
  layer.tiles = tex
  return true
end

local function layoutTiles()
  for _, t in ipairs(tileTex) do t:Hide() end
  if not layer.tiles then return end
  local z = st.zoom
  for i, file in ipairs(layer.tiles) do
    local t = tileTex[i]
    if not t then
      t = CV:CreateTexture(nil, "BACKGROUND")
      tileTex[i] = t
    end
    local r, c = floor((i - 1) / layer.cols), (i - 1) % layer.cols
    t:ClearAllPoints()
    t:SetSize(layer.tw * z, layer.th * z)
    t:SetPoint("TOPLEFT", CV, "TOPLEFT", c * layer.tw * z, -r * layer.th * z)
    t:SetTexture(file)
    t:Show()
  end
end

---------------------------------------------------------------- 좌표 변환 (기록 지도 → 보는 지도, 캔버스 단위)
local function project(map, x, y, viewMap)
  if map == viewMap then return x / 10000 * layer.W, y / 10000 * layer.H end
  if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
  local ok, cont, wpos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x / 10000, y / 10000))
  if not ok or not wpos then return nil end
  -- 클라이언트마다 (위치) 또는 (지도ID, 위치) 를 돌려줌
  local ok2, r1, r2 = pcall(C_Map.GetMapPosFromWorldPos, cont, wpos, viewMap)
  if not ok2 then return nil end
  local mpos = (type(r1) == "table" or type(r1) == "userdata") and r1 or r2
  if type(mpos) ~= "table" and type(mpos) ~= "userdata" then return nil end
  local mx, my
  if mpos.GetXY then mx, my = mpos:GetXY() else mx, my = mpos.x, mpos.y end
  if not mx or mx < -0.02 or mx > 1.02 or my < -0.02 or my > 1.02 then return nil end
  return mx * layer.W, my * layer.H
end

-- 세션의 점을 보는 지도 좌표로 (끝까지 또는 새로 늘어난 만큼). cx[i] = false 면 이 지도에 없음
local function ensureProjected(sess, viewMap)
  local pc = projCache[sess]
  if not pc then pc = {} projCache[sess] = pc end
  local c = pc[viewMap]
  if not c then c = { cx = {}, cy = {}, n = 0 } pc[viewMap] = c end
  local n = sess.n or 0
  if c.n >= n then return c end
  local m, X, Y = sess.m, sess.x, sess.y
  local cx, cy = c.cx, c.cy
  for i = c.n + 1, n do
    local ok, px, py = pcall(project, m[i], X[i], Y[i], viewMap)
    if ok and px then cx[i], cy[i] = px, py else cx[i] = false end
  end
  c.n = n
  return c
end

---------------------------------------------------------------- 선 · 표식 풀
local function getLine(i)
  local l = lines[i]
  if not l then
    l = CV:CreateLine(nil, "ARTWORK")
    l:SetThickness(LINE_W)
    lines[i] = l
  end
  return l
end

local function placeLine(i)
  local d, l, z = lineData[i], lines[i], st.zoom
  l:SetStartPoint("TOPLEFT", CV, d[1] * z, -d[2] * z)
  l:SetEndPoint("TOPLEFT", CV, d[3] * z, -d[4] * z)
end

local function addLine(x1, y1, x2, y2, color, alpha)
  if nLines >= MAX_LINES then return end
  nLines = nLines + 1
  local d = lineData[nLines]
  if not d then d = {} lineData[nLines] = d end
  d[1], d[2], d[3], d[4] = x1, y1, x2, y2
  local l = getLine(nLines)
  l:SetColorTexture(color[1], color[2], color[3], alpha or 0.9)
  placeLine(nLines)
  l:Show()
end

local function clearLines()
  for i = 1, nLines do lines[i]:Hide() end
  nLines = 0
end

local function markerTip(self)
  local e = self.ev
  if not e or not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local info = EVENT_ICON[e.k] or { label = e.k }
  GameTooltip:AddLine(info.label, 1, 0.9, 0.5)
  GameTooltip:AddLine(self.who, 0.7, 0.9, 1)
  GameTooltip:AddLine(NS.fmtClock(self.abs), 0.8, 0.8, 0.8)
  if e.k == "DEATH" then
    if e.by then GameTooltip:AddLine("죽인 것: " .. e.by, 1, 0.5, 0.5) end
    if e.lvl then GameTooltip:AddLine("레벨 " .. e.lvl, 0.9, 0.9, 0.9) end
    if e.zone then GameTooltip:AddLine((e.zone or "") .. ((e.sub and e.sub ~= "") and (" - " .. e.sub) or ""), 0.9, 0.9, 0.9) end
  elseif e.k == "LEVEL" then
    GameTooltip:AddLine("레벨 " .. tostring(e.lvl), 1, 1, 0.6)
  elseif e.k == "INST_IN" or e.k == "INST_OUT" then
    if e.name then GameTooltip:AddLine(e.name, 0.9, 0.9, 0.9) end
    if e.dur then GameTooltip:AddLine("머문 시간 " .. NS.fmtDur(e.dur), 0.9, 0.9, 0.9) end
    if e.log and #e.log > 0 then
      GameTooltip:AddLine(" ")
      for i = 1, math.min(#e.log, 14) do
        local l = e.log[i]
        GameTooltip:AddLine(("|cff9a9a9a%s|r  %s"):format(NS.fmtDur(l.t - e.t), l.s), 0.85, 0.85, 0.85)
      end
      if #e.log > 14 then GameTooltip:AddLine("... " .. (#e.log - 14) .. "건 더", 0.6, 0.6, 0.6) end
    end
  elseif e.k == "BOSS" then
    GameTooltip:AddLine((e.name or "") .. (e.ok == false and " (실패)" or ""), 0.9, 0.9, 0.9)
  elseif e.k == "KILL" then
    GameTooltip:AddLine((e.name or "") .. (e.lvl and (" (레벨 " .. e.lvl .. ")") or ""), 0.9, 0.9, 0.9)
    if e.cls then GameTooltip:AddLine(e.cls == "worldboss" and "월드 보스" or (e.cls == "rareelite" and "희귀 정예" or "희귀"), 0.7, 0.7, 0.7) end
  elseif e.k == "FIRST" then
    GameTooltip:AddLine(e.name or "", 0.9, 0.9, 0.9)
  elseif e.k == "GOLD" then
    GameTooltip:AddLine((e.delta >= 0 and "+" or "-") .. NS.fmtMoney(e.delta) .. "  (" .. (e.how or "") .. ")", e.delta >= 0 and 0.6 or 1, e.delta >= 0 and 1 or 0.6, 0.6)
    if e.total then GameTooltip:AddLine("보유 " .. NS.fmtMoney(e.total), 0.7, 0.7, 0.7) end
  elseif e.k == "QUEST" then
    GameTooltip:AddLine(e.title or ("퀘스트 " .. tostring(e.id)), 0.9, 0.9, 0.9)
  elseif e.k == "HEARTH" then
    if e.dest then GameTooltip:AddLine("-> " .. e.dest, 0.9, 0.9, 0.9) end
  elseif e.k == "LOGIN" or e.k == "LOGOUT" or e.k == "TAXI_ON" then
    if e.zone then GameTooltip:AddLine(e.zone, 0.9, 0.9, 0.9) end
  end
  GameTooltip:Show()
end

local function getMarker(i)
  local b = markers[i]
  if not b then
    b = CreateFrame("Button", nil, CV)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetAllPoints(b)
    b:SetScript("OnEnter", markerTip)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:EnableMouseWheel(true)
    b:SetScript("OnMouseWheel", function(_, d) if VP.wheel then VP.wheel(VP, d) end end)
    markers[i] = b
  end
  return b
end

local function placeMarker(b)
  local z = st.zoom
  b:ClearAllPoints()
  b:SetPoint("CENTER", CV, "TOPLEFT", b.cx * z, -b.cy * z)
end

local function addMarker(e, cx, cy, who, absT)
  if nMarkers >= MAX_MARKERS then return end
  local info = EVENT_ICON[e.k]
  if not info then return end
  nMarkers = nMarkers + 1
  local b = getMarker(nMarkers)
  b.ev, b.who, b.abs, b.cx, b.cy = e, who, absT, cx, cy
  b:SetSize(info.size, info.size)
  b.tex:SetTexture(info.tex)
  b:SetFrameLevel(CV:GetFrameLevel() + 5)
  placeMarker(b)
  b:Show()
end

local function clearMarkers()
  for i = 1, nMarkers do markers[i]:Hide() end
  nMarkers = 0
end

---------------------------------------------------------------- 자료 모으기
local function sessInRange(s)
  local r = st.range
  if r == "all" then return true end
  local stop = s.stop or GetServerTime()
  if r == "today" then
    local d = date("*t")
    d.hour, d.min, d.sec = 0, 0, 0
    return stop >= time(d)
  elseif r == "week" then
    return stop >= GetServerTime() - 7 * 86400
  elseif type(r) == "table" then
    return s == r
  end
  return true
end

local function buildTracks()
  tracks = {}
  st.tMin, st.tMax = nil, nil
  for key, c in pairs(NS.db.chars) do
    if not st.charKey or st.charKey == key then
      local color = NS.charColor(c)
      for _, s in ipairs(c.sessions) do
        if (s.n or 0) > 0 and sessInRange(s) then
          local tr = { sess = s, who = c.name, color = color, taken = 0, lastIdx = 0, evIdx = 0 }
          tracks[#tracks + 1] = tr
          local a = s.start + s.t[1]
          local b = s.start + s.t[s.n]
          if s.stop then b = max(b, s.stop) end
          if not st.tMin or a < st.tMin then st.tMin = a end
          if not st.tMax or b > st.tMax then st.tMax = b end
        end
      end
    end
  end
  table.sort(tracks, function(a, b) return a.sess.start < b.sess.start end)
  st.tMin = st.tMin or GetServerTime()
  st.tMax = st.tMax or st.tMin
end

local function totalPoints()
  local n = 0
  for _, tr in ipairs(tracks) do n = n + (tr.sess.n or 0) end
  return n
end

-- 지도 후보: 자료가 있는 지도 + 그 부모(대륙) 들
local function mapChoices()
  local seen, out = {}, {}
  local function add(map, depth)
    if not map or seen[map] or depth > 4 then return end
    seen[map] = true
    local ok, info = pcall(C_Map.GetMapInfo, map)
    if not ok or not info then return end
    if info.mapType and info.mapType >= 2 then  -- 대륙(2) 지역(3) 던전(4) 소지도(5) 고아(6)
      out[#out + 1] = { map = map, name = info.name or ("지도 " .. map), type = info.mapType }
    end
    if info.parentMapID and info.parentMapID > 0 and info.mapType and info.mapType > 2 then add(info.parentMapID, depth + 1) end
  end
  for _, tr in ipairs(tracks) do
    local s = tr.sess
    local last
    for i = 1, s.n do
      if s.m[i] ~= last then last = s.m[i] add(last, 0) end
    end
  end
  table.sort(out, function(a, b)
    if a.type ~= b.type then return a.type < b.type end
    return a.name < b.name
  end)
  return out
end

---------------------------------------------------------------- 그리기
local function resetDraw()
  clearLines()
  clearMarkers()
  for _, h in ipairs(heads) do h:Hide() end
  GAP = NS.db.settings.gapSeconds or 180
  local total = totalPoints()
  st.stride = max(1, ceil(total / MAX_LINES))
  for _, tr in ipairs(tracks) do
    tr.taken, tr.lastIdx, tr.evIdx = 0, 0, 0
    tr.cache = ensureProjected(tr.sess, st.viewMap)
  end
end

-- 트랙의 점을 시각 T 까지 더 그린다 (늘어난 만큼만)
local function advanceTrack(tr, T)
  local s = tr.sess
  local c = tr.cache
  if c.n < (s.n or 0) then c = ensureProjected(s, st.viewMap) tr.cache = c end
  local cx, cy, t, fl = c.cx, c.cy, s.t, s.fl
  local rel = T - s.start
  local i = tr.lastIdx + 1
  local n = s.n
  local stride = st.stride
  while i <= n and t[i] <= rel do
    local here = cx[i]
    local prev = tr.taken
    local brk = (prev == 0) or (not here) or (not cx[prev]) or (t[i] - t[prev] > GAP + stride * 10)
    local pick = brk or (i - prev >= stride) or (i == n) or (fl[i] ~= fl[prev])
    if pick then
      if here and not brk and prev > 0 then
        local f = fl[i] or fl[prev]
        local alpha = (f == 1) and 0.45 or ((f == 2) and 0.5 or 0.9)
        local col = (f == 2) and { 0.75, 0.75, 0.75 } or tr.color
        addLine(cx[prev], cy[prev], here, cy[i], col, alpha)
      end
      tr.taken = i
    end
    tr.lastIdx = i
    i = i + 1
  end
  -- 사건
  if st.showEvents then
    local ev = s.ev
    local j = tr.evIdx + 1
    while j <= #ev and ev[j].t <= rel do
      local e = ev[j]
      local idx = e.i
      if idx and idx >= 1 and idx <= c.n and cx[idx] then
        addMarker(e, cx[idx], cy[idx], tr.who, s.start + e.t)
      end
      tr.evIdx = j
      j = j + 1
    end
  end
end

local function headPos(tr, T)
  local s, c = tr.sess, tr.cache
  local i = tr.lastIdx
  if i < 1 then return nil end
  local rel = T - s.start
  local cx, cy, t = c.cx, c.cy, s.t
  if not cx[i] then return nil end
  if i < s.n and cx[i + 1] and (t[i + 1] - t[i]) <= GAP then
    local f = (rel - t[i]) / max(1, t[i + 1] - t[i])
    if f > 1 then f = 1 elseif f < 0 then f = 0 end
    local x = cx[i] + (cx[i + 1] - cx[i]) * f
    local y = cy[i] + (cy[i + 1] - cy[i]) * f
    return x, y, cx[i + 1] - cx[i], cy[i + 1] - cy[i], false
  end
  -- 마지막 점에 머묾 (로그아웃 뒤면 흐리게)
  local idle = (rel - t[i]) > GAP
  local dx, dy = 0, -1
  if i > 1 and cx[i - 1] then dx, dy = cx[i] - cx[i - 1], cy[i] - cy[i - 1] end
  return cx[i], cy[i], dx, dy, idle
end

local function getHead(k)
  local h = heads[k]
  if not h then
    h = CreateFrame("Frame", nil, CV)
    h:SetSize(26, 26)
    h.tex = h:CreateTexture(nil, "OVERLAY", nil, 7)
    h.tex:SetAllPoints(h)
    h.tex:SetTexture("Interface\\Minimap\\MinimapArrow")
    h.name = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.name:SetPoint("BOTTOM", h, "TOP", 0, 1)
    heads[k] = h
  end
  return h
end

-- 캐릭터마다 머리는 하나: 시각 T 기준으로 가장 최근 점을 가진 세션만
local function pickHeads(T)
  local best = {}
  for _, tr in ipairs(tracks) do
    local i = tr.lastIdx
    if i >= 1 then
      local at = tr.sess.start + tr.sess.t[i]
      local b = best[tr.who]
      if not b or at > b.at then best[tr.who] = { tr = tr, at = at } end
    end
  end
  local out = {}
  for _, b in pairs(best) do out[#out + 1] = b.tr end
  table.sort(out, function(a, b) return a.who < b.who end)
  return out
end

local function drawHeads(T)
  local k = 0
  local fx, fy, fn = 0, 0, 0
  for _, tr in ipairs(pickHeads(T)) do
    local x, y, dx, dy, idle = headPos(tr, T)
    if x then
      k = k + 1
      local h = getHead(k)
      h:SetFrameLevel(CV:GetFrameLevel() + 8)
      h:ClearAllPoints()
      h:SetPoint("CENTER", CV, "TOPLEFT", x * st.zoom, -y * st.zoom)
      if dx ~= 0 or dy ~= 0 then h.tex:SetRotation(-math.atan2(dx, -dy)) end
      h.tex:SetVertexColor(tr.color[1], tr.color[2], tr.color[3])
      h:SetAlpha(idle and 0.35 or 1)
      h.name:SetText(tr.who)
      h.name:SetTextColor(tr.color[1], tr.color[2], tr.color[3])
      h:Show()
      if not idle then fx, fy, fn = fx + x, fy + y, fn + 1 end
    end
  end
  for i = k + 1, #heads do heads[i]:Hide() end
  if fn > 0 then return fx / fn, fy / fn end
end

local function relayout()
  layoutTiles()
  for i = 1, nLines do placeLine(i) end
  for i = 1, nMarkers do placeMarker(markers[i]) end
end

local function applyPan()
  if not VP or not CV then return end
  local vw, vh = VP:GetWidth(), VP:GetHeight()
  local cw, ch = layer.W * st.zoom, layer.H * st.zoom
  -- 지도가 화면에서 완전히 사라지지 않게
  st.px = min(max(st.px, vw * 0.2 - cw), vw * 0.8)
  st.py = min(max(st.py, vh * 0.2 - ch), vh * 0.8)
  CV:ClearAllPoints()
  CV:SetSize(max(1, cw), max(1, ch))
  CV:SetPoint("TOPLEFT", VP, "TOPLEFT", st.px, -st.py)
end

local function fitZoom()
  local vw, vh = VP:GetWidth(), VP:GetHeight()
  if vw < 10 or vh < 10 then return end
  st.zmin = min(vw / layer.W, vh / layer.H) * 0.98
  st.zmax = max(st.zmin * 20, 12)
end

local function centerOn(cx, cy)
  st.px = VP:GetWidth() / 2 - cx * st.zoom
  st.py = VP:GetHeight() / 2 - cy * st.zoom
  applyPan()
end

local function updateTimeUI()
  if not F then return end
  local span = st.tMax - st.tMin
  if F.slider and not F.slider.dragging then
    F.sliderBusy = true
    F.slider:SetValue(span > 0 and ((st.T - st.tMin) / span * 1000) or 0)
    F.sliderBusy = false
  end
  F.timeText:SetText(NS.fmtClock(st.T) .. "   |cffa0a0a0" .. NS.fmtDur(st.T - st.tMin) .. " / " .. NS.fmtDur(span) .. "|r")
  F.zoomText:SetText(("x%.2f"):format(st.zoom / max(st.zmin, 0.0001)))
  F.play:SetText(st.playing and "||" or ">")
  F.liveBtn:SetAlpha(st.live and 1 or 0.6)
end

local function drawToRaw(T, full)
  if full or T < st.T then resetDraw() end
  st.T = T
  for _, tr in ipairs(tracks) do
    if not NS.safe("선 그리기 " .. NS.fmtShort(tr.sess.start), advanceTrack, tr, T) then tr.lastIdx = tr.sess.n end
  end
  local hx, hy = drawHeads(T)
  if st.follow and hx then centerOn(hx, hy) end
end

local function drawTo(T, full)
  NS.safe("그리기", drawToRaw, T, full)
  NS.safe("시간 표시", updateTimeUI)
end

local function seek(T)
  if T < st.tMin then T = st.tMin end
  if T > st.tMax then T = st.tMax end
  drawTo(T, T < st.T)
end

-- 다음 점이 있는 시각 (공백 건너뛰기)
local function nextPointTime()
  local best
  for _, tr in ipairs(tracks) do
    local s = tr.sess
    local i = tr.lastIdx + 1
    if i <= s.n then
      local a = s.start + s.t[i]
      if not best or a < best then best = a end
    end
  end
  return best
end

---------------------------------------------------------------- 지도 바꾸기 · 범위 바꾸기
local function setViewMap(map, keepView)
  if not map then return end
  st.viewMap = map
  NS.db.settings.lastMap = map
  if not loadLayer(map) then
    layer.W, layer.H, layer.tiles = 1002, 668, nil
  end
  fitZoom()
  if not keepView then
    st.zoom = st.zmin
    st.px = (VP:GetWidth() - layer.W * st.zoom) / 2
    st.py = (VP:GetHeight() - layer.H * st.zoom) / 2
  end
  applyPan()
  if F.mapBtn then F.mapBtn.text:SetText(NS.mapName(map)) end
  drawTo(st.T, true)
end

local function latestMap()
  local best, bt
  for _, tr in ipairs(tracks) do
    local s = tr.sess
    if s.n > 0 then
      local a = s.start + s.t[s.n]
      if not bt or a > bt then bt, best = a, s.m[s.n] end
    end
  end
  return best
end

local rebuildRaw
local function rebuildAll(keepTime)
  NS.safe("다시 모으기", rebuildRaw, keepTime)
end
rebuildRaw = function(keepTime)
  buildTracks()
  if not keepTime or not st.T or st.T < st.tMin or st.T > st.tMax then st.T = st.tMax end
  local map = st.viewMap or NS.db.settings.lastMap or latestMap()
  if map then setViewMap(map, st.viewMap ~= nil) else drawTo(st.T, true) end
  if F.legend then
    local parts = {}
    for key, c in pairs(NS.db.chars) do
      if not st.charKey or st.charKey == key then
        local col = NS.charColor(c)
        parts[#parts + 1] = ("|cff%02x%02x%02x# %s|r"):format(col[1] * 255, col[2] * 255, col[3] * 255, c.name)
      end
    end
    F.legend:SetText(table.concat(parts, "  "))
  end
  if F.colorBtn then
    local key = st.charKey or NS.charKey()
    local c = key and NS.db.chars[key]
    local col = c and NS.charColor(c) or { 0.5, 0.5, 0.5 }
    F.colorBtn.swatch:SetColorTexture(col[1], col[2], col[3], 1)
  end
end

---------------------------------------------------------------- 작은 드롭다운 (템플릿 의존 없이)
local function closeDropdowns()
  for _, d in ipairs(dropdowns) do if d.list then d.list:Hide() end end
end

local function makeDropdown(parent, width, getItems, onPick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b.text = b:GetFontString() or b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetText("...")
  local list = CreateFrame("Frame", nil, parent)
  list:SetFrameStrata("TOOLTIP")
  list:SetWidth(width + 60)
  list:Hide()
  local bg = list:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(list)
  bg:SetColorTexture(0.06, 0.05, 0.04, 0.96)
  list.buttons = {}
  b.list = list
  b:SetScript("OnClick", function()
    if list:IsShown() then list:Hide() return end
    closeDropdowns()
    local items = getItems()
    for _, ib in ipairs(list.buttons) do ib:Hide() end
    local y = -4
    for i, it in ipairs(items) do
      local ib = list.buttons[i]
      if not ib then
        ib = CreateFrame("Button", nil, list)
        ib:SetHeight(18)
        ib.text = ib:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ib.text:SetPoint("LEFT", 8, 0)
        ib.text:SetJustifyH("LEFT")
        ib.hl = ib:CreateTexture(nil, "HIGHLIGHT")
        ib.hl:SetAllPoints(ib)
        ib.hl:SetColorTexture(1, 1, 1, 0.12)
        list.buttons[i] = ib
      end
      ib:ClearAllPoints()
      ib:SetPoint("TOPLEFT", list, "TOPLEFT", 0, y)
      ib:SetPoint("RIGHT", list, "RIGHT", 0, 0)
      ib.text:SetText(it.text)
      ib:SetScript("OnClick", function()
        list:Hide()
        b.text:SetText(it.short or it.text)
        onPick(it)
      end)
      ib:Show()
      y = y - 18
    end
    list:SetHeight(-y + 4)
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
    list:Show()
  end)
  dropdowns[#dropdowns + 1] = b
  return b
end

---------------------------------------------------------------- 창 만들기
local function cursorInViewport()
  local cx, cy = GetCursorPosition()
  local s = VP:GetEffectiveScale()
  return cx / s - VP:GetLeft(), VP:GetTop() - cy / s
end

local function zoomAt(factor, vx, vy)
  local nz = min(max(st.zoom * factor, st.zmin), st.zmax)
  if nz == st.zoom then return end
  local ux, uy = (vx - st.px) / st.zoom, (vy - st.py) / st.zoom
  st.zoom = nz
  st.px, st.py = vx - ux * nz, vy - uy * nz
  st.follow = false
  if F.followBtn then F.followBtn:SetAlpha(0.6) end
  applyPan()
  relayout()
  drawHeads(st.T)
  updateTimeUI()
end

local function build()
  local S = NS.db.settings.ui or {}
  F = CreateFrame("Frame", "HeroPathFrame", UIParent)
  F:SetFrameStrata("HIGH")
  F:SetSize(S.w or 960, S.h or 660)
  F:SetPoint("CENTER")
  F:SetMovable(true)
  F:SetResizable(true)
  F:SetClampedToScreen(true)
  F:EnableMouse(true)
  F:SetUserPlaced(true)
  if F.SetResizeBounds then F:SetResizeBounds(640, 440) elseif F.SetMinResize then F:SetMinResize(640, 440) end
  tinsert(UISpecialFrames, "HeroPathFrame")
  F:SetScript("OnMouseDown", closeDropdowns)

  local bg = F:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(F)
  bg:SetColorTexture(0.05, 0.045, 0.04, 0.95)
  local border = F:CreateTexture(nil, "BACKGROUND", nil, -1)
  border:SetPoint("TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", 1, -1)
  border:SetColorTexture(0.35, 0.30, 0.20, 1)

  -- 제목 줄 (드래그)
  local titleBar = CreateFrame("Frame", nil, F)
  titleBar:SetPoint("TOPLEFT")
  titleBar:SetPoint("TOPRIGHT")
  titleBar:SetHeight(28)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  titleBar:SetScript("OnDragStart", function() F:StartMoving() end)
  titleBar:SetScript("OnDragStop", function() F:StopMovingOrSizing() end)
  F.title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  F.title:SetPoint("LEFT", 12, 0)
  F.title:SetText("Hero's Path  |cff80c0ff용사의 발자취|r")
  local close = CreateFrame("Button", nil, F, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  -- 위 도구 줄
  local x = 12
  F.charBtn = makeDropdown(F, 120, function()
    local items = { { text = "모두", key = nil } }
    for key, c in pairs(NS.db.chars) do items[#items + 1] = { text = c.name, key = key } end
    table.sort(items, function(a, b) return (a.key or "") < (b.key or "") end)
    return items
  end, function(it) st.charKey = it.key st.viewMap = nil rebuildAll(false) end)
  F.charBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)
  F.charBtn.text:SetText("모두")
  x = x + 124

  -- 선 색 고르기: 고른 캐릭터(모두면 내 캐릭터)의 색을 게임 색 고르기 창으로
  F.colorBtn = CreateFrame("Button", nil, F, "UIPanelButtonTemplate")
  F.colorBtn:SetSize(22, 22)
  F.colorBtn:SetText("")
  F.colorBtn.swatch = F.colorBtn:CreateTexture(nil, "OVERLAY")
  F.colorBtn.swatch:SetPoint("TOPLEFT", 5, -5)
  F.colorBtn.swatch:SetPoint("BOTTOMRIGHT", -5, 5)
  F.colorBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)
  F.colorBtn:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("선 색 바꾸기 (" .. (st.charKey or NS.charKey() or "") .. ")")
    GameTooltip:AddLine("/hp color [캐릭] <색> 으로도 됨", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  F.colorBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  F.colorBtn:SetScript("OnClick", function()
    local key = st.charKey or NS.charKey()
    local c = key and NS.db.chars[key]
    if not c or not ColorPickerFrame then return end
    local cur = NS.charColor(c)
    local function apply()
      local r, g, b = ColorPickerFrame:GetColorRGB()
      NS.setCharColor(key, { r, g, b })
    end
    local function cancel(prev)
      if prev then NS.setCharColor(key, { prev.r, prev.g, prev.b }) end
    end
    if ColorPickerFrame.SetupColorPickerAndShow then
      ColorPickerFrame:SetupColorPickerAndShow({ r = cur[1], g = cur[2], b = cur[3], swatchFunc = apply, cancelFunc = cancel, hasOpacity = false })
    else
      ColorPickerFrame.func, ColorPickerFrame.cancelFunc, ColorPickerFrame.opacityFunc = apply, cancel, nil
      ColorPickerFrame.hasOpacity = false
      ColorPickerFrame.previousValues = { r = cur[1], g = cur[2], b = cur[3] }
      ColorPickerFrame:SetColorRGB(cur[1], cur[2], cur[3])
      ColorPickerFrame:Hide()
      ColorPickerFrame:Show()
    end
  end)
  x = x + 26

  F.mapBtn = makeDropdown(F, 170, function()
    local items = {}
    for _, m in ipairs(mapChoices()) do
      local prefix = (m.type == 2 and "[대륙] ") or (m.type == 4 and "[던전] ") or (m.type == 5 and "[소지도] ") or ""
      items[#items + 1] = { text = prefix .. m.name, short = m.name, map = m.map }
    end
    if #items == 0 then items[1] = { text = "(자료 없음)", map = st.viewMap } end
    return items
  end, function(it) if it.map then setViewMap(it.map, false) end end)
  F.mapBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)
  x = x + 176

  F.rangeBtn = makeDropdown(F, 150, function()
    local items = {
      { text = "전체", short = "전체", range = "all" },
      { text = "오늘", short = "오늘", range = "today" },
      { text = "최근 7일", short = "최근 7일", range = "week" },
    }
    local sess = {}
    for key, c in pairs(NS.db.chars) do
      if not st.charKey or st.charKey == key then
        for _, s in ipairs(c.sessions) do if (s.n or 0) > 0 then sess[#sess + 1] = { s = s, who = c.name } end end
      end
    end
    table.sort(sess, function(a, b) return a.s.start > b.s.start end)
    for i = 1, min(#sess, 25) do
      local s = sess[i].s
      local dur = (s.stop or (s.start + s.t[s.n])) - s.start
      local label = NS.fmtShort(s.start) .. " " .. sess[i].who .. " (" .. NS.fmtDur(dur) .. ")"
      items[#items + 1] = { text = label, short = NS.fmtShort(s.start), range = s }
    end
    return items
  end, function(it) st.range = it.range rebuildAll(false) end)
  F.rangeBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)
  F.rangeBtn.text:SetText("전체")
  x = x + 156

  local function toggleBtn(label, width, getter, onClick)
    local b = CreateFrame("Button", nil, F, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", function() onClick() b:SetAlpha(getter() and 1 or 0.6) end)
    b:SetAlpha(getter() and 1 or 0.6)
    return b
  end
  F.followBtn = toggleBtn("따라가기", 72, function() return st.follow end, function()
    st.follow = not st.follow
    if st.follow then
      local hx, hy = drawHeads(st.T)
      if hx then centerOn(hx, hy) end
    end
  end)
  F.followBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)
  x = x + 76
  F.eventsBtn = toggleBtn("사건", 50, function() return st.showEvents end, function()
    st.showEvents = not st.showEvents
    drawTo(st.T, true)
  end)
  F.eventsBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)
  x = x + 54
  F.skipBtn = toggleBtn("공백 건너뜀", 90, function() return st.skipIdle end, function() st.skipIdle = not st.skipIdle end)
  F.skipBtn:SetPoint("TOPLEFT", F, "TOPLEFT", x, -32)

  F.zoomText = F:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  F.zoomText:SetPoint("TOPRIGHT", F, "TOPRIGHT", -14, -36)

  -- 뷰포트
  VP = CreateFrame("Frame", nil, F)
  VP:SetPoint("TOPLEFT", F, "TOPLEFT", 12, -60)
  VP:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", -12, 78)
  VP:SetClipsChildren(true)
  VP:EnableMouse(true)
  VP:EnableMouseWheel(true)
  local vbg = VP:CreateTexture(nil, "BACKGROUND")
  vbg:SetAllPoints(VP)
  vbg:SetColorTexture(0, 0, 0, 1)

  CV = CreateFrame("Frame", nil, VP)
  CV:SetSize(layer.W, layer.H)
  CV:SetPoint("TOPLEFT")

  VP.wheel = function(_, delta)
    local vx, vy = cursorInViewport()
    zoomAt(delta > 0 and 1.25 or 0.8, vx, vy)
  end
  VP:SetScript("OnMouseWheel", VP.wheel)
  VP:SetScript("OnMouseDown", function(_, btn)
    closeDropdowns()
    if btn ~= "LeftButton" then return end
    local cx, cy = GetCursorPosition()
    VP.drag = { cx, cy, st.px, st.py }
  end)
  VP:SetScript("OnMouseUp", function() VP.drag = nil end)
  VP:SetScript("OnSizeChanged", function()
    if not st.viewMap then return end
    local oz = st.zmin
    fitZoom()
    if st.zoom < st.zmin or abs(st.zoom - oz) < 1e-6 then st.zoom = st.zmin end
    applyPan()
    relayout()
    drawHeads(st.T)
  end)

  -- 아래 도구 줄
  F.play = CreateFrame("Button", nil, F, "UIPanelButtonTemplate")
  F.play:SetSize(36, 24)
  F.play:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", 12, 44)
  F.play:SetText(">")
  F.play:SetScript("OnClick", function()
    if st.playing then
      st.playing = false
    else
      if st.T >= st.tMax then seek(st.tMin) end
      st.playing = true
      st.live = false
    end
    updateTimeUI()
  end)

  F.liveBtn = CreateFrame("Button", nil, F, "UIPanelButtonTemplate")
  F.liveBtn:SetSize(46, 24)
  F.liveBtn:SetPoint("LEFT", F.play, "RIGHT", 4, 0)
  F.liveBtn:SetText("지금")
  F.liveBtn:SetScript("OnClick", function()
    st.live = not st.live
    st.playing = false
    if st.live then rebuildAll(false) seek(st.tMax) end
    updateTimeUI()
  end)

  local sx = 100
  F.speedBtns = {}
  for _, sp in ipairs(SPEEDS) do
    local b = CreateFrame("Button", nil, F, "UIPanelButtonTemplate")
    local w = (sp >= 1000) and 52 or 44
    b:SetSize(w, 24)
    b:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", sx, 44)
    b:SetText(sp >= 60 and ((sp / 60) .. "m/s") or (sp .. "x"))
    b:SetScript("OnClick", function()
      st.speed = sp
      for _, o in ipairs(F.speedBtns) do o:SetAlpha(o.speed == sp and 1 or 0.6) end
    end)
    b.speed = sp
    b:SetAlpha(sp == st.speed and 1 or 0.6)
    F.speedBtns[#F.speedBtns + 1] = b
    sx = sx + w + 4
  end

  F.timeText = F:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  F.timeText:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", sx + 8, 50)
  F.timeText:SetJustifyH("LEFT")

  F.legend = F:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  F.legend:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", -30, 50)
  F.legend:SetJustifyH("RIGHT")

  -- 시간 슬라이더
  local sl = CreateFrame("Slider", nil, F)
  sl:SetOrientation("HORIZONTAL")
  sl:SetHeight(16)
  sl:SetPoint("BOTTOMLEFT", F, "BOTTOMLEFT", 14, 20)
  sl:SetPoint("BOTTOMRIGHT", F, "BOTTOMRIGHT", -34, 20)
  sl:SetMinMaxValues(0, 1000)
  sl:SetValueStep(1)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  local track = sl:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("LEFT", 0, 0)
  track:SetPoint("RIGHT", 0, 0)
  track:SetHeight(6)
  track:SetColorTexture(0.25, 0.22, 0.18, 1)
  sl.fill = sl:CreateTexture(nil, "BORDER")
  sl.fill:SetPoint("LEFT", 0, 0)
  sl.fill:SetHeight(6)
  sl.fill:SetColorTexture(0.25, 0.95, 0.40, 0.8)
  sl.fill:SetWidth(1)
  sl:SetScript("OnValueChanged", function(self, v)
    local w = self:GetWidth()
    if w and w > 0 then self.fill:SetWidth(max(1, w * v / 1000)) end
    if F.sliderBusy then return end
    st.live = false
    local span = st.tMax - st.tMin
    seek(st.tMin + span * v / 1000)
  end)
  sl:SetScript("OnMouseDown", function(self) self.dragging = true st.playing = false updateTimeUI() end)
  sl:SetScript("OnMouseUp", function(self) self.dragging = false end)
  sl:EnableMouseWheel(true)
  sl:SetScript("OnMouseWheel", function(_, d)
    local span = st.tMax - st.tMin
    seek(st.T + (d > 0 and 1 or -1) * max(10, span / 200))
  end)
  F.slider = sl

  -- 크기 조절 손잡이
  local grip = CreateFrame("Button", nil, F)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnMouseDown", function() F:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    F:StopMovingOrSizing()
    V.save()
  end)

  -- 매 프레임: 드래그 이동 · 재생 · 실시간
  local acc = 0
  F:SetScript("OnUpdate", function(_, elapsed)
    if VP.drag then
      local cx, cy = GetCursorPosition()
      local s = VP:GetEffectiveScale()
      st.px = VP.drag[3] + (cx - VP.drag[1]) / s
      st.py = VP.drag[4] - (cy - VP.drag[2]) / s
      st.follow = false
      F.followBtn:SetAlpha(0.6)
      applyPan()
    end
    if st.playing then
      local T = st.T + elapsed * st.speed
      if st.skipIdle then
        local nxt = nextPointTime()
        if nxt and nxt > T + 120 then T = nxt - 2 end
      end
      if T >= st.tMax then
        T = st.tMax
        st.playing = false
      end
      drawTo(T, false)
    elseif st.live then
      acc = acc + elapsed
      if acc >= 1.0 then
        acc = 0
        local s = NS.Record and NS.Record.current()
        if s and s.n > 0 then
          -- 지금 세션이 트랙에 없으면 다시 모음
          local have = false
          for _, tr in ipairs(tracks) do if tr.sess == s then have = true end end
          if not have then rebuildAll(true) end
          local nowT = GetServerTime()
          st.tMax = max(st.tMax, nowT)
          drawTo(nowT, false)
        end
      end
    end
  end)

  F:SetScript("OnShow", function()
    rebuildAll(true)
    seek(st.tMax)
    st.live = true
    updateTimeUI()
  end)
  F:SetScript("OnHide", function()
    st.playing = false
    st.live = false
    closeDropdowns()
  end)
end

-- 색 등 바깥에서 바뀐 것 다시 그리기
function V.refresh()
  if F and F:IsShown() then rebuildAll(true) end
end

function V.toggle()
  if not F then build() end
  if F:IsShown() then F:Hide() else F:Show() end
end

function V.show() if not F then build() end F:Show() end
function V.save()
  if F then
    NS.db.settings.ui = NS.db.settings.ui or {}
    NS.db.settings.ui.w, NS.db.settings.ui.h = F:GetWidth(), F:GetHeight()
  end
end
V.state = st
function V.debug()
  local shown = 0
  for _, l in ipairs(lines) do if l:IsShown() then shown = shown + 1 end end
  local r = st.range
  r = (type(r) == "table") and ("세션 " .. NS.fmtShort(r.start)) or tostring(r)
  return ("범위 %s · 트랙 %d · 선 %d(풀 %d, 씀 %d) · 표식 %d · 지도 %s · T %s · %s~%s · 보폭 %d · zoom %.3f"):format(
    r, #tracks, shown, #lines, nLines, nMarkers, tostring(st.viewMap), st.T and NS.fmtClock(st.T) or "-",
    st.tMin and NS.fmtClock(st.tMin) or "-", st.tMax and NS.fmtClock(st.tMax) or "-", st.stride or 0, st.zoom or 0)
end
