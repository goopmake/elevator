--!strict
--[[
	Language node identification.

	Decides what a single source Instance is, from its class and name only:

		Folder                         -> ignored (hard language boundary)
		Model                          -> model declaration
		Configuration "asm|try|pick|each X" -> container node
		ObjectValue   "ref X"          -> reference

	Everything else in a language position is an error.
]]

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

type outcome<T> = diagnostics.outcome<T>
type container_kind = ir.container_kind

local errors = diagnostics.codes.errors

export type classification =
	{ kind: "ignored" }
	| { kind: "model", namedLikeNode: boolean }
	| { kind: "container", nodeKind: container_kind, label: string }
	| { kind: "reference", label: string }

local CONTAINER_BY_PREFIX: { [string]: container_kind } = {}
CONTAINER_BY_PREFIX[constants.PREFIX.assembly] = "assembly"
CONTAINER_BY_PREFIX[constants.PREFIX.try] = "try"
CONTAINER_BY_PREFIX[constants.PREFIX.pick] = "pick"
CONTAINER_BY_PREFIX[constants.PREFIX.each] = "each"
table.freeze(CONTAINER_BY_PREFIX)

local ALL_PREFIXES: { string } = table.freeze({
	constants.PREFIX.assembly,
	constants.PREFIX.try,
	constants.PREFIX.pick,
	constants.PREFIX.each,
	constants.PREFIX.reference,
})

type split = { prefix: string, label: string }

-- Splits "<prefix><separator><label>". Returns nil when there is no separator.
local function splitName(name: string): split?
	local at = string.find(name, constants.PREFIX_SEPARATOR, 1, true)
	if at == nil then
		return nil
	end
	return {
		prefix = string.sub(name, 1, at - 1),
		label = string.sub(name, at + #constants.PREFIX_SEPARATOR),
	}
end

local function isKnownPrefix(prefix: string): boolean
	return table.find(ALL_PREFIXES, prefix) ~= nil
end

-- Explains the most likely mistake for a name that is not a valid node name.
local function prefixHint(name: string): string
	local lowered = string.lower(name)
	for _, prefix in ALL_PREFIXES do
		if lowered == prefix then
			return string.format("Add a space and a label after the prefix, e.g. '%s main'.", prefix)
		end
		if string.sub(lowered, 1, #prefix) == prefix then
			return string.format(
				"Prefixes are lowercase and followed by a single space, e.g. '%s%s<label>'.",
				prefix,
				constants.PREFIX_SEPARATOR
			)
		end
	end
	return "Name language nodes 'asm <label>', 'try <label>', 'pick <label>', 'each <label>' (Configuration) or 'ref <label>' (ObjectValue), or move this Instance into a Folder."
end

local function classifyConfiguration(instance: Instance): outcome<classification>
	local parts = splitName(instance.Name)
	if parts then
		local kind: container_kind? = CONTAINER_BY_PREFIX[parts.prefix]
		if kind then
			local c: classification = { kind = "container", nodeKind = kind, label = parts.label }
			return result.ok(c)
		end
		if parts.prefix == constants.PREFIX.reference then
			return diagnostics.fail(
				errors.NODE_WRONG_CLASS,
				instance,
				"References must be ObjectValue Instances, but this is a Configuration.",
				{ hint = "Replace it with an ObjectValue and set its Value to the target." }
			)
		end
	end
	return diagnostics.fail(
		errors.NODE_UNKNOWN_PREFIX,
		instance,
		string.format("'%s' does not start with a known node prefix.", instance.Name),
		{ hint = prefixHint(instance.Name) }
	)
end

local function classifyObjectValue(instance: Instance): outcome<classification>
	local parts = splitName(instance.Name)
	if parts then
		if parts.prefix == constants.PREFIX.reference then
			local c: classification = { kind = "reference", label = parts.label }
			return result.ok(c)
		end
		if CONTAINER_BY_PREFIX[parts.prefix] then
			return diagnostics.fail(
				errors.NODE_WRONG_CLASS,
				instance,
				string.format("'%s' nodes must be Configuration Instances, but this is an ObjectValue.", parts.prefix),
				{ hint = "Use a Configuration for asm/try/pick/each nodes, or rename it 'ref <label>' if it is a reference." }
			)
		end
	end
	return diagnostics.fail(
		errors.NODE_UNKNOWN_PREFIX,
		instance,
		string.format("ObjectValue '%s' is not named as a reference.", instance.Name),
		{ hint = "Name references 'ref <label>', or move this Instance into a Folder." }
	)
end

local function classify(instance: Instance): outcome<classification>
	if instance:IsA(constants.CLASS.boundary) then
		local c: classification = { kind = "ignored" }
		return result.ok(c)
	end
	if instance:IsA(constants.CLASS.model) then
		-- Only the exact class Model is a model declaration. Subclasses such as
		-- WorldModel or Actor are rejected below.
		if instance.ClassName == constants.CLASS.model then
			local parts = splitName(instance.Name)
			local namedLikeNode = parts ~= nil and isKnownPrefix(parts.prefix)
			local c: classification = { kind = "model", namedLikeNode = namedLikeNode }
			return result.ok(c)
		end
	end
	if instance.ClassName == constants.CLASS.container then
		return classifyConfiguration(instance)
	end
	if instance.ClassName == constants.CLASS.reference then
		return classifyObjectValue(instance)
	end
	return diagnostics.fail(
		errors.NODE_INVALID_CHILD_CLASS,
		instance,
		string.format("%s Instances are not part of the language and cannot appear here.", instance.ClassName),
		{
			hint = "Put physical Instances inside a Model, and keep scripts or notes inside a Folder.",
		}
	)
end

-- Whether an Instance looks like a language node by class and name. Used to
-- warn about nodes hidden inside models, which are never interpreted.
local function looksLikeNode(instance: Instance): boolean
	if instance.ClassName ~= constants.CLASS.container and instance.ClassName ~= constants.CLASS.reference then
		return false
	end
	local parts = splitName(instance.Name)
	return parts ~= nil and isKnownPrefix(parts.prefix)
end

return table.freeze({
	classify = classify,
	looksLikeNode = looksLikeNode,
})
