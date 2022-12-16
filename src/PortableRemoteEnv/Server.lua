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

local remEnv = newCallbackTable{}

local comm = Instance.new"RemoteEvent"
comm.Parent = script.Parent

local clientInit = Instance.new"RemoteFunction"
clientInit.Parent = script.Parent

clientInit.OnServerInvoke = function(player)
	return remEnv.GetRawSelf()
end

remEnv.Hook(function(kPath, value)
	comm:FireAllClients(kPath, value)
end)

return remEnv