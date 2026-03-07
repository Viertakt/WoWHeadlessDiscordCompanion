-- WoWHeadlessDiscordCompanion - Vanilla 1.12.1 / Lua 5.0
-- In-game IPC only (no internet). Signed lines over a password-protected addon channel.

WHDC_DB = WHDC_DB or {}

local WHDC = {}
WHDC.defaults = {
  password = "change-me",
  channel = "GUILD",
  channel_name = "WHDC_SYNC",
  channel_pass = "",
  prefix = "WHDC",
  nonce = 0,
  payloads = {},
  relayQueue = {},
  history = {},
  replayWindowSeconds = 180,
  recentFrames = {},
  channelSendQueue = {},
  channelMinInterval = 1.0,
  lastChannelSendAt = 0
}

local function whdc_msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WHDC|r " .. text)
end

local function whdc_trim(text)
  if not text then return "" end
  return string.gsub(text, "^%s*(.-)%s*$", "%1")
end

local function whdc_copy_defaults(dst, src)
  local key
  for key in pairs(src) do
    if type(src[key]) == "table" then
      dst[key] = dst[key] or {}
      whdc_copy_defaults(dst[key], src[key])
    elseif dst[key] == nil then
      dst[key] = src[key]
    end
  end
end

local function whdc_now()
  return date("%Y-%m-%d %H:%M:%S")
end

local function whdc_next_nonce()
  WHDC_DB.nonce = (tonumber(WHDC_DB.nonce) or 0) + 1
  return tostring(WHDC_DB.nonce)
end

local function whdc_sum_bytes(text)
  local total = 0
  local i
  for i = 1, string.len(text) do
    total = total + string.byte(text, i)
  end
  return total
end

-- Required cheap_sig algorithm:
-- sig = sum(bytes((cmd|nonce|payload) + "|" + password)) mod 65535
local function whdc_cheap_sig(cmd, nonce, payload, password)
  local core = cmd .. "|" .. nonce .. "|" .. payload
  return math.mod(whdc_sum_bytes(core .. "|" .. password), 65535)
end

local function whdc_pack_line(cmd, nonce, payload, sig)
  return cmd .. "|" .. nonce .. "|" .. payload .. "|" .. tostring(sig)
end

local function whdc_unpack_line(line)
  local function parse_a(raw)
    local p1 = string.find(raw, "|", 1, true)
    if not p1 then return nil end
    local p2 = string.find(raw, "|", p1 + 1, true)
    if not p2 then return nil end
    local rev = string.reverse(raw)
    local lastFromEnd = string.find(rev, "|", 1, true)
    if not lastFromEnd then return nil end
    local pLast = string.len(raw) - lastFromEnd + 1
    if p2 >= pLast then return nil end

    local cmd = string.sub(raw, 1, p1 - 1)
    local nonce = string.sub(raw, p1 + 1, p2 - 1)
    local payload = string.sub(raw, p2 + 1, pLast - 1)
    local sig = string.sub(raw, pLast + 1)
    return cmd, nonce, payload, sig
  end

  local function parse_b(raw)
    local p1 = string.find(raw, "|", 1, true)
    if not p1 then return nil end
    local p2 = string.find(raw, "|", p1 + 1, true)
    if not p2 then return nil end
    local p3 = string.find(raw, "|", p2 + 1, true)
    if not p3 then return nil end
    local rev = string.reverse(raw)
    local lastFromEnd = string.find(rev, "|", 1, true)
    if not lastFromEnd then return nil end
    local pLast = string.len(raw) - lastFromEnd + 1
    if p3 >= pLast then return nil end

    local cmd = string.sub(raw, p1 + 1, p2 - 1)
    local nonce = string.sub(raw, p2 + 1, p3 - 1)
    local payload = string.sub(raw, p3 + 1, pLast - 1)
    local sig = string.sub(raw, pLast + 1)
    return cmd, nonce, payload, sig
  end

  local cmd, nonce, payload, sig = parse_a(line)
  if cmd then
    return cmd, nonce, payload, sig
  end

  return parse_b(line)
end

local function whdc_is_safe_token(value)
  return value and value ~= "" and not string.find(value, "|", 1, true)
end

local function whdc_prune_recent_frames()
  local now = time()
  local keep = {}
  local i
  for i = 1, table.getn(WHDC_DB.recentFrames) do
    local row = WHDC_DB.recentFrames[i]
    if now - row.at <= WHDC_DB.replayWindowSeconds then
      table.insert(keep, row)
    end
  end
  WHDC_DB.recentFrames = keep
end

local function whdc_frame_seen(line)
  whdc_prune_recent_frames()
  local i
  for i = 1, table.getn(WHDC_DB.recentFrames) do
    if WHDC_DB.recentFrames[i].line == line then
      return true
    end
  end
  table.insert(WHDC_DB.recentFrames, { line = line, at = time() })
  return false
