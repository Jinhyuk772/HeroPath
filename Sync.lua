-- Hero's Path — 둘이 보기: 양자 동의(초대 → 수락) 뒤에만 발자취를 주고받는다
-- 채널: 애드온 귓속말 (같은 서버 · 같은 진영). 상대 캐릭터마다 한 번 짝을 맺는다.
local ADDON, NS = ...
local Y = {}
NS.Sync = Y

local PREFIX = "HeroPath"
local FS, RS, KS = "\31", "\30", "\29"   -- 필드 · 레코드 · 키 구분자
local MAXLEN = 240
local TICK = 2.0          -- 실시간 전송 주기
local QUEUE_GAP = 0.15    -- 메시지 사이 간격 (게임 전송 제한 안쪽)
local PT_PER_MSG = 9
local min, max, floor = math.min, math.max, math.floor

local queue, queueRunning = {}, false
local online = {}         -- key → 마지막 HI 시각
local sentN, sentEv = {}, {}   -- 내 세션(start) → 상대에게 보낸 점 · 사건 수  (key..start)
local invites = {}        -- key → 받은 초대 (저장 안 함)
local pendingOut = {}     -- key → 내가 보낸 초대 시각
local idx = {}            -- 상대 key → { start → session }
local dirty = false
local myKey

local function S() return NS.db.settings end
local function partners()
  local s = S()
  s.partners = s.partners or {}
  return s.partners
end
function Y.partners() return partners() end
function Y.isPartner(key) return partners()[key] ~= nil end
function Y.isOnline(key) return online[key] and (GetServerTime() - online[key]) < 600 end

local function clean(v)
  v = tostring(v)
  return (v:gsub("[\29\30\31]", " "))
end

local function normKey(name)
  if not name or name == "" then return nil end
  local n, r = name:match("^(.-)%-(.*)$")
  if not n then
    n = name
    r = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or ""
  end
  r = (r or ""):gsub("%s+", "")
  n = n:sub(1, 1):upper() .. n:sub(2)
  return n .. "-" .. r
end
Y.normKey = normKey

---------------------------------------------------------------- 전송 큐
local function pump()
  local m = table.remove(queue, 1)
  if not m then queueRunning = false return end
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, m.text, "WHISPER", m.to)
  end
  C_Timer.After(QUEUE_GAP, pump)
end

