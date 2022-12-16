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

export type ProxyTable = {
	Get : (key : any) -> any,
	Set : (key : any, value : any) -> nil,
	Hook : (func : (...any) -> nil) -> nil,
	HookPath : (path : string, func : (...any) -> nil) -> nil,
	UnhookPath : (path : string) -> nil,
	GetRawSelf : () -> table
}

local function callbackTable(t, _callbacks, currentPath)
	local p = newproxy(true)
	local mt = getmetatable(p)

	currentPath = currentPath or "Base"

	local function fireCallbacks(path, v)
		local pathSplit = path:split(".")

		local currPath;

		for i, nextNode in ipairs(pathSplit) do
			currPath = currPath and currPath .. "." .. nextNode or nextNode
			
			if _callbacks[currPath] then
				local remainingPath = path:gsub(i ~= #pathSplit and currPath .. "." or currPath, "")
				remainingPath = remainingPath:len() > 0 and remainingPath

				for _, cb in ipairs(_callbacks[currPath]) do
					coroutine.wrap(cb)(remainingPath, v)
				end
			end
		end
	end

	local Methods = {}
	mt.__index = Methods

	function Methods.Get(kPath)
		local pathSplit = kPath:split(".")

		local head = t

		for i = 1, #pathSplit - 1 do
			head = head[pathSplit[i]]
		end

		local v = head[pathSplit[#pathSplit]]
		local _typeV = type(v)

		if _typeV == "table" then
			return callbackTable(v, _callbacks, currentPath .. "." .. kPath)
		else
			return v
		end
	end

	-- path can take the form "Key1.Key2.Keys"
	function Methods.Set(kPath, v)
		local pathSplit = kPath:split(".")

		local head = t

		for i = 1, #pathSplit - 1 do
			head = head[pathSplit[i]]
		end

		head[pathSplit[#pathSplit]] = v

		fireCallbacks(currentPath .. "." .. kPath, v)
	end
	
	local _nestedHooks = {}

	-- * The child proxy copies its RawSelf into this proxy. However, this proxy is hooked with a function that will error upon attempting to use Set on
	-- * the path of the child proxy.
	function Methods.Nest(kPath, otherProxy : ProxyTable)
		assert(not _nestedHooks[otherProxy], "A hook already exists for this proxy! Did you already call Nest on this proxy ?")

		-- Up value for tracking valid modifications.
		local _isValid = false

		local hookF = function(modPath, val)
			_isValid = true
			
			Methods.Set(kPath .. "." .. modPath, val)
		end

		local sHookF = function()
			if _isValid then
				_isValid = false
			else
				error("Parent proxy cannot modify inner proxy")
			end
		end
		
		local _rawOther = otherProxy.GetRawSelf()
		
		_nestedHooks[_rawOther] = {
			self = sHookF,
			other = hookF
		}
		
		Methods.Set(kPath, _rawOther)

		Methods.HookPath(kPath, sHookF)
		otherProxy.Hook(hookF)
	end

	function Methods.Unnest(kPath, otherProxy)
		local _nestedT = Methods.Get(kPath).GetRawSelf()
		
		assert(_nestedT == otherProxy.GetRawSelf(), "Retrieved table does not match proxy's table.")
		
		local hooks = _nestedHooks[_nestedT]
		assert(hooks, "No hook exists for this proxy! Did you already call Unnest for this proxy ?")

		otherProxy.Unhook(nil, hooks.other)
		Methods.Unhook(kPath, hooks.self)
		_nestedHooks[otherProxy] = nil
		
		Methods.Set(kPath)
	end
	
	function Methods.Hook(f : (kPath : string, val : any) -> nil)
		local pCallbacks = _callbacks[currentPath]

		if not pCallbacks then
			pCallbacks = {}
			_callbacks[currentPath] = pCallbacks
		end

		table.insert(pCallbacks, f)
	end
	
	function Methods.HookPath(path, f : (kPath : string, val : any) -> nil)
		local _fullPath = currentPath .. "." .. path
		
		local pCallbacks = _callbacks[_fullPath]

		if not pCallbacks then
			pCallbacks = {}
			_callbacks[_fullPath] = pCallbacks
		end
		
		table.insert(pCallbacks, f)
	end

	function Methods.Unhook(path, f)
		path = currentPath .. (path and "." .. path or "")

		local pCallbacks = _callbacks[path]

		if not pCallbacks then
			pCallbacks = {}
			_callbacks[path] = pCallbacks
		end

		local cbInd = table.find(pCallbacks, f)

		if not cbInd then return warn("NO CALLBACK FOUND") end

		table.remove(pCallbacks, cbInd)
	end

	function Methods.GetRawSelf()
		return t
	end

	return p
end

local function newCallbackTable(t) : ProxyTable
	return callbackTable(t, {})
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
		local pL = newCallbackTable({})
		SLEnvironment.Environments.Universal = pL

		do
			local envUpdatedEvent = getServerEnv(ENVIRONMENT_TYPES.Universal)

			pL.Hook(function(dataPath, value)
				envUpdatedEvent:FireAll(dataPath, value)
			end)
		end

		assert(not serverOwnedEnvironments[ENVIRONMENT_TYPES.Universal], "Universal environment must not share an Environment Type")
		assert(not _globalEnvTypes[ENVIRONMENT_TYPES.Universal], "Universal environment must not share an Environment Type")

		_globalEnvTypes[ENVIRONMENT_TYPES.Universal] = true

		metaData[pL] = {
			Type = ENVIRONMENT_TYPES.Universal,
		}
		
		Players.PlayerAdded:Connect(function(player)
			WaitForPlayerLoaded(player)
			createdServerEvent:FireClient(player, ENVIRONMENT_TYPES.Universal, pL.GetRawSelf())
		end)

		for index, player in ipairs(Players:GetPlayers()) do
			WaitForPlayerLoaded(player)

			createdServerEvent:FireClient(player, ENVIRONMENT_TYPES.Universal, pL.GetRawSelf())
		end
	end

	function SLEnvironment:CreateServerHost(envType, iniT : table ?)
		assert(not _globalEnvTypes[envType], "Universal environment must not share an Environment Type")

		local Subscribers = {}

		local pL = newCallbackTable(iniT)

		do
			local envUpdatedEvent = getServerEnv(envType)

			pL.Hook(function(dataPath, value)
				for _, player in ipairs(Subscribers) do
					envUpdatedEvent:FireTo(player, dataPath, value)
				end
			end)
		end

		metaData[pL] = {
			Subscribers = Subscribers,
			Type = envType,
		}

		if not serverOwnedEnvironments[envType] then serverOwnedEnvironments[envType] = {} end

		table.insert(serverOwnedEnvironments[envType], pL)

		return pL
	end

	function SLEnvironment:DestroyServerHost(remoteEnvironment)
		local pMeta = metaData[remoteEnvironment]

		for index, sub in ipairs(pMeta.Subscribers) do
			removedServerEvent:FireClient(sub, pMeta.Type)
		end

		table.remove(serverOwnedEnvironments[pMeta.Type], table.find(serverOwnedEnvironments[pMeta.Type], remoteEnvironment))

		table.clear(pMeta.Subscribers)
		table.clear(pMeta)

		metaData[remoteEnvironment] = nil
	end

	function SLEnvironment:Subscribe(remoteEnvironment : ProxyTable, player)
		local pInfo = WaitForPlayerLoaded(player)

		local remEnvMeta = metaData[remoteEnvironment]

		if table.find(remEnvMeta.Subscribers, player) then warn(player, "already subscribed to an environment of type", remEnvMeta.Type) end

		table.insert(remEnvMeta.Subscribers, player)

		createdServerEvent:FireClient(player, remEnvMeta.Type, remoteEnvironment.GetRawSelf())
	end

	function SLEnvironment:Unsubscribe(remoteEnvironment, player)
		local remEnvMeta = metaData[remoteEnvironment]

		table.remove(remEnvMeta.Subscribers, table.find(remEnvMeta.Subscribers, player))

		removedServerEvent:FireClient(player, remEnvMeta.Type)
	end

	function SLEnvironment:GetEnvironmentFromSubscriber(envType, subscriber : Player)
		for _, env in ipairs(serverOwnedEnvironments[envType]) do
			if table.find(metaData[env].Subscribers, subscriber) then
				return env
			end
		end

		warn("No environment '" .. envType .. "' with subscriber '" .. subscriber.Name .. "'")
	end

	local _cEventConns = {}

	function SLEnvironment:CreateClientHost(player, envType, iniT : table ?)
		WaitForPlayerLoaded(player)

		local tClone = DeepCopy(iniT)

		clientOwnedEnvironments[player][envType] = tClone

		if not _cEventConns[envType] then
			local cachedEnvs = {} -- ! Possible danger of a player disconnecting from server, reconnecting and having their old cache.

			_cEventConns[envType] = getClientEnv(envType):Connect(function(player, dataPath, value)
				local cEnv = cachedEnvs[player]

				if not cEnv then
					cachedEnvs[player] = clientOwnedEnvironments[player][envType]
					cEnv = cachedEnvs[player]

					if not cEnv then return warn("Recieved client environment update, but no ClientEnv exists on the server.") end
				end

				local terminalNode = cEnv

				local theseNodes = dataPath:split"."
				local key; key, theseNodes[#theseNodes] = theseNodes[#theseNodes], nil

				-- Skip first instead of removing. Removing is an order N operation.
				for nodeIndex = 1, #theseNodes do
					terminalNode = terminalNode[theseNodes[nodeIndex]]
				end


				if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end

				terminalNode[key] = value
			end)
		end

		createdClientEvent:FireClient(player, envType, iniT)

		return tClone
	end

	function SLEnvironment:ConnectToClient(player, envType, func)
		return getClientEnv(envType):Connect(function(firingPlayer, dataPath, value)
			if player ~= firingPlayer then return end

			func(dataPath, value)
		end)
	end

	function SLEnvironment:ConnectToClientPath(player, envType, keyPath : string, func : (remainingNodes : {string}, value : any) -> nil)
		local connectionNodes = keyPath:split"."

		return getClientEnv(envType):Connect(function(firingPlayer, path : string, value : any)
			if firingPlayer ~= player then return end
			
			local splitNodes = path:split"."

			for i = #connectionNodes, 1, -1 do
				if connectionNodes[i] ~= splitNodes[i] then return end

				table.remove(splitNodes, i)
			end

			func(splitNodes, value)
		end)
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
			local newBridge = BridgeNet.CreateBridge(name)
			serverClientBridges[name] = newBridge

			return newBridge
		end
	end

	local function getClientEnv(name)
		local thisEnv = clientServerBridges[name]

		if thisEnv then 
			return thisEnv 
		else		
			local newBridge = BridgeNet.CreateBridge(name)
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

		return getServerEnv(envType):Connect(function(path : string, value : any)
			local splitNodes = path:split"."

			for i = #connectionNodes, 1, -1 do
				if connectionNodes[i] ~= splitNodes[i] then return end

				table.remove(splitNodes, i)
			end

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
		
		thisMeta.Connection = getServerEnv(envType):Connect(function(dataPath, value)
			local terminalNode = iniT

			local theseNodes = dataPath:split"."
			local key; key, theseNodes[#theseNodes] = theseNodes[#theseNodes], nil

			-- Skip first instead of removing. Removing is an order N operation.
			for nodeIndex = 1, #theseNodes do
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
		local pL = newCallbackTable(iniT)
		
		local updatedEvent = getClientEnv(envType)

		pL.Hook(function(dataPath : string, value)
			updatedEvent:FireServer(dataPath, value)
		end)
		
		clientOwnedEnvironments[envType] = pL
		
	end)

	script:WaitForChild"Loaded":FireServer()
end

return SLEnvironment