end

local function whdc_write_import(name, payload)
  -- Optional SuperWoW/Turtle hook for import folder handoff.
  local fileName = name .. ".txt"
  local path = "/wow/imports/" .. fileName

  if type(SuperWoW_WriteFile) == "function" then
    SuperWoW_WriteFile(path, payload)
    return true, path
  end

  if type(WriteFile) == "function" then
    WriteFile(path, payload)
    return true, path
  end

  return false, path
end

function WHDC:InitializeDB()
  whdc_copy_defaults(WHDC_DB, self.defaults)
end

function WHDC:SetPassword(password, channel)
  WHDC_DB.password = password
  if channel and channel ~= "" then
    WHDC_DB.channel = string.upper(channel)
  end
  whdc_msg("IPC config updated. Channel=" .. WHDC_DB.channel)
end

function WHDC:SetSyncChannel(name, pass)
  WHDC_DB.channel_name = name
  WHDC_DB.channel_pass = pass or ""
  whdc_msg("Sync channel updated. name=" .. WHDC_DB.channel_name)
end

function WHDC:StorePayload(name, payload)
  WHDC_DB.payloads[name] = {
    payload = payload,
    updated = whdc_now()
  }

  local ok, path = whdc_write_import(name, payload)
  if ok then
    whdc_msg("Stored payload '" .. name .. "' and exported to " .. path)
  else
    whdc_msg("Stored payload '" .. name .. "'. File export API unavailable; kept in SavedVariables.")
  end
end

function WHDC:ListPayloads()
  local found = false
  local key
  for key in pairs(WHDC_DB.payloads) do
    found = true
    whdc_msg("Payload: " .. key .. " (updated " .. WHDC_DB.payloads[key].updated .. ")")
  end
  if not found then
    whdc_msg("No payloads stored.")
  end
end

function WHDC:QueueRelay(cmd, payload)
  payload = payload or ""
  if not whdc_is_safe_token(cmd) then
    return nil, "invalid command token"
  end

  local nonce = whdc_next_nonce()
  local finalCmd = string.upper(cmd)
  local sig = whdc_cheap_sig(finalCmd, nonce, payload, WHDC_DB.password)
  local line = whdc_pack_line(finalCmd, nonce, payload, sig)

  table.insert(WHDC_DB.relayQueue, {
    ts = whdc_now(),
    cmd = finalCmd,
    nonce = nonce,
    payload = payload,
    sig = sig,
    line = line
  })

  table.insert(WHDC_DB.history, {
    ts = whdc_now(),
    line = line
  })

  if type(SendAddonMessage) == "function" then
    SendAddonMessage(WHDC_DB.prefix, line, WHDC_DB.channel)
  end

  return line
end

function WHDC:VerifyLine(line)
  local cmd, nonce, payload, sigStr = whdc_unpack_line(line)
  if not cmd then
    return false, "bad format"
  end

  if not whdc_is_safe_token(cmd) then
    return false, "empty/invalid cmd"
  end

  if not whdc_is_safe_token(nonce) then
    return false, "empty/invalid nonce"
  end

  if not whdc_is_safe_token(sigStr) then
    return false, "empty/invalid sig"
  end

  local expected = whdc_cheap_sig(cmd, nonce, payload, WHDC_DB.password)
  local sig = tonumber(sigStr)
  if not sig then
    return false, "signature not numeric"
  end

  if sig ~= expected then
    return false, "signature mismatch"
  end

  if whdc_frame_seen(line) then
    return false, "replay"
  end

  return true, cmd, nonce, payload
end

function WHDC:SendSyncChannelMessage(message)
  if not message or message == "" then
    return false, "empty payload"
  end

  if type(JoinChannelByName) == "function" then
    JoinChannelByName(WHDC_DB.channel_name, WHDC_DB.channel_pass)
  end

  if type(GetChannelName) ~= "function" or type(SendChatMessage) ~= "function" then
    return false, "chat APIs unavailable"
  end

  local channelId = GetChannelName(WHDC_DB.channel_name)
  if not channelId or type(channelId) ~= "number" or channelId <= 0 then
    return false, "channel unavailable"
  end

  SendChatMessage(message, "CHANNEL", nil, channelId)
  return true
end

function WHDC:QueueSyncChannelMessage(message)
  table.insert(WHDC_DB.channelSendQueue, {
    at = time(),
    text = message
  })
end

function WHDC:ProcessSyncChannelQueue(elapsed)
  WHDC_DB.lastChannelSendAt = (WHDC_DB.lastChannelSendAt or 0) + (elapsed or 0)
  if WHDC_DB.lastChannelSendAt < WHDC_DB.channelMinInterval then
    return
  end

  if table.getn(WHDC_DB.channelSendQueue) == 0 then
    return
  end

  local row = table.remove(WHDC_DB.channelSendQueue, 1)
  WHDC_DB.lastChannelSendAt = 0
  local ok, err = self:SendSyncChannelMessage(row.text)
  if not ok then
    whdc_msg("Sync send failed: " .. err)
  end
