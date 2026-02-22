local addonName, addonTable = ...

local Comm = {}
addonTable.Comm = Comm

Comm.PREFIX = "FW"
Comm.REQUEST_TIMEOUT = 5

local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate", true)
local CHANNEL_NAME = "FleshWoundComm"
local channelJoinedOnce = false

-- Midnight helpers
local function IsSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

local function InInstance()
  local inInstance = IsInInstance()
  return inInstance
end

local function CommAllowed()
  -- Midnight rules: in an instance, addons cannot send comms to other players
  -- and chat payloads may be Secret Values. Bail out of comm paths.
  return not InInstance()
end

--------------------------------------------------------------------------------
-- Profile Request and Handling
--------------------------------------------------------------------------------

function Comm:RequestProfile(targetPlayer)
  if not targetPlayer or targetPlayer == "" then return end
  if not CommAllowed() then
    addonTable.Utils.FW_Print("FleshWound: sharing is disabled inside instances in Midnight.", true)
    return
  end

  local registry = addonTable.Registry
  if registry and registry:IsUserOnline(targetPlayer) then
    ChatThrottleLib:SendAddonMessage("NORMAL", self.PREFIX, "REQUEST_PROFILE", "WHISPER", targetPlayer)
  else
    if registry then registry:SendQuery() end
    C_Timer.After(self.REQUEST_TIMEOUT, function()
      if registry and registry:IsUserOnline(targetPlayer) then
        ChatThrottleLib:SendAddonMessage("NORMAL", self.PREFIX, "REQUEST_PROFILE", "WHISPER", targetPlayer)
      end
    end)
  end
end

