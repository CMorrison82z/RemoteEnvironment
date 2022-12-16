local Signal = require(script.Parent:WaitForChild"Signal")

local iniT = script.Parent:WaitForChild"RemoteFunction":InvokeServer()

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

local remEnvEvent = script.Parent:WaitForChild"RemoteEvent".OnClientEvent

local changedSig = Signal.new()

remEnvEvent:Connect(function(kPath, value)
	local terminalNode = iniT
	
	local key; key, kPath[#kPath] = kPath[#kPath], nil
		
	for nodeIndex = 1, #kPath do
		terminalNode = terminalNode[kPath[nodeIndex]]
	end

	if type(terminalNode[key]) == "table" then closeTable(terminalNode[key]) end
	
	changedSig:Fire(kPath, key, terminalNode[key], value)

	terminalNode[key] = value
end)

return {
	Table = iniT,
	
	-- (nodes, old-value, new-value)
	Event = changedSig
}