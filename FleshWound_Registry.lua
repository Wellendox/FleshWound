local addonName, addonTable = ...
local Utils = addonTable.Utils
local L = addonTable.L or {}
local Registry = {}
local function IsSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

local function InInstance()
  local inInstance = IsInInstance()
  return inInstance
end

local function CommAllowed()
  return not InInstance()
end
addonTable.Registry = Registry

Registry.PREFIX = "FW"
Registry.EVENT_HELLO = "HELLO"
Registry.EVENT_QUERY = "QUERY"
Registry.users = {}
Registry.newVersionNotified = false
Registry.fetchingUsers = false
Registry.usersFetched = false
Registry.fetchTimer = nil
Registry.CHANNEL_NAME = "FleshWoundComm"
-- Users not seen for this many seconds will be purged from the registry.
Registry.USER_EXPIRATION = 3600 -- 1 hour

--- Retrieves the local addon's version.
-- @return string The local version string.
function Registry:GetLocalVersion()
    return Utils.GetAddonVersion()
end

--- Sends a HELLO message containing the local version.
-- @param target string (optional) The target player to respond to.
function Registry:SendHello(target)
    if not CommAllowed() then return end
    local version = self:GetLocalVersion()
    local msg = self.EVENT_HELLO .. ":" .. version
    if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
        local channel = addonTable.Comm and addonTable.Comm:GetChannel()
        if channel then
            ChatThrottleLib:SendAddonMessage("ALERT", self.PREFIX, msg, "CHANNEL", channel)
        end
    else
        ChatThrottleLib:SendAddonMessage("ALERT", self.PREFIX, msg, "YELL", nil)
    end
end

--- Sends a QUERY message to request version information.
-- @param target string (optional) The target player for the query.
function Registry:SendQuery(target)
    if not CommAllowed() then return end
    local msg = self.EVENT_QUERY
    if target and target ~= "" then
        -- Send a targeted query as a whisper
        ChatThrottleLib:SendAddonMessage("ALERT", self.PREFIX, msg, "WHISPER", target)
    else
        if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
            local channel = addonTable.Comm and addonTable.Comm:GetChannel()
            if channel then
                ChatThrottleLib:SendAddonMessage("ALERT", self.PREFIX, msg, "CHANNEL", channel)
            end
        else
            ChatThrottleLib:SendAddonMessage("ALERT", self.PREFIX, msg, "YELL", nil)
        end
    end
end


--- Checks if a user is online.
---@param playerName string The name of the player to check.
---@return boolean True if the player is online, false otherwise.
function Registry:IsUserOnline(playerName)
    if not playerName then return false end
    local key = Utils.ToLower(playerName)
    return self.users[key] ~= nil
end


--- Handles incoming addon messages.
-- Processes both QUERY and HELLO messages from other users.
-- @param prefix string The addon message prefix.
-- @param msg string The message payload.
-- @param channel string The channel over which the message was received.
-- @param sender string The sender's name.
function Registry:OnChatMsgAddon(prefix, msg, channel, sender)
    if prefix ~= self.PREFIX then
        return
    end

    local player = Utils.NormalizePlayerName(sender)
    if not player then
        return
    end

    local event, payload = strsplit(":", msg, 2)

    if event == self.EVENT_QUERY then
        self:SendHello(player)
    elseif event == self.EVENT_HELLO then
        local remoteVersion = payload or "0.0.0"
        self.users[Utils.ToLower(player)] = { version = remoteVersion, lastSeen = time() }

        local localVersion = self:GetLocalVersion()
        local cmpResult = Utils.VersionCompare(localVersion, remoteVersion)
        if not self.newVersionNotified and cmpResult < 0 then
            self.newVersionNotified = true
            Utils.FW_Print(string.format(L.NEW_VERSION_AVAILABLE, remoteVersion, localVersion), true)
        end
        -- self:DisplayUserCount()
    end
end

