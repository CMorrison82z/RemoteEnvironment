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

local remEnv = callbackTable{}

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