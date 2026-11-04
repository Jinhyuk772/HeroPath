-- Hero's Path · Core: 저장소 · 공용 도우미 · 명령어
-- 저장 구조 (HeroPathDB, 계정 공용):
--   chars["이름-서버"] = { name, realm, class, color(1..6), sessions = { S, ... } }
--   S = { start = 서버시각, stop = 서버시각|nil, n = 점 수,
--         t = {초 오프셋}, m = {uiMapID}, x = {0..10000}, y = {0..10000}, fl = {[i] = 1 비행 · 2 유령},
--         ev = { {k = 종류, t = 초, i = 그때까지의 점 번호, ...}, ... } }
-- 좌표는 기록한 지도 기준으로만 저장하고, 보는 지도가 다르면 Viewer 가 월드 좌표를 거쳐 변환한다 (지도 에셋과 항상 정합).
local ADDON, NS = ...
HeroPath = NS
NS.VERSION = "0.3.0"

BINDING_HEADER_HEROPATH = "Hero's Path"
BINDING_NAME_HEROPATH_TOGGLE = "발자취 창 열기/닫기"

NS.DEFAULTS = {
  interval = 1.0,      -- 위치 확인 주기(초)
  goldStep = 100,      -- 이만큼(은) 넘게 골드가 바뀌면 GOLD 사건
  minMove = 12,        -- 이만큼(1/10000 지도 단위) 안 움직였으면 점을 안 찍음
  maxPoints = 200000,  -- 세션당 점 상한
  trackQuests = true,
  gapSeconds = 180,    -- 이보다 긴 공백은 선을 끊음 (로그아웃 · 귀환석 · 순간이동)
  ui = { w = 960, h = 660 },
}

NS.COLORS = {
  { 0.25, 0.95, 0.40 },  -- 초록 (야숨 기본)
  { 0.40, 0.70, 1.00 },  -- 하늘
  { 1.00, 0.60, 0.20 },  -- 주황
  { 0.95, 0.40, 0.85 },  -- 자홍
  { 1.00, 0.92, 0.30 },  -- 노랑
  { 0.45, 0.95, 0.95 },  -- 청록
}

function NS.charKey()
  local n = UnitName("player")
  local r = GetRealmName and GetRealmName() or ""
  if not n then return nil end
  r = (r or ""):gsub("%s+", "")
  return n .. "-" .. r
end

function NS.initDB()
  HeroPathDB = HeroPathDB or { version = 1, chars = {}, settings = {} }
  local db = HeroPathDB
  db.chars = db.chars or {}
  db.settings = db.settings or {}
  for k, v in pairs(NS.DEFAULTS) do
    if type(v) == "table" then
      db.settings[k] = db.settings[k] or {}
      for k2, v2 in pairs(v) do if db.settings[k][k2] == nil then db.settings[k][k2] = v2 end end
    elseif db.settings[k] == nil then
      db.settings[k] = v
    end
  end
  db.maps = db.maps or {}  -- uiMapID → {name, type, parent} (지도 이름 캐시)
  NS.db = db
  return db
end

function NS.charData(key, create)
  local db = NS.db
  local c = db.chars[key]
  if not c and create then
    local used = {}
    for _, o in pairs(db.chars) do used[o.color or 0] = true end
    local color = 1
    for i = 1, #NS.COLORS do if not used[i] then color = i break end end
    local name, realm = key:match("^(.-)%-(.*)$")
    c = { name = name or key, realm = realm or "", color = color, sessions = {} }
    local _, class = UnitClass("player")
    c.class = class
    db.chars[key] = c
  end
  return c
end

function NS.rememberMap(map)
  local db = NS.db
  if not map or db.maps[map] or not (C_Map and C_Map.GetMapInfo) then return end
  local ok, info = pcall(C_Map.GetMapInfo, map)
  if ok and info then db.maps[map] = { name = info.name, type = info.mapType, parent = info.parentMapID } end
end

function NS.mapName(map)
  local e = NS.db and NS.db.maps[map]
  if e and e.name then return e.name end
  if C_Map and C_Map.GetMapInfo then
    local ok, info = pcall(C_Map.GetMapInfo, map)
    if ok and info and info.name then return info.name end
  end
  return "지도 " .. tostring(map)
end

function NS.fmtClock(ts)
  if not ts then return "-" end
  return date("%Y-%m-%d %H:%M:%S", ts)
end