local function send(to, ...)
  local text = table.concat({ ... }, FS)
  queue[#queue + 1] = { to = to, text = text }
  if not queueRunning then
    queueRunning = true
    C_Timer.After(0, pump)
  end
end

local function sendAll(...)
  for key in pairs(partners()) do send(key, ...) end
end

function Y.queued() return #queue end

---------------------------------------------------------------- 부호화
local function encodePoints(s, from, to)
  -- "t,m,x,y,f;..."  (m 이 앞 점과 같으면 비움)
  local parts = {}
  local lastM
  for i = from, to do
    local m = s.m[i]
    parts[#parts + 1] = table.concat({ s.t[i], (m == lastM) and "" or tostring(m), s.x[i], s.y[i], s.fl[i] or "" }, ",")
    lastM = m
  end
  return table.concat(parts, ";")
end

local function decodePoints(s, i0, text, prevM)
  local lastM = prevM
  local i = i0
  for rec in (text .. ";"):gmatch("([^;]*);") do
    if rec ~= "" then
      local t, m, x, y, f = rec:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
      if t then
        m = (m ~= "") and tonumber(m) or lastM
        s.t[i], s.m[i], s.x[i], s.y[i] = tonumber(t), m, tonumber(x), tonumber(y)
        if f ~= "" then s.fl[i] = tonumber(f) else s.fl[i] = nil end
        lastM = m
        i = i + 1
      end
    end
  end
  if i - 1 > s.n then s.n = i - 1 end
  return i - 1
end

local function encodeEvent(e)
  local parts = { clean(e.k), tostring(e.t or 0), tostring(e.i or 0) }
  for k, v in pairs(e) do
    if k ~= "k" and k ~= "t" and k ~= "i" and k ~= "log" then
      local tv = type(v)
      if tv == "string" or tv == "number" then parts[#parts + 1] = clean(k) .. "=" .. clean(v)
      elseif tv == "boolean" then parts[#parts + 1] = clean(k) .. "=" .. (v and "!t" or "!f") end
    end
  end
  return table.concat(parts, KS)
end

local function decodeEvent(text)
  local f = {}
  for p in (text .. KS):gmatch("([^\29]*)\29") do f[#f + 1] = p end
  if #f < 3 then return nil end
  local e = { k = f[1], t = tonumber(f[2]) or 0, i = tonumber(f[3]) or 0 }
  for j = 4, #f do
    local k, v = f[j]:match("^([^=]+)=(.*)$")
    if k then
      if v == "!t" then e[k] = true elseif v == "!f" then e[k] = false
      else e[k] = tonumber(v) or v end
    end
  end
  return e
end

---------------------------------------------------------------- 상대 자료 저장
local function partnerChar(key)
  local p = partners()[key]
  local c = NS.charData(key, true)
  if p and p.class then c.class = p.class end
  c.partner = true
  return c
end

local function findSession(key, start, create, c)
  idx[key] = idx[key] or {}
  local s = idx[key][start]
  if s then return s end
  c = c or partnerChar(key)
  for _, o in ipairs(c.sessions) do
    if o.start == start then idx[key][start] = o return o end
  end
  if not create then return nil end
  s = { start = start, n = 0, t = {}, m = {}, x = {}, y = {}, fl = {}, ev = {}, blind = 0, remote = true }
  table.insert(c.sessions, s)
  table.sort(c.sessions, function(a, b) return a.start < b.start end)
  idx[key][start] = s
  return s
end

---------------------------------------------------------------- 보내기: 세션 조각
local function sendPoints(to, s, from, to_i)
  local i = from
  while i <= to_i do
    local j = min(i + PT_PER_MSG - 1, to_i)
    send(to, "PT", s.start, i, encodePoints(s, i, j))
    i = j + 1
  end
end

local function sendEvents(to, s, from)
  for j = from, #s.ev do
    send(to, "EV", s.start, j, encodeEvent(s.ev[j]))
  end
end

local function sendSessionMeta(to, s)
  local c = NS.db.chars[myKey]
  send(to, "SES", s.start, s.stop or 0, c and c.class or "", c and c.name or "")
end

local function sendCatalog(to)
  local c = NS.db.chars[myKey]
  if not c then return end
  local parts = {}
  local function flush()
    if #parts > 0 then send(to, "CAT", table.concat(parts, ";")) parts = {} end
  end
  for _, s in ipairs(c.sessions) do
    if (s.n or 0) > 0 then
      parts[#parts + 1] = table.concat({ s.start, s.n, s.stop or 0, #s.ev }, ",")
      if #table.concat(parts, ";") > MAXLEN - 30 then flush() end
    end
  end
  flush()
  send(to, "CATEND")
end

---------------------------------------------------------------- 받기
local handlers = {}

handlers.INV = function(from, ver, name)
  if S().noInvites then return end
  if Y.isPartner(from) then send(from, "ACC") return end   -- 이미 짝이면 바로 확인
  invites[from] = { at = GetServerTime(), ver = ver, name = name }
  NS.print(("|cff80ff80%s|r 님이 발자취를 함께 보자고 합니다.  수락: /hp accept %s"):format(from, (from:match("^(.-)%-") or from)))
  if StaticPopup_Show and StaticPopupDialogs then
    StaticPopup_Show("HEROPATH_INVITE", from, nil, { key = from })
  end
end

local function addPartner(key, name)
  local p = partners()
  if not p[key] then
    p[key] = { name = name or (key:match("^(.-)%-") or key), since = GetServerTime() }
    partnerChar(key)
    NS.print(("|cff80ff80%s|r 와 발자취를 함께 봅니다."):format(key))
    dirty = true
  end
  online[key] = GetServerTime()
end

handlers.ACC = function(from)
  if not pendingOut[from] and not Y.isPartner(from) then return end
  pendingOut[from] = nil
  addPartner(from)
  send(from, "HI", NS.VERSION)
  sendCatalog(from)
end

handlers.DEC = function(from)
  if pendingOut[from] then
    pendingOut[from] = nil
    NS.print(("%s 님이 초대를 거절했습니다."):format(from))
  end
end

handlers.BYE = function(from)
  if partners()[from] then
    partners()[from] = nil
    NS.print(("%s 님이 함께 보기를 끊었습니다. (받아 둔 발자취는 남습니다)"):format(from))
    dirty = true
  end
end

local function resetSent(from)
  -- 상대가 새로 접속했으니 '보냈다' 고 여긴 수는 믿을 수 없음 → 카탈로그가 다시 맞춘다
  for k in pairs(sentN) do if k:sub(1, #from + 1) == from .. ":" then sentN[k] = nil end end
  for k in pairs(sentEv) do if k:sub(1, #from + 1) == from .. ":" then sentEv[k] = nil end end
end

handlers.HI = function(from, ver)
  if not Y.isPartner(from) then return end
  online[from] = GetServerTime()
  resetSent(from)
  send(from, "HI2", NS.VERSION)
  sendCatalog(from)
end

handlers.HI2 = function(from, ver)
  if not Y.isPartner(from) then return end
  online[from] = GetServerTime()
  sendCatalog(from)
end

handlers.CAT = function(from, list)
  if not Y.isPartner(from) then return end
  local c = partnerChar(from)
  for rec in (list .. ";"):gmatch("([^;]*);") do
    local start, n, stop, nev = rec:match("^(%d+),(%d+),(%d+),(%d+)$")
    if start then
      start, n, stop, nev = tonumber(start), tonumber(n), tonumber(stop), tonumber(nev)
      local s = findSession(from, start, true, c)
      if stop > 0 and not s.stop then s.stop = stop dirty = true end
      if s.n < n then send(from, "REQ", start, s.n + 1) end
      if #s.ev < nev then send(from, "REQE", start, #s.ev + 1) end
    end
  end
end

handlers.CATEND = function(from) end

handlers.REQ = function(from, start, i0)
  if not Y.isPartner(from) then return end
  start, i0 = tonumber(start), tonumber(i0)
  local c = NS.db.chars[myKey]
  if not c then return end
  for _, s in ipairs(c.sessions) do
    if s.start == start then
      if i0 <= s.n then sendPoints(from, s, i0, s.n) end
      sendSessionMeta(from, s)
      sentN[from .. ":" .. start] = s.n
      return
    end
  end
end

handlers.REQE = function(from, start, j0)
  if not Y.isPartner(from) then return end
  start, j0 = tonumber(start), tonumber(j0)
  local c = NS.db.chars[myKey]
  if not c then return end
  for _, s in ipairs(c.sessions) do
    if s.start == start then
      sendEvents(from, s, j0)
      sentEv[from .. ":" .. start] = #s.ev
      return
    end
  end
end

handlers.PT = function(from, start, i0, text)
  if not Y.isPartner(from) then return end
  start, i0 = tonumber(start), tonumber(i0)
  local s = findSession(from, start, true)
  if i0 > s.n + 1 then
    -- 빠진 조각: 다시 요청 (한 번만, 같은 자리 재요청 폭주 방지)
    if s.reqAt ~= s.n + 1 then s.reqAt = s.n + 1 send(from, "REQ", start, s.n + 1) end
    return
  end
  if i0 <= s.n then return end  -- 이미 있음
  decodePoints(s, i0, text, s.m[s.n])
  for i = i0, s.n do if s.m[i] then NS.rememberMap(s.m[i]) end end
  online[from] = GetServerTime()
  dirty = true
end

handlers.EV = function(from, start, j, text)
  if not Y.isPartner(from) then return end
  start, j = tonumber(start), tonumber(j)
  local s = findSession(from, start, true)
  if j ~= #s.ev + 1 then return end
  local e = decodeEvent(text)
  if e then s.ev[j] = e dirty = true end
end

handlers.SES = function(from, start, stop, class, name)
  if not Y.isPartner(from) then return end
  local c = partnerChar(from)
  if class and class ~= "" then c.class = class end
  if name and name ~= "" then c.name = name end
  local s = findSession(from, tonumber(start), true, c)
  stop = tonumber(stop) or 0
  if stop > 0 then s.stop = stop end
  dirty = true
end

local function onAddonMessage(prefix, text, channel, sender)
  if prefix ~= PREFIX then return end
  local from = normKey(sender)
  if not from or from == myKey then return end
  local f = {}
  for p in (text .. FS):gmatch("([^\31]*)\31") do f[#f + 1] = p end
  local h = handlers[f[1]]
  if h then NS.safe("동기화 " .. f[1], h, from, f[2], f[3], f[4], f[5]) end
end

---------------------------------------------------------------- 실시간 전송
local function liveTick()
  C_Timer.After(TICK, liveTick)
  local R = NS.Record
  local s = R and R.current and R.current()
  if not s or next(partners()) == nil then
    if dirty then dirty = false if NS.Viewer and NS.Viewer.refresh then NS.Viewer.refresh() end end
    return
  end
  for key in pairs(partners()) do
    if Y.isOnline(key) then
      local k = key .. ":" .. s.start
      local n0 = sentN[k]
      if not n0 then
        sendSessionMeta(key, s)
        n0 = 0
      end
      if s.n > n0 then
        sendPoints(key, s, n0 + 1, s.n)
        sentN[k] = s.n
      end
      local e0 = sentEv[k] or 0
      if #s.ev > e0 then
        sendEvents(key, s, e0 + 1)
        sentEv[k] = #s.ev
      end
    end
  end
  if dirty then
    dirty = false
    if NS.Viewer and NS.Viewer.refresh then NS.Viewer.refresh() end
  end
end

---------------------------------------------------------------- 공개 함수
function Y.invite(name)
  local key = normKey(name)
  if not key then NS.print("초대할 캐릭터 이름을 적어 주세요.") return false end
  if key == myKey then NS.print("자기 자신은 초대할 수 없습니다.") return false end
  if Y.isPartner(key) then NS.print(key .. " 와는 이미 함께 보고 있습니다.") return false end
  pendingOut[key] = GetServerTime()
  local c = NS.db.chars[myKey]
  send(key, "INV", NS.VERSION, c and c.name or "")
  NS.print(("|cff80ff80%s|r 에게 함께 보기 초대를 보냈습니다. 상대가 수락하면 연결됩니다."):format(key))
  return true
end

function Y.accept(name)
  local key = name and normKey(name)
  if not key then
    for k in pairs(invites) do key = k break end
  end
  if not key or not invites[key] then NS.print("받은 초대가 없습니다.") return false end
  invites[key] = nil
  addPartner(key, invites[key] and invites[key].name)
  send(key, "ACC")
  send(key, "HI", NS.VERSION)
  return true
end

function Y.decline(name)
  local key = name and normKey(name)
  if not key then for k in pairs(invites) do key = k break end end
  if not key then return false end
  invites[key] = nil
  send(key, "DEC")
  return true
end

function Y.unpair(name)
  local key = normKey(name)
  if not key or not partners()[key] then NS.print("그런 짝이 없습니다: " .. tostring(name)) return false end
  partners()[key] = nil
  send(key, "BYE")
  NS.print(key .. " 와 함께 보기를 끊었습니다. 받아 둔 발자취는 남습니다. (/hp forget <이름> 으로 지움)")
  dirty = true
  return true
end

function Y.forget(name)
  local key = normKey(name)
  if not key or not NS.db.chars[key] or key == myKey then return false end
  NS.db.chars[key] = nil
  idx[key] = nil
  NS.print(key .. " 의 발자취를 지웠습니다.")
  if NS.Viewer and NS.Viewer.refresh then NS.Viewer.refresh() end
  return true
end

function Y.pendingInvites()
  local out = {}
  for k, v in pairs(invites) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function Y.status(key)
  local c = NS.db.chars[key]
  local pts = 0
  if c then for _, s in ipairs(c.sessions) do pts = pts + (s.n or 0) end end
  return Y.isOnline(key) and "접속 중" or "—", pts
end

function Y.hello()
  for key in pairs(partners()) do send(key, "HI", NS.VERSION) end
end

function Y.init()
  myKey = NS.charKey()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
  if StaticPopupDialogs then
    StaticPopupDialogs["HEROPATH_INVITE"] = {
      text = "|cff80ff80%s|r 님이 Hero's Path 발자취를 함께 보자고 합니다.\n수락하면 서로의 이동 경로와 사건이 양쪽 애드온에 저장됩니다.",
      button1 = "수락", button2 = "거절",
      OnAccept = function(self, data) Y.accept(data and data.key) end,
      OnCancel = function(self, data) Y.decline(data and data.key) end,
      timeout = 120, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
  end
  local f = CreateFrame("Frame")
  f:RegisterEvent("CHAT_MSG_ADDON")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:SetScript("OnEvent", function(_, ev, ...)
    if ev == "CHAT_MSG_ADDON" then onAddonMessage(...)
    elseif ev == "PLAYER_ENTERING_WORLD" then
      myKey = NS.charKey() or myKey
      C_Timer.After(5, Y.hello)
    end
  end)
  C_Timer.After(TICK, liveTick)
end

function Y.logout()
  local R = NS.Record
  local s = R and R.current and R.current()
  if not s then return end
  for key in pairs(partners()) do
    if Y.isOnline(key) and C_ChatInfo and C_ChatInfo.SendAddonMessage then
      -- 큐를 거치지 않고 바로 (로그아웃 중엔 타이머가 안 돎)
      local c = NS.db.chars[myKey]
      pcall(C_ChatInfo.SendAddonMessage, PREFIX, table.concat({ "SES", s.start, GetServerTime(), c and c.class or "", c and c.name or "" }, FS), "WHISPER", key)
    end
  end
end
