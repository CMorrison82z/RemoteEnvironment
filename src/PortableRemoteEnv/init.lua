if not game:GetService"RunService":IsClient() then
	return require(script.Server)
else
	return require(script.Client)
end