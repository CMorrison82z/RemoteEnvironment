-- TODO : Also support synced environments for use with Actors !
-- TODO : Support metatable replication ??? Unlikely ...
-- TODO : Consider prescribing a metatable to the table being wrapped in a proxy that prevents modification (__newindex only). (Use rawset rawget in getProxyListener instead)

-- TODO : Follow event-subscription model. 

-- TODO : For clarity's sake, separate containers for remote events that are Fired by server versus Client

--[[

	Notes : 

	- Environments of type are UNIQUE on Client, NON-UNIQUE on server

]]

-- Exclusive, Multi, Global, Client

local WAIT_TIMEOUT = 5 -- In Seconds 

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService"Players"
local Runs = game:GetService"RunService"

local Signal = require(script.Parent.Signal)

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
	local serverOwnedEnvironments = {}
	local clientOwnedEnvironments = {}

	SLEnvironment.Environments = {
		Server = serverOwnedEnvironments,
		Client = clientOwnedEnvironments
	}

	local LoadedEvent = Instance.new"RemoteEvent"
	LoadedEvent.Name = "Loaded"
	LoadedEvent.Parent = script

	local createdServerEvent = Instance.new"RemoteEvent"
	createdServerEvent.Name = "CreatedServerEvent"
	createdServerEvent.Parent = script

	local removedServerEvent = Instance.new"RemoteEvent"
	removedServerEvent.Name = "RemovedServerEvent"
	removedServerEvent.Parent = script

	local createdClientEvent = Instance.new"RemoteEvent"
	createdClientEvent.Name = "CreatedClientEvent"
	createdClientEvent.Parent = script

	local playersInfo = {}
	local connectionsToClientEnvironment = {}

	local function WaitForPlayerInfo(player)
		local pInfo = playersInfo[player]

		local s = tick()

		while not pInfo and (tick() - s < WAIT_TIMEOUT) do
			pInfo = playersInfo[player]

			wait()
		end

		return pInfo
	end

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

	local metaData = {}

	function SLEnvironment:CreateServerHost(envType, iniT : table ?)
		local Subscribers = {}

		local accessSignal = Signal.new()

		local pL = getProxyListener(iniT, accessSignal)

		do
			local envUpdatedEvent = getEnv(envType)

			accessSignal:Connect(function(dataPath, key, value)
				for _, player in ipairs(Subscribers) do
					envUpdatedEvent:FireClient(player, dataPath, key, value)
				end
			end)
		end

		metaData[pL] = {
			Subscribers = Subscribers,
			Type = envType,
			Signal = accessSignal
		}

		if not serverOwnedEnvironments[envType] then serverOwnedEnvironments[envType] = {} end

		table.insert(serverOwnedEnvironments[envType], pL)

		return pL
	end

	function SLEnvironment:DestroyServerHost(remoteEnvironment)
		local pMeta = metaData[remoteEnvironment]

		pMeta.Signal:Destroy()

		for index, sub in ipairs(pMeta.Subscribers) do
			removedServerEvent:FireClient(sub, pMeta.Type)
		end

		table.remove(serverOwnedEnvironments[pMeta.Type], table.find(serverOwnedEnvironments[pMeta.Type], remoteEnvironment))

		table.clear(pMeta.Subscribers)
		table.clear(pMeta)


		metaData[remoteEnvironment] = nil
	end

	local _cEventConns = {}

	function SLEnvironment:CreateForClient(envType, player, iniT : table ?)
		local pInfo = WaitForPlayerInfo(player)
		
		if not pInfo then
			return warn(player.Name .. " failed to load in time")
		end
		
		local tClone = DeepCopy(iniT)

		local cEnvs = playersInfo[player].ClientEnvs
		
		if cEnvs[envType] then warn(envType, "is being overwritten for " .. player.Name) end
		cEnvs[envType] = tClone

		if not _cEventConns[envType] then
			local cachedEnvs = {} -- ! Possible danger of a player disconnecting from server, reconnecting and having their old cache.

			_cEventConns[envType] = getEnv(envType):Connect(function(player, dataPath, key, value)
				local cEnv = cachedEnvs[player]
				
				if not cEnv then
					cachedEnvs[player] = playersInfo[player].ClientEnvs[envType]
					cEnv = cachedEnvs[player]

					if not cEnv then return warn("Recieved client environment update, but no ClientEnv exists on the server.") end
				end
				
				local terminalNode = cEnv
		
				local theseNodes = dataPath:split"."
	
				-- Skip first instead of removing. Removing is an order N operation.
				for nodeIndex = 2, #theseNodes do
					terminalNode = terminalNode[theseNodes[nodeIndex]]
				end

	
				if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end
				
				terminalNode[key] = value
	
				cEnv.Changed:Fire(dataPath, key, value) -- * ?? Do we need this ?
			end)
		end

		createdClientEvent:FireClient(player, envType, iniT)

		return tClone
	end

	function SLEnvironment:ConnectToClient(player, envType, func)
		return getEnv(envType):Connect(function(firingPlayer, dataPath, key, value)
			if player ~= firingPlayer then return end

			func(dataPath, key, value)
		end)
	end

	function SLEnvironment:Subscribe(remoteEnvironment, player)
		local pInfo = WaitForPlayerInfo(player)
		
		if not pInfo then
			return warn(player.Name .. " failed to load in time")
		end

		local remEnvMeta = metaData[remoteEnvironment]

		if pInfo.Subscriptions[remEnvMeta.Type] then warn(player, "already subscribed to an environment of type", remEnvMeta.Type) end

		table.insert(remEnvMeta.Subscribers, player)

		createdServerEvent:FireClient(player, remEnvMeta.Type, remoteEnvironment._true)

		pInfo.Subscriptions[remEnvMeta.Type] = true
	end
	
	function SLEnvironment:Unsubscribe(remoteEnvironment, player)
		local remEnvMeta = metaData[remoteEnvironment]

		table.remove(remEnvMeta.Subscribers, table.find(remEnvMeta.Subscribers, player))

		removedServerEvent:FireClient(player, remEnvMeta.Type)

		playersInfo[player].Subscriptions[remEnvMeta.Type] = false
	end

	LoadedEvent.OnServerEvent:Connect(function(player)
		local thisClientEnvs = {}

		clientOwnedEnvironments[player] = thisClientEnvs

		playersInfo[player] = {
			Subscriptions = {},
			ClientEnvs = thisClientEnvs,
		}
	end)

	game:GetService"Players".PlayerRemoving:Connect(function(player)
		-- TODO : disconnect and destroy all : ClientOwnedEnvironments; 

		playersInfo[player] = nil
	end)
