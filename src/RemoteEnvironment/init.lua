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

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService"Players"
local Runs = game:GetService"RunService"

local BridgeNet = require(script.BridgeNet)
local Signal = require(script.Signal)

local ENVIRONMENT_TYPES = {
	Universal = "Universal",
	Server = "Server",
	Client = "Client"
}

local SLEnvironment = {}
SLEnvironment.Types = ENVIRONMENT_TYPES

local function DeepCopy(t, preserveMetatable : boolean?, preserveFunctions : boolean?)
	local copy = {}

	local selfFunc = DeepCopy -- Caching the function because it is being indexed multiple times in the loop.

	for i, v in pairs(t) do
		if type(v) == "function" then
			if not preserveFunctions then continue end
		elseif typeof(v) == "table" then
			copy[i] = selfFunc(v)
		else
			copy[i] = v
		end
	end

	if preserveMetatable then
		setmetatable(copy, getmetatable(t))
	end

	return copy
end

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

	local specialKeys = {
		_true = function()
			return t
		end,
		_signal = function()
			return accessSignal
		end
	}

	proxMeta.__index = function(self, k)
		local val = t[k]

		if val == nil then
			local sKfunc = specialKeys[k]

			if sKfunc then
				return sKfunc()
			else
				return val
			end
		end		

		if type(val) == "table" then
			return getProxyListener(val, accessSignal, keyNamePath .. "." .. k)
		else
			return val
		end
	end

	proxMeta.__newindex = function(self, k, v)
		if (type(v) == "function") then error("Cannot assign a table or function") end

		if (type(v) == "table") then
			assert(not getmetatable(v), "Cannot assign a table with a metatable.")
			warn("Table is evolving")

			-- Clone table for use in the proxy table.
			local cT = table.clone(v)
			
			-- Clear contents of the old table and turn it into another proxy.
			table.clear(v)
			setmetatable(v, proxMeta)

			-- set v to the cloned table so that it is assigned and fired correctly by the signal.
			v = cT
		end

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

	local serverBridges = {}
	local clientBridges = {}

	local loadedPlayers = {}
	local connectionsToClientEnvironment = {}

	local function WaitForPlayerLoaded(player)
		local pInfo = loadedPlayers[player]

		local s = tick()
		local _notified = false

		while not pInfo do
			if not _notified and (tick() - s > 10) then _notified = true warn(player.Name .. " may never load") end
			
			pInfo = loadedPlayers[player]

			wait()
		end

		if not pInfo then warn("No player info for " .. player.Name) end

		return pInfo
	end

	local function getServerEnv(name)
		local thisEnv = serverBridges[name]

		if thisEnv then 
			return thisEnv 
		else		
			local newBridge = BridgeNet.CreateBridge(name)
			serverBridges[name] = newBridge

			return newBridge
		end
	end

	local function getClientEnv(name)
		local thisEnv = clientBridges[name]

		if thisEnv then 
			return thisEnv 
		else		
			local newBridge = BridgeNet.CreateBridge(name)
			clientBridges[name] = newBridge

			return newBridge
		end
	end

	local metaData = {}
	local _globalEnvTypes = {}
	
	-- It's assumed that a universal environment will exist forever.
	do
		local accessSignal = Signal.new()

		local pL = getProxyListener({}, accessSignal)
		SLEnvironment.Environments.Universal = pL

		do
			local envUpdatedEvent = getServerEnv(ENVIRONMENT_TYPES.Universal)

			accessSignal:Connect(function(dataPath, key, value)
				envUpdatedEvent:FireAll(dataPath, key, value)
			end)
		end

		assert(not serverOwnedEnvironments[ENVIRONMENT_TYPES.Universal], "Universal environment must not share an Environment Type")
		assert(not _globalEnvTypes[ENVIRONMENT_TYPES.Universal], "Universal environment must not share an Environment Type")

		_globalEnvTypes[ENVIRONMENT_TYPES.Universal] = true

		metaData[pL] = {
			Type = ENVIRONMENT_TYPES.Universal,
			Signal = accessSignal
		}
		
		Players.PlayerAdded:Connect(function(player)
			WaitForPlayerLoaded(player)
			createdServerEvent:FireClient(player, ENVIRONMENT_TYPES.Universal, pL._true)
		end)

		for index, player in ipairs(Players:GetPlayers()) do
			WaitForPlayerLoaded(player)

			createdServerEvent:FireClient(player, ENVIRONMENT_TYPES.Universal, pL._true)
		end
	end

	function SLEnvironment:CreateServerHost(envType, iniT : table ?)
		assert(not _globalEnvTypes[envType], "Universal environment must not share an Environment Type")

		local Subscribers = {}

		local accessSignal = Signal.new()

		local pL = getProxyListener(iniT, accessSignal)

		do
			local envUpdatedEvent = getServerEnv(envType)

			accessSignal:Connect(function(dataPath, key, value)
				for _, player in ipairs(Subscribers) do
					envUpdatedEvent:FireTo(player, dataPath, key, value)
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

	function SLEnvironment:CreateClientHost(player, envType, iniT : table ?)
		WaitForPlayerLoaded(player)

		local tClone = DeepCopy(iniT)

		clientOwnedEnvironments[player][envType] = tClone

		if not _cEventConns[envType] then
			local cachedEnvs = {} -- ! Possible danger of a player disconnecting from server, reconnecting and having their old cache.

			_cEventConns[envType] = getClientEnv(envType):Connect(function(player, dataPath, key, value)
				local cEnv = cachedEnvs[player]

				if not cEnv then
					cachedEnvs[player] = clientOwnedEnvironments[player][envType]
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

				-- cEnv.Changed:Fire(dataPath, key, value) -- * ?? Do we need this ?
			end)
		end

		createdClientEvent:FireClient(player, envType, iniT)

		return tClone
	end

	function SLEnvironment:ConnectToClient(player, envType, func)
		return getClientEnv(envType):Connect(function(firingPlayer, dataPath, key, value)
			if player ~= firingPlayer then return end

			func(dataPath, key, value)
		end)
	end

	function SLEnvironment:ConnectToClientPath(player, envType, keyPath : string, func : (remainingNodes : {string}, value : any) -> nil)
		local connectionNodes = keyPath:split"."

		return getClientEnv(envType):Connect(function(firingPlayer, path : string, nodeKey, value : any)
			if firingPlayer ~= player then return end
			
			local splitNodes = path:split"."

			for i = #connectionNodes, 1, -1 do
				if connectionNodes[i] ~= splitNodes[i] then return end

				table.remove(splitNodes, i)
			end

			table.insert(splitNodes, nodeKey)

			func(splitNodes, value)
		end)
	end

	function SLEnvironment:Subscribe(remoteEnvironment, player)
		local pInfo = WaitForPlayerLoaded(player)

		local remEnvMeta = metaData[remoteEnvironment]

		if table.find(remEnvMeta.Subscribers, player) then warn(player, "already subscribed to an environment of type", remEnvMeta.Type) end

		table.insert(remEnvMeta.Subscribers, player)

		createdServerEvent:FireClient(player, remEnvMeta.Type, remoteEnvironment._true)
	end

	function SLEnvironment:Unsubscribe(remoteEnvironment, player)
		local remEnvMeta = metaData[remoteEnvironment]

		table.remove(remEnvMeta.Subscribers, table.find(remEnvMeta.Subscribers, player))

		removedServerEvent:FireClient(player, remEnvMeta.Type)
	end

	LoadedEvent.OnServerEvent:Connect(function(player)
		clientOwnedEnvironments[player] = {}

		loadedPlayers[player] = true
	end)

	game:GetService"Players".PlayerRemoving:Connect(function(player)
		-- TODO : Include OnDisconnected callbacks so that other services have a chance to retrieve the table.

		for _, value in ipairs(serverOwnedEnvironments) do
			local thisMetaData = metaData[value]

			local index = table.find(thisMetaData.Subscribers, player)

			if index then
				table.remove(thisMetaData.Subscribers, index)
			end
		end

		-- TODO : Decide whether dropping references is enough, or if we should close the tables.
		table.clear(clientOwnedEnvironments[player])

		loadedPlayers[player] = nil
	end)
else -- Client :
	local serverOwnedEnvironments = {}
	local clientOwnedEnvironments = {}

	local serverClientBridges = {}
	local clientServerBridges = {}

	SLEnvironment.Environments = {
		Server = serverOwnedEnvironments,
		Client = clientOwnedEnvironments
	}

	local function getServerEnv(name)
		local thisEnv = serverClientBridges[name]

		if thisEnv then 
			return thisEnv 
		else		
			local newBridge = BridgeNet.WaitForBridge(name)
			serverClientBridges[name] = newBridge

			return newBridge
		end
	end

	local function getClientEnv(name)
		local thisEnv = clientServerBridges[name]

		if thisEnv then 
			return thisEnv 
		else		
			local newBridge = BridgeNet.WaitForBridge(name)
			clientServerBridges[name] = newBridge

			return newBridge
		end
	end

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
		return getServerEnv(envType):Connect(func)
	end

	function SLEnvironment:ConnectToEnvironmentPath(envType, keyPath : string, func : (remainingNodes : {string}, value : any) -> nil)
		local connectionNodes = keyPath:split"."

		return getServerEnv(envType):Connect(function(path : string, nodeKey, value : any)
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

	script:WaitForChild("CreatedServerEvent").OnClientEvent:Connect(function(envType, iniT)
		if serverOwnedEnvironments[envType] then warn(envType, "environment being overwritten") end

		serverOwnedEnvironments[envType] = iniT

		-- TODO : if metadata already exists, need to clean it first.

		local thisMeta = {}
		metaData[envType] = thisMeta
		
		thisMeta.Connection = getServerEnv(envType):Connect(function(dataPath, key, value)
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

	script:WaitForChild("RemovedServerEvent").OnClientEvent:Connect(function(envType)
		if not metaData[envType] then return warn("None", envType) end

		metaData[envType].Connection:Disconnect()

		-- TODO : Notify before closing the table.

		closeTable(serverOwnedEnvironments[envType])

		serverOwnedEnvironments[envType] = nil
	end)

	script:WaitForChild"CreatedClientEvent".OnClientEvent:Connect(function(envType, iniT)
		local accessSignal = Signal.new()

		local pL = getProxyListener(iniT, accessSignal)
		
		local updatedEvent = getClientEnv(envType)

		accessSignal:Connect(function(dataPath : string, key, value)
			updatedEvent:FireServer(dataPath, key, value)
		end)
		
		clientOwnedEnvironments[envType] = pL
		
	end)

	script:WaitForChild"Loaded":FireServer()
end

return SLEnvironment