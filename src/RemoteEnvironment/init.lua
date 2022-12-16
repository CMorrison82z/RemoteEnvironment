local RunService = game:GetService("RunService")
local src;

if not RunService:IsClient() then
	if src then return src
	else
		src = require(script.Server)
		script.Server.Parent = nil
	end
else
	return require(script.Client)
end