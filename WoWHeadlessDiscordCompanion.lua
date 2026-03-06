-- WoWHeadlessDiscordCompanion - Vanilla 1.12.1 / Lua 5.0
-- In-game IPC only (no internet). Signed lines over a password-protected addon channel.

WHDC_DB = WHDC_DB or {}

local WHDC = {}
WHDC.defaults = {
  password = "change-me",
  channel = "GUILD",
  prefix = "WHDC",
  nonce = 0,
  payloads = {},
  relayQueue = {},
  history = {}
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
  return string.match(line, "^([^|]+)|([^|]+)|([^|]*)|([^|]+)$")
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
  local nonce = whdc_next_nonce()
  local sig = whdc_cheap_sig(cmd, nonce, payload, WHDC_DB.password)
  local line = whdc_pack_line(cmd, nonce, payload, sig)

  table.insert(WHDC_DB.relayQueue, {
    ts = whdc_now(),
    cmd = cmd,
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

  local expected = whdc_cheap_sig(cmd, nonce, payload, WHDC_DB.password)
  local sig = tonumber(sigStr)
  if not sig then
    return false, "signature not numeric"
  end

  if sig ~= expected then
    return false, "signature mismatch"
  end

  return true, cmd, nonce, payload
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
  local line = self:QueueRelay("test", "ok=true")
  whdc_msg("Sent test line: " .. line)
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
end

function WHDC:PrintHelp()
  whdc_msg("/whdc pwd <password> [channel] - set password + channel (GUILD/RAID/PARTY/WHISPER)")
  whdc_msg("/whdc store <name> <payload> - store payload and export to /wow/imports when API exists")
  whdc_msg("/whdc list - list stored payloads")
  whdc_msg("/whdc send <name> - send signed import_payload line")
  whdc_msg("/whdc pull <name> - send signed request_import line")
  whdc_msg("/whdc test - send signed test line")
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

  if cmd == "pwd" then
    local password, channel = string.match(rest, "^(%S+)%s*(.*)$")
    if not password then
      whdc_msg("Usage: /whdc pwd <password> [channel]")
      return
    end
    channel = whdc_trim(channel)
    if channel == "" then channel = nil end
    self:SetPassword(password, channel)
    return
  end

  if cmd == "store" then
    local name, payload = string.match(rest, "^(%S+)%s+(.+)$")
    if not name then
      whdc_msg("Usage: /whdc store <name> <payload>")
      return
    end
    self:StorePayload(name, payload)
    return
  end

  if cmd == "list" then
    self:ListPayloads()
    return
  end

  if cmd == "send" then
    local name = string.match(rest, "^(%S+)$")
    if not name then
      whdc_msg("Usage: /whdc send <name>")
      return
    end
    self:SendPayload(name)
    return
  end

  if cmd == "pull" then
    local name = string.match(rest, "^(%S+)$")
    if not name then
      whdc_msg("Usage: /whdc pull <name>")
      return
    end
    self:RequestPayload(name)
    return
  end

  if cmd == "test" then
    self:RunTest()
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
  frame:SetWidth(420)
  frame:SetHeight(200)
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
  title:SetText("WHDC Command Console")

  local editBox = CreateFrame("EditBox", "WHDC_CommandInput", frame, "InputBoxTemplate")
  editBox:SetAutoFocus(false)
  editBox:SetWidth(340)
  editBox:SetHeight(24)
  editBox:SetPoint("TOP", frame, "TOP", 0, -50)
  editBox:SetText("pwd change-me GUILD")

  local runBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  runBtn:SetWidth(120)
  runBtn:SetHeight(24)
  runBtn:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", 0, -14)
  runBtn:SetText("Run")

  local testBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  testBtn:SetWidth(120)
  testBtn:SetHeight(24)
  testBtn:SetPoint("LEFT", runBtn, "RIGHT", 12, 0)
  testBtn:SetText("Test")

  local closeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  closeBtn:SetWidth(120)
  closeBtn:SetHeight(24)
  closeBtn:SetPoint("LEFT", testBtn, "RIGHT", 12, 0)
  closeBtn:SetText("Close")

  runBtn:SetScript("OnClick", function()
    local text = whdc_trim(editBox:GetText())
    if text ~= "" then
      WHDC:HandleCommand(text)
    end
  end)

  testBtn:SetScript("OnClick", function()
    WHDC:RunTest()
  end)

  closeBtn:SetScript("OnClick", function()
    frame:Hide()
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
eventFrame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    WHDC:InitializeDB()
    whdc_msg("Loaded. /whdc for commands. Uses in-game signed IPC only.")
  elseif event == "CHAT_MSG_ADDON" then
    -- Vanilla handler args: arg1=prefix, arg2=message, arg3=channel, arg4=sender
    WHDC:ReceiveIPC(arg1, arg2, arg3, arg4)
  end
end)