end

function WHDC:SendPayload(name)
  local row = WHDC_DB.payloads[name]
  if not row then
    whdc_msg("Unknown payload: " .. name)
    return
  end

  local payload = name .. "=" .. row.payload
  local line = self:QueueRelay("import_payload", payload)
  whdc_msg("Sent signed line: " .. line)
end

function WHDC:RequestPayload(name)
  local line = self:QueueRelay("request_import", name)
  whdc_msg("Sent signed line: " .. line)
end

function WHDC:RunTest()
  local nonce = whdc_next_nonce()
  local payload = "test:" .. tostring(time())
  local sig = whdc_cheap_sig("PING", nonce, payload, WHDC_DB.password)
  local line = whdc_pack_line("PING", nonce, payload, sig)

  table.insert(WHDC_DB.history, {
    ts = whdc_now(),
    line = line,
    sync = true
  })

  self:QueueSyncChannelMessage(line)
  whdc_msg("Queued sync test line for channel '" .. WHDC_DB.channel_name .. "': " .. line)
end

function WHDC:HandleProtocolCommand(cmd, payload)
  if cmd == "PING" then
    self:QueueRelay("PONG", UnitName("player") or "unknown")
    return
  end

  if cmd == "CHANNEL" then
    self:QueueSyncChannelMessage(payload)
    self:QueueRelay("CHANNEL_ACK", "OK")
    return
  end
end

function WHDC:ReceiveIPC(prefix, line, channel, sender)
  if prefix ~= WHDC_DB.prefix then
    return
  end

  local ok, a, b, c = self:VerifyLine(line)
  if not ok then
    whdc_msg("Rejected IPC from " .. (sender or "?") .. ": " .. a)
    return
  end

  local cmd = a
  local nonce = b
  local payload = c
  whdc_msg("IPC recv " .. cmd .. " nonce=" .. nonce .. " from " .. (sender or "?") .. " on " .. (channel or "?"))

  table.insert(WHDC_DB.history, {
    ts = whdc_now(),
    line = line,
    recv = true,
    sender = sender,
    channel = channel,
    cmd = cmd,
    payload = payload
  })

  self:HandleProtocolCommand(cmd, payload)
end

function WHDC:ReceiveSyncChannel(msg, channelName, sender)
  if string.upper(channelName or "") ~= string.upper(WHDC_DB.channel_name or "") then
    return
  end

  local ok, a, b, c = self:VerifyLine(msg)
  if not ok then
    return
  end

  local cmd = a
  local nonce = b
  local payload = c
  whdc_msg("SYNC recv " .. cmd .. " nonce=" .. nonce .. " from " .. (sender or "?"))

  self:HandleProtocolCommand(cmd, payload)
end

function WHDC:PrintHelp()
  whdc_msg("/whdc test - queue signed test line to sync channel")
  whdc_msg("/whdc sync <channel_name> [channel_pass] - set sync chat channel")
  whdc_msg("/whdc gui - show command GUI")
end

function WHDC:HandleCommand(msg)
  msg = whdc_trim(msg)
  if msg == "" then
    self:PrintHelp()
    return
  end

  local cmd, rest = string.match(msg, "^(%S+)%s*(.-)$")
  cmd = string.lower(cmd or "")

  if cmd == "test" then
    self:RunTest()
    return
  end

  if cmd == "sync" then
    local name, pass = string.match(rest, "^(%S+)%s*(.*)$")
    if not name then
      whdc_msg("Usage: /whdc sync <channel_name> [channel_pass]")
      return
    end
    self:SetSyncChannel(name, whdc_trim(pass or ""))
    return
  end

  if cmd == "gui" then
    WHDC_ShowGUI()
    return
  end

  self:PrintHelp()
end

