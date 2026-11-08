--!strict
--[[
	Read-only inspection of source Instances.

	Only language keys (attributes and tags in the language namespaces) are
	read. Everything else on an Instance is developer data and is ignored.
	Results are sorted so that every later stage iterates deterministically.
]]

local constants = require(script.Parent.Parent.constants)
local ir = require(script.Parent.Parent.ir)

type raw_config = ir.raw_config

local function inNamespace(name: string, namespaces: { string }): boolean
	for _, prefix in namespaces do
		if string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function isLanguageAttribute(name: string): boolean
	return inNamespace(name, constants.ATTRIBUTE_NAMESPACES)
end

local function isLanguageTag(name: string): boolean
	return inNamespace(name, constants.TAG_NAMESPACES)
end

local function readConfig(instance: Instance): raw_config
	local attributes: { [string]: unknown } = {}
	local attributeNames: { string } = {}
	for name, value in instance:GetAttributes() do
		if isLanguageAttribute(name) then
			attributes[name] = value
			table.insert(attributeNames, name)
		end
	end
	table.sort(attributeNames)

	local tags: { string } = {}
	for _, tag in instance:GetTags() do
		if isLanguageTag(tag) then
			table.insert(tags, tag)
		end
	end
	table.sort(tags)

	return table.freeze({
		attributes = table.freeze(attributes),
		attributeNames = table.freeze(attributeNames),
		tags = table.freeze(tags),
	})
end

local function isEmpty(config: raw_config): boolean
	return #config.attributeNames == 0 and #config.tags == 0
end

local function hasTag(config: raw_config, tag: string): boolean
	return table.find(config.tags, tag) ~= nil
end

-- Keys present in `config`, as "attribute:<name>" / "tag:<name>" strings.
local function keysOf(config: raw_config): { string }
	local keys = {}
	for _, name in config.attributeNames do
		table.insert(keys, "attribute " .. name)
	end
	for _, tag in config.tags do
		table.insert(keys, "tag " .. tag)
	end
	return keys
end

return table.freeze({
	isLanguageAttribute = isLanguageAttribute,
	isLanguageTag = isLanguageTag,
	readConfig = readConfig,
	isEmpty = isEmpty,
	hasTag = hasTag,
	keysOf = keysOf,
})
