# Remote Environments

## Description

Facilitates shared tables between server and client. Creation of a RemoteEnvironment is reserved for the Server. Initial state of the table is transmitted to clients, and subsequent updates are transmitted to clients that are subscribed to that environment. Typically, ownership of the table will be on the server, and clients will listen, but there are some instances where volatile data from the client may be listened to by the server (simply, a table owned and updated from the client and subscribed to by the server.)

Currently in very early stages, and minor care was taken for upholding standard styling practices, in favor of laying out a roughdraft quickly.

## Usage

### General

```lua
-- Server :

local serverOwnedEnv = RemoteEnvironment:CreateServerHost("Player", {
	SomeField = 100
})

RemoteEnvironment:Subscribe(serverOwnedEnv, somePlayer)

-- Another script :

local serverOwnedEnvForPlayer = RemoteEnvironment:GetEnvironmentFromSubscriber("Player", somePlayer)


-- Client : 

local serviceRemoteEnvironment = RemoteEnvironment:WaitForServer("Player")

local _connection = RemoteEnvironment:ConnectToEnvironmentPath("Player", keyPath, func)
```

### Universal

The universal environment is created automatically and is immediately ready for use via:
```lua
-- Server : 
local universalEnv = require(RemoteEnvironment).Environments.Universal

-- Client : 

-- Note that for the client, it looks like just another regular ServerEnvironment, just with a special reserved name.
local serviceRemoteEnvironment = RemoteEnvironment:WaitForServer(RemoteEnvironment.Types.Universal)

local _connection = RemoteEnvironment:ConnectToEnvironmentPath(RemoteEnvironment.Types.Universal, keyPath, func)
```

### Standardizing Paths

It can be useful to standardize paths in order to avoid any bugs related to typos. 
The below example would generate a usable dictionary at runtime. However,
for intellisense, you should generate the standardization table and paste it where this would go.

```lua
-- ! Reminder : DO NOT MODIFY THESE PATHS WITHIN REQUIRING SCRIPTS. IT WILL AFFECT EVERY OTHER SCRIPT THAT REQUIRES IT.

local structures = {
	Universal = {},
	Player = {
		Backpack = {
			Consumables = true,
			Tools = true,
			Keycards = true,
			Throwables = true
		}
	}
}

local getPathInfo = function(structure)
	local pathShorthands = {}
	local shortHandToPath = {}
	
	local function recur(struct, currPath)
		for k, v in struct do
			local pathClone = table.clone(currPath)
			table.insert(pathClone, k)
	
			local pathStr = table.concat(pathClone, "_")
			pathShorthands[pathStr] = pathStr
			shortHandToPath[pathStr] = pathClone
	
			if type(v) == "table" then
				recur(v, table.clone(pathClone))
			end
		end
	end

	recur(structure, {})

	return pathShorthands, shortHandToPath
end

local returnStuff = {}

for structName, structure in structures do
	local pathShorthands, shortHandToPath = getPathInfo(structure)

	returnStuff[structName] = {
		Keys = pathShorthands,
		Path = shortHandToPath
	}
end

--[[
	-- The above return this :

	{
		Universal = {},
		Player = {
			Keys = {
				Backpack = "Backpack",
				Backpack_Consumables = "Backpack_Consumables",
				Backpack_Tools = "Backpack_Tools",
				.
				.
				.
			},
			Path = {
				Backpack = {"Backpack"}.
				Backpack_Consumables = {"Backpack", "Consumables"},
				.
				.
				.
		}
	}
]]

return returnStuff
```