function WHDC_CreateGUI()
  if WHDC_Frame then return end

  local frame = CreateFrame("Frame", "WHDC_Frame", UIParent)
  frame:SetWidth(460)
  frame:SetHeight(250)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
  })
  frame:Hide()

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", frame, "TOP", 0, -16)
  title:SetText("WHDC Sync Settings")

  local joinHelp = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  joinHelp:SetPoint("TOP", frame, "TOP", 0, -34)
  joinHelp:SetText("Save settings, then join the sync channel and send a test line")

  local channelNameLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  channelNameLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, -58)
  channelNameLabel:SetText("Channel Name")

  local channelNameInput = CreateFrame("EditBox", "WHDC_ChannelNameInput", frame, "InputBoxTemplate")
  channelNameInput:SetAutoFocus(false)
  channelNameInput:SetWidth(270)
  channelNameInput:SetHeight(24)
  channelNameInput:SetPoint("LEFT", channelNameLabel, "RIGHT", 20, 0)

  local channelPassLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  channelPassLabel:SetPoint("TOPLEFT", channelNameLabel, "BOTTOMLEFT", 0, -24)
  channelPassLabel:SetText("Channel Pass")

  local channelPassInput = CreateFrame("EditBox", "WHDC_ChannelPassInput", frame, "InputBoxTemplate")
  channelPassInput:SetAutoFocus(false)
  channelPassInput:SetWidth(270)
  channelPassInput:SetHeight(24)
  channelPassInput:SetPoint("LEFT", channelPassLabel, "RIGHT", 26, 0)

  local passwordLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  passwordLabel:SetPoint("TOPLEFT", channelPassLabel, "BOTTOMLEFT", 0, -24)
  passwordLabel:SetText("IPC Password")

  local passwordInput = CreateFrame("EditBox", "WHDC_PasswordInput", frame, "InputBoxTemplate")
  passwordInput:SetAutoFocus(false)
  passwordInput:SetWidth(270)
  passwordInput:SetHeight(24)
  passwordInput:SetPoint("LEFT", passwordLabel, "RIGHT", 24, 0)

  local saveBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  saveBtn:SetWidth(100)
  saveBtn:SetHeight(24)
  saveBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 24, 26)
  saveBtn:SetText("Save")

  local joinBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  joinBtn:SetWidth(100)
  joinBtn:SetHeight(24)
  joinBtn:SetPoint("LEFT", saveBtn, "RIGHT", 10, 0)
  joinBtn:SetText("Join")

  local testBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  testBtn:SetWidth(100)
  testBtn:SetHeight(24)
  testBtn:SetPoint("LEFT", joinBtn, "RIGHT", 10, 0)
  testBtn:SetText("Test")

  local closeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  closeBtn:SetWidth(100)
  closeBtn:SetHeight(24)
  closeBtn:SetPoint("LEFT", testBtn, "RIGHT", 10, 0)
  closeBtn:SetText("Close")

  local function saveSettingsFromGUI()
    local channelName = whdc_trim(channelNameInput:GetText())
    local channelPass = whdc_trim(channelPassInput:GetText())
    local password = whdc_trim(passwordInput:GetText())

    if channelName ~= "" then
      WHDC_DB.channel_name = channelName
    end
    WHDC_DB.channel_pass = channelPass

    if password ~= "" then
      WHDC_DB.password = password
    end

    whdc_msg("Settings saved to SavedVariables (WTF). channel=" .. WHDC_DB.channel_name)
  end

  saveBtn:SetScript("OnClick", function()
    saveSettingsFromGUI()
  end)

  joinBtn:SetScript("OnClick", function()
    saveSettingsFromGUI()
    if type(JoinChannelByName) == "function" then
      JoinChannelByName(WHDC_DB.channel_name, WHDC_DB.channel_pass)
      whdc_msg("Join requested for sync channel '" .. WHDC_DB.channel_name .. "'.")
    else
      whdc_msg("JoinChannelByName API unavailable.")
    end
  end)

  testBtn:SetScript("OnClick", function()
    saveSettingsFromGUI()
    WHDC:RunTest()
  end)

  closeBtn:SetScript("OnClick", function()
    frame:Hide()
  end)

  frame:SetScript("OnShow", function()
    channelNameInput:SetText(WHDC_DB.channel_name or "")
    channelPassInput:SetText(WHDC_DB.channel_pass or "")
    passwordInput:SetText(WHDC_DB.password or "")
  end)
end

function WHDC_ShowGUI()
  if not WHDC_Frame then
    WHDC_CreateGUI()
  end
  WHDC_Frame:Show()
end

SLASH_WHDC1 = "/whdc"
SlashCmdList["WHDC"] = function(msg)
  WHDC:HandleCommand(msg)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("VARIABLES_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("CHAT_MSG_CHANNEL")
eventFrame:SetScript("OnUpdate", function()
  WHDC:ProcessSyncChannelQueue(arg1 or 0)
end)
eventFrame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    WHDC:InitializeDB()
    whdc_msg("Loaded. /whdc for commands. Uses in-game signed IPC only.")
  elseif event == "CHAT_MSG_ADDON" then
    -- Vanilla handler args: arg1=prefix, arg2=message, arg3=channel, arg4=sender
    WHDC:ReceiveIPC(arg1, arg2, arg3, arg4)
  elseif event == "CHAT_MSG_CHANNEL" then
    -- Vanilla handler args: arg1=message, arg8=channel name, arg4=sender
    WHDC:ReceiveSyncChannel(arg1, arg8, arg4)
  end
end)
