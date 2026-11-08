--!strict
--[[
	Parser entry point.

	Turns a source Instance that is a container node or a model declaration
	into a definition (see ir.luau), parsing inline descendants recursively.
	Definitions are memoised by Instance, so a definition that is reachable
	both inline and through references is parsed exactly once, and recursive
	references terminate.

	Definition ids are assigned in discovery order, which is deterministic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local diagnostics = require(script.Parent.diagnostics)
local ir = require(script.Parent.ir)
local container = require(script.container)
local node = require(script.node)
local source = require(script.source)

type session = ir.session
type definition = ir.definition
type node_kind = ir.node_kind
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors

local function newDefinition(session: session, instance: Instance, kind: node_kind, label: string): definition
	local def: definition = {
		id = #session.definitions + 1,
		kind = kind,
		instance = instance,
		label = label,
		path = diagnostics.pathOf(instance),
		className = instance.ClassName,
		ownConfig = source.readConfig(instance),
		children = {},
		complete = true,
	}
	table.insert(session.definitions, def)
	session.definitionOf[instance] = def.id
	return def
end

local function parseDefinition(session: session, instance: Instance): outcome<number>
	local existing = session.definitionOf[instance]
	if existing then
		return result.ok(existing)
	end

	local classified = node.classify(instance)
	if not classified.ok then
		return classified
	end

	local classification = classified.val
	if classification.kind == "model" then
		return result.ok(newDefinition(session, instance, "model", instance.Name).id)
	elseif classification.kind == "container" then
		-- Register before parsing children so that cycles terminate.
		local def = newDefinition(session, instance, classification.nodeKind, classification.label)
		local children, complete = container.parseChildren(session, def, parseDefinition)
		def.children = children
		def.complete = complete
		return result.ok(def.id)
	elseif classification.kind == "reference" then
		return diagnostics.fail(
			errors.REFERENCE_CHAIN,
			instance,
			"A reference cannot be used where a node definition is required.",
			{ hint = "Point the ObjectValue at the final node or model directly." }
		)
	else
		return diagnostics.fail(
			errors.REFERENCE_UNSUPPORTED_TARGET,
			instance,
			"A Folder is a language boundary and cannot be used as a node.",
			{ hint = "Target a node or model inside the Folder instead." }
		)
	end
end

return table.freeze({
	parseDefinition = parseDefinition,
	classify = node.classify,
	readConfig = source.readConfig,
})
