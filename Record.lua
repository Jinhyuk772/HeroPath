-- Hero's Path · Record: 위치 점 + 굵직한 사건 기록
-- 위치: C_Map.GetBestMapForUnit + GetPlayerMapPosition 을 주기마다 확인, 움직였을 때만 점을 찍음.
--       던전 안은 그 던전 지도(층 지도)가 있으면 똑같이 기록되고, 지도 위치가 비면 '어둠 구간'(blind) 으로 세며
--       INST_IN / INST_OUT 사건이 들어간 시각 · 나온 시각 · 머문 시간을 남긴다.
-- 사건: LOGIN LOGOUT DEATH REVIVE LEVEL ZONE INST_IN INST_OUT QUEST HEARTH TAXI_ON TAXI_OFF
local NS = select(2, ...)
local R = {}
NS.Record = R

local floor, abs = math.floor, math.abs
local S            -- 지금 세션
local char         -- 지금 캐릭터 자료
local lastM, lastX, lastY
local inInst, instName, instEnter
local onTaxi = false
local lastAttacker
local instEvent          -- 지금 들어와 있는 인스턴스의 INST_IN 사건 (안에서 생긴 일을 log 로 붙임)
local lastMoney
local firstVisit         -- 아래에서 정의 (로그인 처리에서도 씀)
local seenGuid = {}      -- guid → {name, cls, lvl, t} 최근 본 희귀 · 보스 (처치 판정용)
local started = false
local loopRunning = false

local function now()
  return GetServerTime() - S.start
end

local function newSession()
  S = { start = GetServerTime(), n = 0, t = {}, m = {}, x = {}, y = {}, fl = {}, ev = {}, blind = 0 }
  table.insert(char.sessions, S)
  lastM, lastX, lastY = nil, nil, nil
  return S
end

function R.current() return S end
function R.restart()
  char = NS.charData(NS.charKey(), true)
  newSession()
  R.event("LOGIN", { reload = true })
end

