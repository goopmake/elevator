local compiler = require("@game/ServerStorage/modules/compiler")
local builder = require("@game/ServerStorage/modules/builder")

local comp_res = compiler.compile(game.ServerStorage.assets["asm floor"])

if not comp_res.ok then
	error(comp_res.err)
end

local plan_res = builder.plan(comp_res.val, {
	seed = 0,
})

if not plan_res.ok then
	error(plan_res.err)
end

builder.commit(plan_res.val, workspace.floor)