--- Displays the count of online users.
-- Calculates the number of users in the registry and prints an appropriate message.
function Registry:DisplayUserCount()
    local total = 0
    for _, _ in pairs(self.users) do
        total = total + 1
    end
    local count = total - 1
    if count == 1 then
        Utils.FW_Print(string.format(L.USERS_ONLINE_ONE), false)
    elseif count > 1 then
        Utils.FW_Print(string.format(L.USERS_ONLINE_OTHER, count), false)
    else
        Utils.FW_Print(string.format(L.USERS_ONLINE_NONE), false)
    end
end 

--- Initiates fetching of the user list from the designated channel.
-- Calls ListChannelByName to trigger the CHAT_MSG_CHANNEL_LIST event and retries until successful.
function Registry:FetchUsers()
    if not CommAllowed() then return end
    -- Purge entries that haven't been seen in a while before we refresh.
    self:CleanupUsers(self.USER_EXPIRATION)
    if self.usersFetched and not self.fetchingUsers then return end
    self.fetchingUsers = true
    if addonTable.Comm and addonTable.Comm:GetChannel() then
        ListChannelByName(self.CHANNEL_NAME)
        if self.fetchTimer then
            self.fetchTimer:Cancel()
        end
        self.fetchTimer = C_Timer.NewTicker(1, function()
            if not Registry.usersFetched then
                ListChannelByName(Registry.CHANNEL_NAME)
            else
                Registry.fetchTimer:Cancel()
                Registry.fetchTimer = nil
            end
        end)
    end
end

--- Removes users that haven't been seen within the given age.
-- Cleans up the registry so stale entries don't linger indefinitely.
-- @param maxAge number Age in seconds after which a user should expire.
function Registry:CleanupUsers(maxAge)
    local now = time()
    for key, data in pairs(self.users) do
        if data.lastSeen and (now - data.lastSeen) > maxAge then
            self.users[key] = nil
        end
    end
end

--- Callback for the CHAT_MSG_CHANNEL_LIST event.
-- Processes the comma-separated list of players from the channel and updates the registry.
local channelListFrame = CreateFrame("Frame")
channelListFrame:RegisterEvent("CHAT_MSG_CHANNEL_LIST")
channelListFrame:SetScript("OnEvent", function(_, event, ...)
    local playersIndex = 1
    local channelIndex = 9
    
    local players = select(playersIndex, ...)
    local channelName = select(channelIndex, ...)
    if IsSecret(players) or IsSecret(channelName) then return end
    
    if channelName ~= Registry.CHANNEL_NAME then
        return
    end
    
    if not players or players == "" then
        return
    end
    
    for player in string.gmatch(players, "([^,]+)") do
        player = player:gsub("^%s*(.-)%s*$", "%1")
        local normPlayer = Utils.NormalizePlayerName(player)
        if normPlayer then
            local key = Utils.ToLower(normPlayer)
            Registry.users[key] = Registry.users[key] or {}
            Registry.users[key].lastSeen = time()
        end
    end

    Registry.usersFetched = true
    Registry.fetchingUsers = false
    if Registry.fetchTimer then
        Registry.fetchTimer:Cancel()
        Registry.fetchTimer = nil
    end

    Registry:DisplayUserCount()
    -- Clean up outdated users after refreshing the list.
    Registry:CleanupUsers(Registry.USER_EXPIRATION)
end)

--- Filters CHAT_MSG_CHANNEL_LIST events.
-- Suppresses the default chat output for the designated channel.
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_LIST", function(_, event, ...)
    local channelName = select(9, ...)
    if channelName == Registry.CHANNEL_NAME then
        return true
    end
    return false
end)

--- Initializes the registry module.
-- Registers the addon message prefix, sets up event handlers, fetches users,
-- and starts a periodic ticker to send HELLO messages.
function Registry:Initialize()
    C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:SetScript("OnEvent", function(_, _, ...)
        Registry:OnChatMsgAddon(...)
    end)
    self:FetchUsers()
    C_Timer.NewTicker(300, function()
        self:SendHello()
    end)
    -- Periodically remove stale registry entries.
    C_Timer.NewTicker(600, function()
        self:CleanupUsers(self.USER_EXPIRATION)
    end)
end

return Registry