function R.event(kind, data)
  if not S then return end
  local e = data or {}
  e.k = kind
  e.t = now()
  e.i = S.n
  S.ev[#S.ev + 1] = e
  if instEvent and e ~= instEvent and R.instLine then
    local line = R.instLine(e)
    if line then
      instEvent.log = instEvent.log or {}
      if #instEvent.log < 60 then instEvent.log[#instEvent.log + 1] = { t = e.t, s = line } end
    end
  end
  return e
end

-- 던전 안에서 생긴 일을 입구 표식에 붙일 한 줄 글
function R.instLine(e)
  local k = e.k
  if k == "SUBZONE" then return "→ " .. (e.name or "")
  elseif k == "BOSS" then return "보스 처치: " .. (e.name or "")
  elseif k == "KILL" then return "희귀 처치: " .. (e.name or "")
  elseif k == "DEATH" then return "사망" .. (e.by and (" (" .. e.by .. ")") or "")
  elseif k == "REVIVE" then return "부활"
  elseif k == "LEVEL" then return "레벨 " .. tostring(e.lvl)
  elseif k == "QUEST" then return "퀘스트 완료: " .. (e.title or tostring(e.id))
  elseif k == "GOLD" then return (e.delta >= 0 and "+" or "-") .. NS.fmtMoney(e.delta)
  elseif k == "FIRST" then return "첫 방문: " .. (e.name or "")
  end
end

local function flags()
  local f = 0
  if onTaxi then f = 1 end
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then f = 2 end
  return f
end

-- 점 하나. force = 지도 바뀜 · 사건 직후 등 움직임과 상관없이 찍기
function R.sample(force)
  if not S or not (C_Map and C_Map.GetBestMapForUnit) then return end
  local map = C_Map.GetBestMapForUnit("player")
  local x, y
  if map then
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if ok and pos then x, y = pos:GetXY() end
  end
  if not x or not y or (x == 0 and y == 0) then
    -- 지도 위치가 없는 곳(지도 없는 인스턴스 등): 어둠 구간으로 셈
    S.blind = (S.blind or 0) + 1
    return
  end
  local xi, yi = floor(x * 10000 + 0.5), floor(y * 10000 + 0.5)
  local minMove = NS.db.settings.minMove or 12
  if not force and lastM == map and abs(xi - lastX) < minMove and abs(yi - lastY) < minMove then return end
  if S.n >= (NS.db.settings.maxPoints or 200000) then
    S.truncated = true
    return
  end
  local n = S.n + 1
  S.n = n
  S.t[n] = now()
  S.m[n] = map
  S.x[n] = xi
  S.y[n] = yi
  local f = flags()
  if f ~= 0 then S.fl[n] = f end
  if lastM ~= map then NS.rememberMap(map) end
  lastM, lastX, lastY = map, xi, yi
end

local function checkTaxi()
  local t = UnitOnTaxi and UnitOnTaxi("player") and true or false
  if t ~= onTaxi then
    onTaxi = t
    R.sample(true)
    R.event(t and "TAXI_ON" or "TAXI_OFF", { zone = GetRealZoneText and GetRealZoneText() or nil })
  end
end

local function checkInstance()
  local isIn, kind = false, "none"
  if IsInInstance then isIn, kind = IsInInstance() end
  isIn = isIn and (kind == "party" or kind == "raid" or kind == "pvp" or kind == "arena") or false
  if isIn == inInst then return end
  if inInst == nil and not isIn then inInst = false return end -- 처음 판정: 밖이면 조용히
  if isIn then
    local name = GetInstanceInfo and GetInstanceInfo() or GetRealZoneText()
    instName, instEnter = name, GetServerTime()
    inInst = true
    R.sample(true)
    instEvent = R.event("INST_IN", { name = name, kind = kind })
  else
    inInst = false
    R.sample(true)
    local dur = instEnter and (GetServerTime() - instEnter) or nil
    if instEvent then instEvent.dur = dur end
    instEvent = nil
    R.event("INST_OUT", { name = instName, dur = dur })
    instName, instEnter = nil, nil
  end
end

local function loop()
  if not S then loopRunning = false return end
  pcall(checkTaxi)
  pcall(R.sample, false)
  local iv = NS.db.settings.interval or 1.0
  if onTaxi and iv > 0.5 then iv = 0.5 end
  C_Timer.After(iv, loop)
end

local function questTitle(id)
  local title
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local ok, t = pcall(C_QuestLog.GetTitleForQuestID, id)
    if ok then title = t end
  end
  if not title and C_QuestLog and C_QuestLog.GetQuestInfo then
    local ok, t = pcall(C_QuestLog.GetQuestInfo, id)
    if ok then title = t end
  end
  return title
end

local ev = CreateFrame("Frame")
local HANDLERS = {}

HANDLERS.PLAYER_ENTERING_WORLD = function(isLogin, isReload)
  if not started then
    started = true
    char = NS.charData(NS.charKey(), true)
    newSession()
    R.event("LOGIN", { lvl = UnitLevel("player"), zone = GetRealZoneText and GetRealZoneText() or nil, reload = isReload and true or nil })
    if GetMoney then lastMoney = GetMoney() end
    -- 처음 서 있는 지역 · 세부 지역도 첫 방문 후보
    firstVisit(GetRealZoneText and GetRealZoneText() or nil, "zone")
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub ~= "" then firstVisit(sub, "sub") end
  end
  checkInstance()
  R.sample(true)
  if not loopRunning then
    loopRunning = true
    C_Timer.After(1.0, loop)
  end
end

-- 첫 방문: 캐릭터별로 지역 · 세부 지역 이름을 기억해 처음 밟을 때 FIRST
firstVisit = function(name, kind)
  if not S or not name or name == "" or not char then return end
  char.visited = char.visited or {}
  if char.visited[name] then return end
  char.visited[name] = GetServerTime()
  R.sample(true)
  R.event("FIRST", { name = name, kind = kind })
end

HANDLERS.ZONE_CHANGED_NEW_AREA = function()
  if not S then return end
  R.sample(true)
  checkInstance()
  local zone = GetRealZoneText and GetRealZoneText() or nil
  R.event("ZONE", { name = zone, map = lastM })
  if not inInst then firstVisit(zone, "zone") end
end

HANDLERS.ZONE_CHANGED = function()
  if not S then return end
  local sub = GetSubZoneText and GetSubZoneText() or ""
  if sub ~= "" then
    if inInst then R.event("SUBZONE", { name = sub }) end
    firstVisit(sub, "sub")
  end
end
HANDLERS.ZONE_CHANGED_INDOORS = HANDLERS.ZONE_CHANGED

HANDLERS.PLAYER_MONEY = function()
  if not S or not GetMoney then return end
  local m = GetMoney()
  if lastMoney == nil then lastMoney = m return end
  local d = m - lastMoney
  lastMoney = m
  local step = (NS.db.settings.goldStep or 100) * 100  -- 은 단위 설정 → 동
  if math.abs(d) < step then return end
  local how = (d < 0) and "소비" or "획득"
  if MerchantFrame and MerchantFrame:IsShown() then how = "상인"
  elseif MailFrame and MailFrame:IsShown() then how = "우편"
  elseif TradeFrame and TradeFrame:IsShown() then how = "거래"
  elseif AuctionFrame and AuctionFrame:IsShown() then how = "경매" end
  R.sample(true)
  R.event("GOLD", { delta = d, total = m, how = how })
end

HANDLERS.ENCOUNTER_END = function(id, name, difficulty, size, success)
  if not S then return end
  R.sample(true)
  R.event("BOSS", { name = name, id = id, ok = (success == 1 or success == true) and true or false })
end

-- 희귀 · 월드보스: 대상으로 잡거나 이름표 · 마우스오버로 본 것 중 등급이 rare/rareelite/worldboss 인 것을 기억해 두었다가 죽으면 KILL
local function noteUnit(unit)
  if not UnitExists or not UnitExists(unit) then return end
  local cls = UnitClassification and UnitClassification(unit)
  if cls ~= "rare" and cls ~= "rareelite" and cls ~= "worldboss" then return end
  local guid = UnitGUID(unit)
  if guid then seenGuid[guid] = { name = UnitName(unit), cls = cls, lvl = UnitLevel(unit), t = GetTime() } end
end
HANDLERS.PLAYER_TARGET_CHANGED = function() noteUnit("target") end
HANDLERS.NAME_PLATE_UNIT_ADDED = function(unit) noteUnit(unit) end
HANDLERS.UPDATE_MOUSEOVER_UNIT = function() noteUnit("mouseover") end

local wasDead = false
HANDLERS.PLAYER_DEAD = function()
  if not S then return end
  wasDead = true
  R.sample(true)
  R.event("DEATH", { lvl = UnitLevel("player"), by = lastAttacker, zone = GetRealZoneText and GetRealZoneText() or nil, sub = GetSubZoneText and GetSubZoneText() or nil })
end

HANDLERS.PLAYER_UNGHOST = function()
  if not S or not wasDead then return end
  wasDead = false
  R.sample(true)
  R.event("REVIVE", {})
end
HANDLERS.PLAYER_ALIVE = function()
  if not S or not wasDead then return end -- 로그인 · 유령이 된 순간에도 PLAYER_ALIVE 가 옴
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end
  wasDead = false
  R.sample(true)
  R.event("REVIVE", {})
end

HANDLERS.PLAYER_LEVEL_UP = function(level)
  if not S then return end
  R.sample(true)
  R.event("LEVEL", { lvl = tonumber(level), zone = GetRealZoneText and GetRealZoneText() or nil })
end

HANDLERS.QUEST_TURNED_IN = function(questID, xp, money)
  if not S or not NS.db.settings.trackQuests then return end
  R.sample(true)
  R.event("QUEST", { id = questID, title = questTitle(questID), xp = xp })
end

HANDLERS.UNIT_SPELLCAST_SUCCEEDED = function(unit, castGUID, spellID)
  if unit ~= "player" or not S then return end
  if spellID == 8690 then -- 귀환석
    R.sample(true)
    R.event("HEARTH", { dest = GetBindLocation and GetBindLocation() or nil })
  end
end

HANDLERS.COMBAT_LOG_EVENT_UNFILTERED = function()
  if not CombatLogGetCurrentEventInfo then return end
  local _, sub, _, _, srcName, _, _, dstGUID = CombatLogGetCurrentEventInfo()
  if dstGUID == UnitGUID("player") and sub and sub:find("_DAMAGE", 1, true) and srcName then
    lastAttacker = srcName
  elseif sub == "UNIT_DIED" and S then
    local u = seenGuid[dstGUID]
    if u and GetTime() - u.t < 600 then
      seenGuid[dstGUID] = nil
      R.sample(true)
      R.event("KILL", { name = u.name, cls = u.cls, lvl = u.lvl })
    end
  end
end

for e in pairs(HANDLERS) do
  if e == "UNIT_SPELLCAST_SUCCEEDED" and ev.RegisterUnitEvent then
    ev:RegisterUnitEvent(e, "player")
  else
    pcall(ev.RegisterEvent, ev, e)
  end
end
ev:SetScript("OnEvent", function(_, e, ...)
  local h = HANDLERS[e]
  if h then pcall(h, ...) end
end)

function R.init()
  -- ADDON_LOADED 뒤. 세션은 PLAYER_ENTERING_WORLD 에서 시작 (그때 지도 API 가 살아 있음)
end

function R.logout()
  if not S then return end
  R.sample(true)
  R.event("LOGOUT", { zone = GetRealZoneText and GetRealZoneText() or nil })
  S.stop = GetServerTime()
end

function R.status()
  if not S then return "세션 없음" end
  return ("이번 세션 점 %d · 사건 %d · 어둠 %d회 · %s 부터"):format(S.n, #S.ev, S.blind or 0, NS.fmtClock(S.start))
end
