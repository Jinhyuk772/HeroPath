-- Hero's Path — 미니맵 단추 + 게임 설정(AddOns 탭) 패널
local ADDON, NS = ...
local O = {}
NS.Options = O

local function S() return NS.db.settings end

-- ───────── 미니맵 단추 ─────────
local btn
local function placeButton()
  local a = math.rad(S().minimapAngle or 215)
  local r = 80
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function makeButton()
  if btn or not Minimap then return end
  btn = CreateFrame("Button", "HeroPathMinimapButton", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetHighlightTexture("Interface/Minimap/UI-Minimap-ZoomButton-Highlight")
  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface/Minimap/MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")
  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface/Minimap/UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture("Interface/Minimap/MinimapArrow")
  icon:SetPoint("TOPLEFT", 8, -7)
  btn.icon = icon
  btn:SetScript("OnClick", function(_, b)
    if b == "RightButton" then O.openSettings() else NS.Toggle() end
  end)
  btn:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local sc = Minimap:GetEffectiveScale()
      S().minimapAngle = math.deg(math.atan2(cy / sc - my, cx / sc - mx))
      placeButton()
    end)
  end)
  btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Hero's Path " .. NS.VERSION)
    GameTooltip:AddLine("왼쪽: 발자취 창 · 오른쪽: 설정 · 끌기: 자리 옮김", 1, 1, 1)
    if NS.Record and NS.Record.status then GameTooltip:AddLine(NS.Record.status(), 0.7, 0.9, 0.7) end
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  placeButton()
end

function O.updateButton()
  if not btn then makeButton() end
  if not btn then return end
  local c = NS.charData(NS.charKey())
  local rgb = c and NS.charColor(c) or NS.COLORS[1]
  btn.icon:SetVertexColor(rgb[1], rgb[2], rgb[3])
  if S().hideMinimap then btn:Hide() else btn:Show() end
end

-- ───────── 설정 패널 ─────────
local panel, category
local function fs(frame, key, template, point)
  if type(rawget(frame, key)) ~= "table" then
    frame[key] = frame:CreateFontString(nil, "ARTWORK", template)
    frame[key]:SetPoint(unpack(point))
  end
  return frame[key]
end