function NS.fmtShort(ts)
  if not ts then return "-" end
  return date("%m-%d %H:%M", ts)
end

function NS.fmtDur(sec)
  sec = math.floor((sec or 0) + 0.5)
  if sec < 60 then return sec .. "초" end
  local m = math.floor(sec / 60)
  if m < 60 then return m .. "분" end
  local h = math.floor(m / 60)
  m = m % 60
  if h < 24 then return h .. "시간 " .. m .. "분" end
  local d = math.floor(h / 24)
  return d .. "일 " .. (h % 24) .. "시간"
end

function NS.fmtMoney(copper)
  copper = math.floor(math.abs(copper or 0) + 0.5)
  local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return ("%d골드 %d은"):format(g, sv) end
  if sv > 0 then return ("%d은 %d동"):format(sv, c) end
  return c .. "동"
end

-- 캐릭터 선 색: 직접 고른 색(rgb) 이 있으면 그것, 없으면 기본 팔레트
function NS.charColor(c)
  if c.rgb then return c.rgb end
  return NS.COLORS[c.color or 1] or NS.COLORS[1]
end

local NAMED = { ["빨강"] = "ff4040", ["주황"] = "ff9933", ["노랑"] = "ffe64d", ["초록"] = "40f266", ["하늘"] = "66b3ff", ["파랑"] = "4060ff",
  ["보라"] = "b266ff", ["분홍"] = "ff66cc", ["흰색"] = "ffffff", ["청록"] = "66f2f2",
  red = "ff4040", green = "40f266", blue = "66b3ff", yellow = "ffe64d", pink = "ff66cc", purple = "b266ff", orange = "ff9933", white = "ffffff", cyan = "66f2f2" }
function NS.parseColor(str)
  if not str then return nil end
  str = str:lower():gsub("^#", "")
  str = NAMED[str] or str
  if #str ~= 6 or not str:match("^%x+$") then return nil end
  return { tonumber(str:sub(1, 2), 16) / 255, tonumber(str:sub(3, 4), 16) / 255, tonumber(str:sub(5, 6), 16) / 255 }
end

function NS.setCharColor(key, rgb)
  local c = NS.db.chars[key]
  if not c then return false end
  c.rgb = rgb
  if NS.Viewer and NS.Viewer.refresh then NS.Viewer.refresh() end
  if NS.Options and NS.Options.updateButton then NS.Options.updateButton() end
  return true
end