function Comm:SendProfileData(targetPlayer, profileName)
  if not targetPlayer or not profileName then return end
  if not CommAllowed() then
    addonTable.Utils.FW_Print("FleshWound: sharing is disabled inside instances in Midnight.", true)
    return
  end

  local data = addonTable.FleshWoundData.profiles[profileName]
  if not data then return end

  local serialized = self:SerializeProfile(data)
  local encoded = serialized
  local compressed = false

  if #serialized > 255 and LibDeflate then
    encoded = LibDeflate:CompressDeflate(serialized)
    encoded = LibDeflate:EncodeForWoWAddonChannel(encoded)
    compressed = true
  end

  local cmd = compressed and "PROFILE_DATA_COMPRESSED" or "PROFILE_DATA"
  local message = string.format("%s:%s:%s", cmd, profileName, encoded)

  if #message <= 255 then
    ChatThrottleLib:SendAddonMessage("NORMAL", self.PREFIX, message, "WHISPER", targetPlayer)
    return
  end

  local partCmd = cmd .. "_PART"
  local chunkSize = 200
  local totalParts = math.ceil(#encoded / chunkSize)

  for i = 1, totalParts do
    local chunk = encoded:sub((i - 1) * chunkSize + 1, i * chunkSize)
    local partMsg = string.format("%s:%s:%d:%d:%s", partCmd, profileName, totalParts, i, chunk)
    ChatThrottleLib:SendAddonMessage("NORMAL", self.PREFIX, partMsg, "WHISPER", targetPlayer)
  end
end

function Comm:SerializeProfile(profileData)
  local woundData = profileData.woundData or {}
  return AceSerializer:Serialize(woundData)
end

function Comm:DeserializeProfile(cmd, profileName, payload, sender)
  self.partialMessages = self.partialMessages or {}
  local profileData = { woundData = {} }
  local libdeflate = LibStub("LibDeflate", true)

  if cmd == "PROFILE_DATA" or cmd == "PROFILE_DATA_COMPRESSED" then
    local data = payload or ""

    if cmd == "PROFILE_DATA_COMPRESSED" and libdeflate then
      data = libdeflate:DecodeForWoWAddonChannel(data)
      data = data and libdeflate:DecompressDeflate(data)
      if not data then
        addonTable.Utils.FW_Print("Failed to decompress profile from " .. (sender or "unknown"), true)
        return profileData
      end
    end

    if data ~= "" then
      local success, woundData = AceSerializer:Deserialize(data)
      if success and type(woundData) == "table" then
        profileData.woundData = woundData
      end
    end

    return profileData

  elseif cmd == "PROFILE_DATA_PART" or cmd == "PROFILE_DATA_COMPRESSED_PART" then
    local totalParts, index, part = payload.total, payload.index, payload.data
    if not (totalParts and index and part) then return nil end

    local key = (sender or "?") .. ":" .. profileName
    local entry = self.partialMessages[key]
    if not entry then
      entry = {
        total = totalParts,
        parts = {},
        isCompressed = (cmd == "PROFILE_DATA_COMPRESSED_PART"),
        start = GetTime()
      }
      self.partialMessages[key] = entry
    end

    if totalParts ~= entry.total then
      addonTable.Utils.FW_Print("Profile transfer mismatch from " .. (sender or "unknown"), true)
      self.partialMessages[key] = nil
      return nil
    end

    entry.parts[index] = part

    if GetTime() - entry.start > 30 then
      addonTable.Utils.FW_Print("Profile transfer from " .. (sender or "unknown") .. " timed out", true)
      self.partialMessages[key] = nil
      return nil
    end

    local received = 0
    for i = 1, entry.total do
      if entry.parts[i] then received = received + 1 end
    end

    if received == entry.total then
      local combined = table.concat(entry.parts)
      self.partialMessages[key] = nil
      return self:DeserializeProfile(entry.isCompressed and "PROFILE_DATA_COMPRESSED" or "PROFILE_DATA", profileName, combined, sender)
    end

    return nil
  end

  return profileData
end

--------------------------------------------------------------------------------
-- Addon Message Handling
--------------------------------------------------------------------------------

function Comm:OnChatMsgAddon(prefixMsg, msg, channel, sender)
  if prefixMsg ~= self.PREFIX then return end

  -- Defensive: bail inside instances, comms are blocked anyway in Midnight
  if not CommAllowed() then return end

  if msg == "REQUEST_PROFILE" then
    local currentProfile = addonTable.FleshWoundData.currentProfile
    self:SendProfileData(sender, currentProfile)
  else
    local cmd, profileName, rest = strsplit(":", msg, 3)

    if cmd == "PROFILE_DATA" or cmd == "PROFILE_DATA_COMPRESSED" then
      local profileData = self:DeserializeProfile(cmd, profileName, rest, sender)
      addonTable:OpenReceivedProfile(profileName, profileData)

    elseif cmd == "PROFILE_DATA_PART" or cmd == "PROFILE_DATA_COMPRESSED_PART" then
      local total, index, part = strsplit(":", rest, 3)
      local profileData = self:DeserializeProfile(cmd, profileName, {
        total = tonumber(total),
        index = tonumber(index),
        data = part
      }, sender)

      if profileData then
        addonTable:OpenReceivedProfile(profileName, profileData)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Channel Management
--------------------------------------------------------------------------------

function Comm:Initialize()
  C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
  self:JoinChannel()
end

function Comm:GetChannel()
  local channelId = GetChannelName(CHANNEL_NAME)
  if channelId ~= 0 then return channelId end
  return nil
end

function Comm:OnChannelJoined()
  if not channelJoinedOnce then
    channelJoinedOnce = true
    if addonTable.Registry and addonTable.Registry.Initialize then
      addonTable.Registry:Initialize()
    end
  end
end

function Comm:OnChannelFailed(reason)
  C_Timer.After(10, function() self:JoinChannel() end)
end

function Comm:OnChannelLeft()
  C_Timer.After(1, function() self:JoinChannel() end)
end

function Comm:JoinChannel()
  -- Do not attempt to join/maintain the channel in instances
  if not CommAllowed() then return end

  if self.channelJoiner then return end
  if self:GetChannel() then
    self:OnChannelJoined()
    return
  end

  self.channelJoiner = C_Timer.NewTicker(1, function()
    if not CommAllowed() then
      if self.channelJoiner then
        self.channelJoiner:Cancel()
        self.channelJoiner = nil
      end
      return
    end

    if self:GetChannel() then
      if self.channelJoiner then
        self.channelJoiner:Cancel()
        self.channelJoiner = nil
      end
      self:OnChannelJoined()
    else
      JoinTemporaryChannel(CHANNEL_NAME, nil)
    end
  end)
end

--------------------------------------------------------------------------------
-- Event Handling
--------------------------------------------------------------------------------

local channelNoticeFrame = CreateFrame("Frame")
channelNoticeFrame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
channelNoticeFrame:SetScript("OnEvent", function(self, event, ...)
  local text, _, _, _, _, _, _, _, channelName = ...

  -- Midnight: inside instances, these can be Secret Values, so comparisons can error
  if IsSecret(text) or IsSecret(channelName) then return end

  if channelName == CHANNEL_NAME then
    if text == "YOU_JOINED" or text == "YOU_CHANGED" then
      Comm:OnChannelJoined()
    elseif text == "WRONG_PASSWORD" or text == "BANNED" then
      Comm:OnChannelFailed(text)
    elseif text == "YOU_LEFT" then
      Comm:OnChannelLeft()
    end
  end
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "CHAT_MSG_ADDON" then
    Comm:OnChatMsgAddon(...)
  end
end)

return Comm