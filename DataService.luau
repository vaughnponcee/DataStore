-- Connected Discord-GitHub

-- discord: vaughnponce

-- roblox 3HrDev

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local ProfileService = require(ServerStorage.ProfileService)

local DataService = {}

local ProfileStore = ProfileService.GetProfileStore("PlayerDataV1", {
	Cash = 0,
	Rebirths = 0,
	Inventory = {},
	LastDailyReward = 0,
})

local Profiles = {}
local SessionData = {}

-- Used so other systems can react when values change without constantly polling
local CashChanged = Instance.new("BindableEvent")
local RebirthChanged = Instance.new("BindableEvent")
local InventoryChanged = Instance.new("BindableEvent")

-- Ensures invalid numbers or nil values don't break calculations
local function clampNumber(value, fallback)
	if typeof(value) ~= "number" then
		return fallback
	end
	return value
end

-- Creates leaderstats so Roblox automatically displays values on leaderstats UI
local function setupLeaderstats(player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Parent = folder

	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Parent = folder
end

-- Keeps Roblox attributes + leaderstats synced with profile data
-- This avoids UI desync issues when multiple systems modify values
local function sync(player)
	local profile = Profiles[player]
	if not profile then return end

	local data = profile.Data

	player:SetAttribute("Cash", data.Cash)
	player:SetAttribute("Rebirths", data.Rebirths)

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local cash = leaderstats:FindFirstChild("Cash")
		local rebirths = leaderstats:FindFirstChild("Rebirths")

		if cash then cash.Value = data.Cash end
		if rebirths then rebirths.Value = data.Rebirths end
	end
end

-- Wraps player + profile into a lightweight object so systems can be expanded later
local PlayerObject = {}
PlayerObject.__index = PlayerObject

function PlayerObject.new(player, profile)
	local self = setmetatable({}, PlayerObject)
	self.Player = player
	self.Profile = profile
	return self
end

function PlayerObject:GetCash()
	return self.Profile.Data.Cash
end

function PlayerObject:AddCash(amount)
	self.Profile.Data.Cash += amount
end

function PlayerObject:GetRebirths()
	return self.Profile.Data.Rebirths
end

-- Returns raw data table for systems that need direct access
function DataService:Get(player)
	local profile = Profiles[player]
	if not profile then return end
	return profile.Data
end

function DataService:GetProfile(player)
	return Profiles[player]
end

function DataService:GetCash(player)
	local profile = Profiles[player]
	return profile and profile.Data.Cash or 0
end

function DataService:GetRebirths(player)
	local profile = Profiles[player]
	return profile and profile.Data.Rebirths or 0
end

-- Direct overwrite of cash value, always sanitized to prevent negative or fractional values
function DataService:SetCash(player, amount)
	local profile = Profiles[player]
	if not profile then return end

	profile.Data.Cash = math.max(0, math.floor(amount))

	CashChanged:Fire(player, profile.Data.Cash)
	sync(player)
end

-- Adds cash with multipliers from attributes and server boosts
-- This is the main reward function used by gameplay systems
function DataService:AddCash(player, amount)
	local profile = Profiles[player]
	if not profile then return 0 end

	local cashBoost = clampNumber(player:GetAttribute("CashBoost"), 1)
	local friendBoost = clampNumber(player:GetAttribute("FriendBoost"), 1)
	local serverBoost = clampNumber(Workspace:GetAttribute("ServerCashBoost"), 1)

	local finalAmount = math.floor(amount * cashBoost * friendBoost * serverBoost)

	profile.Data.Cash += finalAmount

	CashChanged:Fire(player, profile.Data.Cash)
	sync(player)

	return finalAmount
end

function DataService:SetRebirths(player, amount)
	local profile = Profiles[player]
	if not profile then return end

	profile.Data.Rebirths = math.max(0, math.floor(amount))

	RebirthChanged:Fire(player, profile.Data.Rebirths)
	sync(player)
end

function DataService:AddRebirths(player, amount)
	local profile = Profiles[player]
	if not profile then return end

	profile.Data.Rebirths += math.floor(amount)

	RebirthChanged:Fire(player, profile.Data.Rebirths)
	sync(player)
end

-- Inventory uses a dictionary so items are stored as name -> quantity pairs
function DataService:AddItem(player, itemName, amount)
	local profile = Profiles[player]
	if not profile then return end

	local inv = profile.Data.Inventory
	inv[itemName] = (inv[itemName] or 0) + (amount or 1)

	InventoryChanged:Fire(player, itemName, inv[itemName])
end

function DataService:RemoveItem(player, itemName, amount)
	local profile = Profiles[player]
	if not profile then return false end

	local inv = profile.Data.Inventory
	local current = inv[itemName] or 0

	if current < amount then
		return false
	end

	inv[itemName] = current - amount
	InventoryChanged:Fire(player, itemName, inv[itemName])

	return true
end

function DataService:GetItemCount(player, itemName)
	local profile = Profiles[player]
	if not profile then return 0 end

	return profile.Data.Inventory[itemName] or 0
end

-- Boost values are stored as attributes so other systems can modify them without touching data tables
function DataService:SetCashBoost(player, value)
	player:SetAttribute("CashBoost", math.max(1, value))
end

function DataService:AddCashBoost(player, value)
	player:SetAttribute("CashBoost", (player:GetAttribute("CashBoost") or 1) + value)
end

function DataService:SetFishLuck(player, value)
	player:SetAttribute("FishLuck", math.max(1, value))
end

function DataService:AddFishLuck(player, value)
	local serverLuck = clampNumber(Workspace:GetAttribute("ServerLuckBoost"), 1)
	local current = player:GetAttribute("FishLuck") or 1

	player:SetAttribute("FishLuck", math.max(1, current + value * serverLuck))
end

-- Friend boost checks Roblox social graph and increases earnings slightly per friend in server
function DataService:UpdateFriendBoost(player)
	local boost = 1

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local success, isFriend = pcall(function()
				return player:IsFriendsWith(other.UserId)
			end)

			if success and isFriend then
				boost += 0.1
			end
		end
	end

	player:SetAttribute("FriendBoost", boost)
end

-- Tracks how long a player has been in the server for analytics or rewards
function DataService:StartSession(player)
	SessionData[player] = {
		JoinTime = os.time(),
		CashEarned = 0,
		RebirthsEarned = 0,
	}
end

function DataService:GetPlaytime(player)
	local session = SessionData[player]
	if not session then return 0 end

	return os.time() - session.JoinTime
end

function DataService:EndSession(player)
	SessionData[player] = nil
end

-- Daily reward uses day-of-year to prevent repeated claims within same day
function DataService:ClaimDailyReward(player)
	local profile = Profiles[player]
	if not profile then return false end

	local today = os.date("%j")

	if profile.Data.LastDailyReward == today then
		return false
	end

	profile.Data.LastDailyReward = today

	self:AddCash(player, 1000)

	return true
end

-- Rebirth cost scales exponentially so progression slows naturally over time
function DataService:GetRebirthCost(player)
	local rebirths = self:GetRebirths(player)
	return math.floor(1000 * (1.35 ^ rebirths))
end

-- Loads player profile and initializes runtime systems
function DataService:Init(player)
	local profile = ProfileStore:LoadProfileAsync("Player_" .. player.UserId, "ForceLoad")

	if not profile then
		player:Kick("Failed to load player data")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile:ListenToRelease(function()
		Profiles[player] = nil
		self:EndSession(player)

		if player.Parent then
			player:Kick("Data session ended")
		end
	end)

	Profiles[player] = profile

	setupLeaderstats(player)
	self:StartSession(player)

	player:SetAttribute("CashBoost", 1)
	player:SetAttribute("FishLuck", 1)
	player:SetAttribute("FriendBoost", 1)

	sync(player)
end

-- Releases profile safely when player leaves
function DataService:Release(player)
	local profile = Profiles[player]
	if profile then
		profile:Release()
	end

	Profiles[player] = nil
	self:EndSession(player)
end

-- Event access so other scripts can hook into changes
function DataService:GetCashChangedEvent()
	return CashChanged.Event
end

function DataService:GetInventoryChangedEvent()
	return InventoryChanged.Event
end

function DataService:GetRebirthChangedEvent()
	return RebirthChanged.Event
end

return DataService