local shownErr = {}
NS.errors = {}
function NS.safe(where, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    NS.errors[#NS.errors + 1] = where .. ": " .. tostring(err)
    if not shownErr[err] then
      shownErr[err] = true
      NS.print("|cffff4040오류|r " .. where .. ": " .. tostring(err) .. "  (/hp errors 로 다시 보기)")
    end
  end
  return ok
end

function NS.print(msg)
  (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cff40e080Hero's Path|r " .. tostring(msg))
end

function NS.Toggle()
  if NS.Viewer then NS.Viewer.toggle() end
end

-- 전체 점 수 · 세션 수
function NS.stats()
  local chars, sessions, points, events = 0, 0, 0, 0
  for _, c in pairs(NS.db.chars) do
    chars = chars + 1
    for _, s in ipairs(c.sessions) do
      sessions = sessions + 1
      points = points + (s.n or 0)
      events = events + #(s.ev or {})
    end
  end
  return chars, sessions, points, events
end

SLASH_HEROPATH1 = "/heropath"
SLASH_HEROPATH2 = "/hp"
SlashCmdList.HEROPATH = function(msg)
  local raw = msg or ""
  msg = raw:lower()
  local cmd, arg = msg:match("^(%S*)%s*(.-)$")
  local _, rest = raw:match("^(%S*)%s*(.-)$")  -- 이름은 대소문자 보존
  rest = rest or ""
  if cmd == "" or cmd == "show" or cmd == "toggle" then
    NS.Toggle()
  elseif cmd == "status" then
    local chars, sessions, points, events = NS.stats()
    NS.print(("캐릭터 %d · 세션 %d · 점 %d · 사건 %d · 주기 %.1f초"):format(chars, sessions, points, events, NS.db.settings.interval))
    if NS.Record and NS.Record.status then NS.print(NS.Record.status()) end
  elseif cmd == "interval" then
    local v = tonumber(arg)
    if v and v >= 0.2 and v <= 30 then
      NS.db.settings.interval = v
      NS.print("위치 확인 주기 " .. v .. "초")
    else
      NS.print("/hp interval 0.2~30")
    end
  elseif cmd == "quests" then
    NS.db.settings.trackQuests = not NS.db.settings.trackQuests
    NS.print("퀘스트 완료 표시 " .. (NS.db.settings.trackQuests and "켬" or "끔"))
  elseif cmd == "gold" then
    local v = tonumber(arg)
    if v and v >= 1 then
      NS.db.settings.goldStep = v
      NS.print("골드 변화 표식 기준 " .. v .. "은 이상")
    else
      NS.print("/hp gold <은>  (지금 " .. (NS.db.settings.goldStep or 100) .. "은)")
    end
  elseif cmd == "color" then
    -- /hp color <색>  또는  /hp color <캐릭이름> <색>   (색 = ff8800 · 초록 · 하늘 ...)
    local who, col = arg:match("^(%S+)%s+(%S+)$")
    if not col then who, col = nil, arg end
    local rgb = NS.parseColor(col)
    if not rgb then NS.print("/hp color [캐릭이름] <ff8800|빨강|주황|노랑|초록|하늘|파랑|보라|분홍|청록|흰색>") return end
    local key
    if who then
      for k, c in pairs(NS.db.chars) do if c.name:lower() == who:lower() or k:lower() == who:lower() then key = k end end
      if not key then NS.print("그런 캐릭터 기록이 없습니다: " .. who) return end
    else
      key = NS.charKey()
    end
    if NS.setCharColor(key, rgb) then NS.print(key .. " 선 색을 바꿨습니다.") else NS.print("기록이 없는 캐릭터입니다.") end
  elseif cmd == "wipe" then
    if arg == "confirm" then
      wipe(NS.db.chars)
      if NS.Record then NS.Record.restart() end
      NS.print("모든 발자취를 지웠습니다.")
    else
      NS.print("정말 지우려면 /hp wipe confirm")
    end
  else
    if cmd == "invite" or cmd == "초대" then NS.Sync.invite(rest) return end
    if cmd == "accept" or cmd == "수락" then NS.Sync.accept(rest ~= "" and rest or nil) return end
    if cmd == "decline" or cmd == "거절" then NS.Sync.decline(rest ~= "" and rest or nil) return end
    if cmd == "unpair" or cmd == "해제" then NS.Sync.unpair(rest) return end
    if cmd == "forget" then NS.Sync.forget(rest) return end
    if cmd == "partners" or cmd == "짝" then
      local n = 0
      for key, p in pairs(NS.Sync.partners()) do
        n = n + 1
        local st, pts = NS.Sync.status(key)
        NS.print(("  %s · %s · 받아 둔 점 %d · 맺음 %s"):format(key, st, pts, NS.fmtShort(p.since)))
      end
      if n == 0 then NS.print("함께 보는 사람이 없습니다. 설정 패널이나 /hp invite <이름> 으로 초대하세요.") end
      return
    end
    if msg == "debug" then
      NS.print(NS.Viewer and NS.Viewer.debug and NS.Viewer.debug() or "뷰어 없음")
      return
    end
    if msg == "errors" then
      if #NS.errors == 0 then NS.print("기록된 오류 없음") end
      for i = max(1, #NS.errors - 9), #NS.errors do NS.print(NS.errors[i]) end
      return
    end
    if msg == "settings" or msg == "설정" then if NS.Options then NS.Options.openSettings() end return end
    NS.print("/hp invite <이름> · /hp accept · /hp partners · /hp unpair <이름>  (둘이 보기)")
    NS.print("/hp  창 열기/닫기 · /hp settings · /hp status · /hp color [캐릭] <색> · /hp gold <은> · /hp interval <초> · /hp quests · /hp wipe confirm")
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, ev, name)
  if ev == "ADDON_LOADED" and name == ADDON then
    NS.initDB()
    if NS.Record then NS.Record.init() end
    if NS.Sync then NS.Sync.init() end
    if NS.Options then NS.Options.init() end
    NS.print("Hero's Path " .. NS.VERSION .. " 기록 중 — /hp 로 창 열기")
    f:UnregisterEvent("ADDON_LOADED")
  elseif ev == "PLAYER_LOGOUT" then
    if NS.Record then NS.Record.logout() end
    if NS.Sync then NS.Sync.logout() end
    if NS.Viewer and NS.Viewer.save then NS.Viewer.save() end
  end
end)