else -- Client :
	local serverOwnedEnvironments = {}
	local clientOwnedEnvironments = {}

	SLEnvironment.Environments = {
		Server = serverOwnedEnvironments,
		Client = clientOwnedEnvironments
	}

	function SLEnvironment:WaitForServer(envType : string)
		while not serverOwnedEnvironments[envType] do
			wait()
		end

		return serverOwnedEnvironments[envType]
	end

	function SLEnvironment:WaitForClient(envType : string)
		while not clientOwnedEnvironments[envType] do
			wait()
		end

		return clientOwnedEnvironments[envType]
	end

	function SLEnvironment:ConnectTo(envType : string, func)
		return script.Env:WaitForChild("Updated" .. envType):Connect(func)
	end

	function SLEnvironment:ConnectToUpdate(envType, keyPath : string, func : (remainingNodes : {string}, value : any) -> nil)
		local connectionNodes = keyPath:split"."
	
		return script.Env:WaitForChild("Updated" .. envType, WAIT_TIMEOUT):Connect(function(path : string, nodeKey, value : any)
			local splitNodes = path:split"."
	
			for i = #connectionNodes, 1, -1 do
				if connectionNodes[i] ~= splitNodes[i] then return end
	
				table.remove(splitNodes, i)
			end
	
			table.insert(splitNodes, nodeKey)
	
			func(splitNodes, value)
		end)
	end

	local metaData = {}

	script:WaitForChild"CreatedServerEvent".OnClientEvent:Connect(function(envType, iniT)
		if serverOwnedEnvironments[envType] then warn(envType, "environment being overwritten") end

		serverOwnedEnvironments[envType] = iniT

		-- TODO : if metadata already exists, need to clean it first.

		local thisMeta = {}
		metaData[envType] = thisMeta

		thisMeta.Connection = script.Env:WaitForChild("Updated" .. envType):Connect(function(dataPath, key, value)
			local terminalNode = iniT
	
			local theseNodes = dataPath:split"."

			-- Skip first instead of removing. Removing is an order N operation.
			for nodeIndex = 2, #theseNodes do
				terminalNode = terminalNode[theseNodes[nodeIndex]]
			end

			if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end
			
			terminalNode[key] = value
		end)
	end)

	script:WaitForChild"RemovedServerEvent".OnClientEvent:Connect(function(envType)
		if not metaData[envType] then return warn("None", envType) end

		metaData[envType].Connection:Disconnect()

		-- TODO : Notify before closing the table.

		closeTable(serverOwnedEnvironments[envType])

		serverOwnedEnvironments[envType] = nil
	end)

	script:WaitForChild"CreatedClientEvent".OnClientEvent:Connect(function(envType, iniT)
		local accessSignal = Signal.new()

		local pL = getProxyListener(iniT, accessSignal)

		accessSignal:Connect(function(dataPath : string, key, value)
			script.Env:WaitForChild("Updated" .. envType):Fire(dataPath, key, value)
		end)

		clientOwnedEnvironments[envType] = pL
	end)

	script:WaitForChild"Loaded":FireServer()
end

return SLEnvironment