local function check(parent, y, label, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  cb:SetPoint("TOPLEFT", 16, y)
  fs(cb, "Text", "GameFontHighlight", { "LEFT", cb, "RIGHT", 4, 0 }):SetText(label)
  cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
  cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  return cb
end

local function slider(parent, y, label, lo, hi, step, fmt, get, set)
  local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
  s:SetPoint("TOPLEFT", 24, y)
  s:SetWidth(240)
  s:SetMinMaxValues(lo, hi)
  s:SetValueStep(step)
  s:SetObeyStepOnDrag(true)
  fs(s, "Low", "GameFontHighlightSmall", { "TOPLEFT", s, "BOTTOMLEFT", 0, 2 }):SetText(tostring(lo))
  fs(s, "High", "GameFontHighlightSmall", { "TOPRIGHT", s, "BOTTOMRIGHT", 0, 2 }):SetText(tostring(hi))
  fs(s, "Text", "GameFontNormal", { "BOTTOM", s, "TOP", 0, 2 })
  s:SetScript("OnShow", function(self) self:SetValue(get()); self.Text:SetText(fmt(get())) end)
  s:SetScript("OnValueChanged", function(self, v) set(v); self.Text:SetText(fmt(v)) end)
  return s
end

local function makePanel()
  if panel then return end
  panel = CreateFrame("Frame", "HeroPathOptionsPanel")
  panel.name = "Hero's Path"
  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("Hero's Path " .. NS.VERSION .. " — 용사의 발자취")
  local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetWidth(540); sub:SetJustifyH("LEFT")
  sub:SetText("어디로 어떻게 걸었는지 별도 창에서 돌려 봅니다. 창은 /hp, 미니맵 단추, 또는 단축키(키 설정 → Hero's Path)로 엽니다.")

  local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  open:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -12)
  open:SetSize(160, 24)
  open:SetText("발자취 창 열기")
  open:SetScript("OnClick", function() NS.Toggle() end)

  local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  status:SetPoint("LEFT", open, "RIGHT", 12, 0)
  panel.status = status

  check(panel, -112, "미니맵 단추 보이기",
    function() return not S().hideMinimap end,
    function(v) S().hideMinimap = not v; O.updateButton() end)
  check(panel, -140, "퀘스트 완료도 표식으로 남김",
    function() return S().trackQuests end,
    function(v) S().trackQuests = v end)
  slider(panel, -196, "위치 확인 주기", 0.2, 5, 0.1,
    function(v) return ("위치 확인 주기 %.1f초"):format(v) end,
    function() return S().interval end,
    function(v) S().interval = math.floor(v * 10 + 0.5) / 10 end)
  slider(panel, -250, "골드 변화 표식 기준", 10, 5000, 10,
    function(v) return ("골드 변화 표식 기준 %d은 이상"):format(v) end,
    function() return S().goldStep or 100 end,
    function(v) S().goldStep = math.floor(v + 0.5) end)

  -- ───── 둘이 보기 ─────
  local pairTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  pairTitle:SetPoint("TOPLEFT", 16, -300)
  pairTitle:SetText("둘이 보기")
  local pairNote = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  pairNote:SetPoint("TOPLEFT", pairTitle, "BOTTOMLEFT", 0, -4)
  pairNote:SetWidth(540); pairNote:SetJustifyH("LEFT")
  pairNote:SetText("상대 캐릭터를 초대하고 상대가 수락해야만 발자취가 오갑니다. 같은 서버 · 같은 진영, 둘 다 이 애드온이 있어야 합니다.")

  local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
  box:SetSize(180, 22)
  box:SetPoint("TOPLEFT", pairNote, "BOTTOMLEFT", 6, -10)
  box:SetAutoFocus(false)
  box:SetMaxLetters(40)
  local inviteBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  inviteBtn:SetSize(90, 22)
  inviteBtn:SetPoint("LEFT", box, "RIGHT", 8, 0)
  inviteBtn:SetText("초대 보내기")
  local function doInvite()
    local name = box:GetText()
    if name and name ~= "" and NS.Sync.invite(name) then box:SetText("") end
    panel.refreshPartners()
  end
  inviteBtn:SetScript("OnClick", doInvite)
  box:SetScript("OnEnterPressed", doInvite)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local targetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  targetBtn:SetSize(110, 22)
  targetBtn:SetPoint("LEFT", inviteBtn, "RIGHT", 6, 0)
  targetBtn:SetText("대상 초대")
  targetBtn:SetScript("OnClick", function()
    if UnitExists("target") and UnitIsPlayer("target") then
      local n, r = UnitName("target")
      box:SetText(r and r ~= "" and (n .. "-" .. r) or n)
      doInvite()
    else
      NS.print("플레이어를 대상으로 잡고 눌러 주세요.")
    end
  end)
  check(panel, -392, "초대 받기 (끄면 아무도 초대할 수 없음)",
    function() return not S().noInvites end,
    function(v) S().noInvites = not v end)

  panel.rows = {}
  local function row(i)
    local r = panel.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, panel)
    r:SetSize(540, 22)
    r:SetPoint("TOPLEFT", 24, -424 - (i - 1) * 24)
    r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    r.text:SetPoint("LEFT", 0, 0)
    r.text:SetWidth(330); r.text:SetJustifyH("LEFT")
    r.btn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.btn:SetSize(70, 20)
    r.btn:SetPoint("LEFT", r.text, "RIGHT", 8, 0)
    r.btn2 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.btn2:SetSize(70, 20)
    r.btn2:SetPoint("LEFT", r.btn, "RIGHT", 4, 0)
    panel.rows[i] = r
    return r
  end

  function panel.refreshPartners()
    local i = 0
    for _, key in ipairs(NS.Sync.pendingInvites()) do
      i = i + 1
      local r = row(i)
      r.text:SetText(("|cffffd080초대 받음|r  %s"):format(key))
      r.btn:SetText("수락"); r.btn:SetScript("OnClick", function() NS.Sync.accept(key) panel.refreshPartners() end)
      r.btn2:SetText("거절"); r.btn2:Show(); r.btn2:SetScript("OnClick", function() NS.Sync.decline(key) panel.refreshPartners() end)
      r:Show()
    end
    local keys = {}
    for key in pairs(NS.Sync.partners()) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      i = i + 1
      local r = row(i)
      local st, pts = NS.Sync.status(key)
      local c = NS.db.chars[key]
      local col = c and NS.charColor(c) or { 1, 1, 1 }
      r.text:SetText(("|cff%02x%02x%02x#|r %s  ·  %s  ·  받아 둔 점 %d"):format(col[1] * 255, col[2] * 255, col[3] * 255, key, st, pts))
      r.btn:SetText("해제"); r.btn:SetScript("OnClick", function() NS.Sync.unpair(key) panel.refreshPartners() end)
      r.btn2:Hide()
      r:Show()
    end
    if i == 0 then
      i = 1
      local r = row(1)
      r.text:SetText("|cff808080아직 함께 보는 사람이 없습니다.|r")
      r.btn:Hide(); r.btn2:Hide()
      r:Show()
    else
      for _, r in ipairs(panel.rows) do r.btn:Show() end
    end
    for j = i + 1, #panel.rows do panel.rows[j]:Hide() end
    if NS.Sync.queued() > 0 then
      status:SetText(status:GetText() .. ("  |cffa0a0a0(보내는 중 %d)|r"):format(NS.Sync.queued()))
    end
  end

  local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 16, -540)
  help:SetWidth(540); help:SetJustifyH("LEFT")
  help:SetText("선 색: 발자취 창의 캐릭터 이름 옆 색 네모, 또는 /hp color [캐릭] <색>\n기록 지우기: /hp wipe confirm")

  panel:SetScript("OnShow", function()
    local chars, sessions, points, events = NS.stats()
    status:SetText(("캐릭터 %d · 세션 %d · 점 %d · 사건 %d"):format(chars, sessions, points, events))
    panel.refreshPartners()
  end)
  panel:SetScript("OnUpdate", function(self, el)
    self.acc = (self.acc or 0) + el
    if self.acc > 3 then self.acc = 0 panel.refreshPartners() end
  end)

  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    category.ID = panel.name
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

function O.openSettings()
  makePanel()
  if Settings and Settings.OpenToCategory and category then
    Settings.OpenToCategory(category.ID)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
  end
end

function O.init()
  makePanel()
  O.updateButton()
end
