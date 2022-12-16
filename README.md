# Remote Environments

## Description

Facilitates shared tables between server and client. Creation of a RemoteEnvironment is reserved for the Server. Initial state of the table is transmitted to clients, and subsequent updates are transmitted to clients that are subscribed to that environment. Typically, ownership of the table will be on the server, and clients will listen, but there are some instances where volatile data from the client may be listened to by the server (simply, a table owned and updated from the client and subscribed to by the server.)

Currently in very early stages, and minor care was taken for upholding standard styling practices, in favor of laying out a roughdraft quickly.

## Universal

The universal environment is created automatically and is immediately ready for use via:
```lua
-- Server : 
local universalEnv = require(RemoteEnvironment).Environments.Universal

-- Client : 

-- Note that for the client, it looks like just another regular ServerEnvironment, just with a special reserved name.
local serviceRemoteEnvironment = RemoteEnvironment:WaitForServer(RemoteEnvironment.Types.Universal)

local _connection = RemoteEnvironment:ConnectToEnvironmentPath(RemoteEnvironment.Types.Universal, keyPath, func)
```

## Knit

```lua
-- Service :

local SERVICE_NAME = "MyName"

local service = Knit.CreateService{
	Name = SERVICE_NAME,

	Client = {
		RemoteEnvironment = Knit.CreateProperty(SERVICE_NAME)
	}
}

-- Client :

local serviceRemoteName = _G.Interpreter.GetKnitPropertyAsync(SomeService.RemoteEnvironment)

local serviceRemoteEnvironment = RemoteEnvironment:WaitForServer(serviceRemoteName)

local _connection = RemoteEnvironment:ConnectToEnvironmentPath(serviceRemoteName, keyPath, func)
```