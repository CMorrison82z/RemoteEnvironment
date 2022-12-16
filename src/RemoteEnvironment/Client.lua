local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService"Players"
local Runs = game:GetService"RunService"

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

local function callbackTable(t, _callbacks, currentPath)
	local p = newproxy(true)
	local mt = getmetatable(p)

	_callbacks = _callbacks or {}
	currentPath = currentPath or {}

	local function fireCallbacks(path, v)
		local currPath = {};

		if _callbacks[""] then
			local remainingPath = {}

			for thisInd = 1, #path do
				table.insert(remainingPath, path[thisInd])
			end

			remainingPath = #remainingPath > 0 and remainingPath

			for _, cb in ipairs(_callbacks[""]) do
				coroutine.wrap(cb)(remainingPath, v)
			end
		end

		for i, nextNode in ipairs(path) do
			table.insert(currPath, nextNode)
			local cbKey = table.concat(currPath, ".")

			if _callbacks[cbKey] then
				local remainingPath = {}

				for thisInd = i + 1, #path do
					table.insert(remainingPath, path[thisInd])
				end

				remainingPath = #remainingPath > 0 and remainingPath

				for _, cb in ipairs(_callbacks[cbKey]) do
					coroutine.wrap(cb)(remainingPath, v)
				end
			end
		end
	end

	local function union(a1, a2)
		local u = table.clone(a1)

		for _, v in a2 do
			table.insert(u, v)
		end

		return u
	end

	local Methods = {}
	mt.__index = Methods

	-- Path is an array of keys.
	function Methods:Get(kPath)
		local head = t

		for i = 1, #kPath - 1 do
			head = head[kPath[i]]
		end

		local v = head[kPath[#kPath]]
		local _typeV = type(v)

		if _typeV == "table" then
			return callbackTable(v, _callbacks, union(currentPath, kPath))
		else
			return v
		end
	end

	-- path is an array.
	function Methods:Set(kPath, v)
		local head = t

		for i = 1, #kPath - 1 do
			head = head[kPath[i]]
		end

		head[kPath[#kPath]] = v

		fireCallbacks(union(currentPath, kPath), v)
	end

	-- Prepares a path of tables
	function Methods:Pave(kPath)
		local head = t

		local cPath = table.clone(currentPath)

		for _, node in kPath do
			if not head[node] then
				head[node] = {}
				table.insert(cPath, node)

				fireCallbacks(cPath, head[node])
			end

			head = head[node]
		end
	end

	-- Path specifies the location of the Array to perform the insert method.
	function Methods:ArrayInsert(kPath, v, atIndex)
		local head = t

		for i = 1, #kPath - 1 do
			head = head[kPath[i]]
		end

		if atIndex then
			table.insert(head, v, atIndex)
		else
			table.insert(head, v)
		end

		local tblPath = union(currentPath, kPath)
		local pathLenPlusOne = #tblPath + 1

		for thisInd = atIndex or #head, #head do
			tblPath[pathLenPlusOne] = thisInd

			fireCallbacks(tblPath, head[thisInd])

			tblPath[pathLenPlusOne] = nil
		end
	end

	-- Path specifies the location of the Array to perform the remove method.
	function Methods:ArrayRemove(kPath, atIndex)
		assert(type(atIndex) == "number", "Must provide an index to remove from.")

		local head = t

		for i = 1, #kPath - 1 do
			head = head[kPath[i]]
		end

		table.remove(head, atIndex)

		local tblPath = union(currentPath, kPath)
		local pathLenPlusOne = #tblPath + 1

		for thisInd = atIndex or #head, #head do
			tblPath[pathLenPlusOne] = thisInd

			fireCallbacks(tblPath, head[thisInd])

			tblPath[pathLenPlusOne] = nil
		end
	end

	local _nestedHooks = {}

	-- * The child proxy copies its RawSelf into this proxy. However, this proxy is hooked with a function that will error upon attempting to use Set on
	-- * the path of the child proxy.
	-- * In other words, the nesting ('Parent') is prohibited from modifying the nested ('Child') proxy using its Modification (Set, Insert, etc.) methods.
	function Methods:Nest(kPath, otherProxy : ProxyTable)
		assert(not _nestedHooks[otherProxy], "A hook already exists for this proxy! Did you already call Nest on this proxy ?")

		-- Up value for tracking valid modifications.
		local _isValid = false

		local hookF = function(modPath, val)
			_isValid = true

			fireCallbacks(modPath and union(kPath, modPath) or kPath, val)
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

		Methods:Set(kPath, _rawOther)

		Methods:HookPath(kPath, sHookF)
		otherProxy:Hook(hookF)
	end

	function Methods:Unnest(kPath, otherProxy)
		local _nestedT = Methods:Get(kPath).GetRawSelf()

		assert(_nestedT == otherProxy.GetRawSelf(), "Retrieved table does not match proxy's table.")

		local hooks = _nestedHooks[_nestedT]
		assert(hooks, "No hook exists for this proxy! Did you already call Unnest for this proxy ?")

		otherProxy:Unhook({}, hooks.other)
		Methods:Unhook(kPath, hooks.self)
		_nestedHooks[otherProxy] = nil

		Methods:Set(kPath)
	end

	function Methods:Hook(f : (kPath : {any}, val : any) -> nil)
		local cbKey = table.concat(currentPath, ".")
		local pCallbacks = _callbacks[cbKey]

		if not pCallbacks then
			pCallbacks = {}
			_callbacks[cbKey] = pCallbacks
		end

		table.insert(pCallbacks, f)
	end

	function Methods:HookPath(path, f : (kPath : {any}, val : any) -> nil)
		local _fullPath = table.concat(union(currentPath, path), ".")

		local pCallbacks = _callbacks[_fullPath]

		if not pCallbacks then
			pCallbacks = {}
			_callbacks[_fullPath] = pCallbacks
		end

		table.insert(pCallbacks, f)
	end

	function Methods:Unhook(path, f)
		path = table.concat(union(currentPath, path), ".")

		local pCallbacks = _callbacks[path]

		if not pCallbacks then
			pCallbacks = {}
			_callbacks[path] = pCallbacks
		end

		local cbInd = table.find(pCallbacks, f)

		if not cbInd then return warn("NO CALLBACK FOUND") end

		table.remove(pCallbacks, cbInd)
	end

	function Methods:GetRawSelf()
		return t
	end

	return p
end

local serverOwnedEnvironments = {}
local clientOwnedEnvironments = {}

local ServerRemFolder = script.Parent:WaitForChild"ServerEnvNet"
local ClientRemFolder = script.Parent:WaitForChild"ClientEnvNet"


SLEnvironment.Environments = {
	Server = serverOwnedEnvironments,
	Client = clientOwnedEnvironments
}

local function getServerEnv(name)
	return ServerRemFolder:WaitForChild(name)
end

local function getClientEnv(name)
	return ClientRemFolder:WaitForChild(name)
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
	return getServerEnv(envType).OnClientEvent:Connect(func)
end

function SLEnvironment:ConnectToEnvironmentPath(envType, keyPath, func : (remainingNodes : {string}, value : any) -> nil)
	return getServerEnv(envType).OnClientEvent:Connect(function(path, value : any)
		for i = #keyPath, 1, -1 do
			if keyPath[i] ~= path[i] then return end

			table.remove(path, i)
		end

		func(path, value)
	end)
end

local metaData = {}

script.Parent:WaitForChild("CreatedServerEvent").OnClientEvent:Connect(function(envType, iniT)
	if serverOwnedEnvironments[envType] then warn(envType, "environment being overwritten") end

	serverOwnedEnvironments[envType] = iniT

	-- TODO : if metadata already exists, need to clean it first.

	local thisMeta = {}
	metaData[envType] = thisMeta

	thisMeta.Connection = getServerEnv(envType).OnClientEvent:Connect(function(dataPath, value)
		local terminalNode = iniT

		local key; key, dataPath[#dataPath] = dataPath[#dataPath], nil

		-- Skip first instead of removing. Removing is an order N operation.
		for nodeIndex = 1, #dataPath do
			terminalNode = terminalNode[dataPath[nodeIndex]]
		end

		if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end

		terminalNode[key] = value
	end)
end)

script.Parent:WaitForChild("RemovedServerEvent").OnClientEvent:Connect(function(envType)
	if not metaData[envType] then return warn("None", envType) end

	metaData[envType].Connection:Disconnect()

	-- TODO : Notify before closing the table.

	closeTable(serverOwnedEnvironments[envType])

	serverOwnedEnvironments[envType] = nil
end)

script.Parent:WaitForChild"CreatedClientEvent".OnClientEvent:Connect(function(envType, iniT)
	local pL = callbackTable(iniT)

	local updatedEvent = getClientEnv(envType)

	pL:Hook(function(dataPath : string, value)
		updatedEvent:FireServer(dataPath, value)
	end)

	clientOwnedEnvironments[envType] = pL

end)

script.Parent:WaitForChild"Loaded":FireServer()

return SLEnvironment