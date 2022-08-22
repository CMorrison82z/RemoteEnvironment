-- TODO : Also support synced environments for use with Actors !
-- TODO : Support metatable replication ??? Unlikely ...
-- TODO : Consider prescribing a metatable to the table being wrapped in a proxy that prevents modification (__newindex only). (Use rawset rawget in getProxyListener instead)

-- TODO : Follow event-subscription model. 
--[[
	TODO :
	* w
	* e
	-- line 3

]]
-- // wut
--[[
	* noob
	! omg 
]]

-- Exclusive, Multi, Global, Client

local WAIT_TIMEOUT = 5 -- In Seconds 

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService"Players"
local Runs = game:GetService"RunService"

local Signal = require(script.Parent.Signal)

local Utilities = _G.Utilities
local TableDeepCopy = Utilities.Get"Table".DeepCopy

local ENVIRONMENT_TYPES = {
	Server = "Server",
	Client = "Client"
}

local SLEnvironment = {}
SLEnvironment.Types = ENVIRONMENT_TYPES

local registeredEnvironments = {}

local function closeTable(t)
	setmetatable(t, {
		__index = function()
			error("This table has been closed and should no longer be used")
		end,
		__newindex = function()
			error("This table has been closed and should no longer be used")
		end
	})

	table.clear(t)
end

-- recursively sets proxies for table-values in the base table.
local function getProxyListener(t, accessSignal : BindableEvent, keyNamePath : string?)
	if not accessSignal or not accessSignal.Fire then return error("Did not provide access signaler") end

	keyNamePath = keyNamePath or "Base"

	local prox = newproxy(true)
	local proxMeta = getmetatable(prox)

	proxMeta.__index = function(self, k)
		local val = t[k]
		
		if val == nil then
			local interpretedKey = k:gsub("_", "")
			
			if interpretedKey == "true" then
				return t
			else
				return t[interpretedKey]
			end
		end		
		
		if type(val) == "table" then
			return getProxyListener(val, accessSignal, keyNamePath .. "." .. k)
		else
			return val
		end
	end

	proxMeta.__newindex = function(self, k, v)
		if (type(v) == "table") then warn("Reminder : table was assigned to proxy listener at '" .. tostring(k) .. "'. Modifications directly made to the table will not be tracked ! To track changes to this table, retrieve a new reference by obtaining it from the proxy listener") end
		if (type(v) == "function") then error("Cannot assign a table or function") end

		t[k] = v

		accessSignal:Fire(keyNamePath, k, v)
	end

	proxMeta.__pairs = function()
		return next, t, nil
	end

	proxMeta.__len = function()
		return #t
	end

	return prox
end

if not Runs:IsClient() then -- Server :
	local LoadedEvent = Instance.new"RemoteEvent"
	LoadedEvent.Name = "Loaded"
	LoadedEvent.Parent = script

	local createdEvent = Instance.new"RemoteEvent"
	createdEvent.Name = "Created"
	createdEvent.Parent = script

	local playersInfo = {}

	local function WaitForPlayerInfo(player)
		local pInfo = playersInfo[player]

		local s = tick()

		while not pInfo and (tick() - s < WAIT_TIMEOUT) do
			pInfo = playersInfo[player]

			wait()
		end

		return pInfo
	end

	local registrationHandlers = {
		Server = function()
			
		end,
		Client = function(name)
			local cachedEnvs = {} -- ! Possible danger of a player disconnecting from server, reconnecting and having their old cache.
			
			registeredEnvironments[name].Updated:Connect(function(player, dataPath, key, value)
				-- InBoundMiddleware
				local cEnv = cachedEnvs[player]
				
				if not cEnv then
					cachedEnvs[player] = playersInfo[player].ClientEnvs[name]
					cEnv = cachedEnvs[player]
				end
				
				local terminalNode = cEnv
		
				local theseNodes = dataPath:split"."

				table.remove(theseNodes, 1) -- "Removing the Base node"

				for nodeIndex, node in ipairs(theseNodes) do
					terminalNode = terminalNode[node]
				end

				if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end
				
				terminalNode[key] = value

				cEnv.Changed:Fire(dataPath, key, value) -- * ?? Do we need this ?
			end)
		end
	}

	local function getEnv(name)
		if registeredEnvironments[name] then 
			return registeredEnvironments[name] 
		else		
			local updatedEvent = Instance.new"RemoteEvent"
			updatedEvent.Name = "Updated" .. name
			updatedEvent.Parent = script.Env
	
			registeredEnvironments[name] = updatedEvent

			return registeredEnvironments[name]
		end
	end

	local creationHandlers = {
		Server = function(envName, iniT)
			local pInfo = WaitForPlayerInfo(player)
		
			if not pInfo then
				return warn(player.Name .. " failed to load in time")
			end

			local accessSignal = Signal.new()

			local pL = getProxyListener(iniT, accessSignal)

			do
				local envUpdatedEvent = getEnv(name)

				table.insert(pInfo.Connections, accessSignal:Connect(function(dataPath, key, value)
					envUpdatedEvent:FireClient(player, dataPath, key, value)
				end))	
			end

			createdEvent:FireClient(player, remoteEnvironment.Name, "Exclusive", iniT)

			return pL
		end,
		Client = function(name)
			local cachedEnvs = {} -- ! Possible danger of a player disconnecting from server, reconnecting and having their old cache.

			registeredEnvironments[name].Updated:Connect(function(player, dataPath, key, value)
				local cEnv = cachedEnvs[player]
				
				if not cEnv then
					cachedEnvs[player] = playersInfo[player].ClientEnvs[name]
					cEnv = cachedEnvs[player]
				end
				
				local terminalNode = cEnv
		
				local theseNodes = dataPath:split"."

				table.remove(theseNodes, 1) -- "Removing the Base node"

				for nodeIndex, node in ipairs(theseNodes) do
					terminalNode = terminalNode[node]
				end

				if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end
				
				terminalNode[key] = value

				cEnv.Changed:Fire(dataPath, key, value) -- * ?? Do we need this ?
			end)
		end
	}

	function SLEnvironment:Create(envName, envType, iniT : table ?)
		local rEnv = registeredEnvironments[envName]

		return creationHandlers[envType](envName, iniT)
	end

	meta = {
		Proxy,
		Subscribers = {}
	}

	LoadedEvent.OnServerEvent:Connect(function(player)
		-- TODO : Init

		playersInfo[player] = {
			Subscriptions = {},
			ClientEnvs = {},
			Connections = {}
		}
	end)

	game:GetService"Players".PlayerRemoving:Connect(function(player)
		-- TODO : disconnect and destroy all.

		playersInfo[player] = nil
	end)
else -- Client :
	local creationHandlers = {
		Exclusive = function(remoteEnvironment, iniT, player)
		end,
		Gloabl = function(remoteEnvironment, iniT, player)
		end,
		Multi = function(remoteEnvironment, iniT, player)
			
		end,
		Client = function(name)

		end
	}

	script:WaitForChild"Created".OnClientEvent:Connect(function(envName, envType, iniT)
		
	end)

	script:WaitForChild"Loaded":FireServer()
end

return SLEnvironment