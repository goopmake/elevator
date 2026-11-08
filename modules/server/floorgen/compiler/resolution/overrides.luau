--!strict
--[[
	Reference overrides.

	Language keys are split into two categories (see constants.BEHAVIOUR_KEYS):

		* Behaviour keys say what a node is. A reference that sets any of them
		  overrides the target's behaviour keys completely: target behaviour
		  keys it does not restate are removed. Removal is thereby explicit.
		* Use-site keys say how the node is used at this place. They never
		  trigger an override; the reference's use-site keys are layered over
		  the target's, key by key.

	The typed layering lives in validation/attributes (`layer`), so that the
	effective configuration is validated exactly like an inline one. This
	module answers the raw questions needed before validation. Nothing is ever
	written to an Instance.
]]

local constants = require(script.Parent.Parent.constants)
local ir = require(script.Parent.Parent.ir)
local parser = require(script.Parent.Parent.parser)
local references = require(script.Parent.references)

type raw_config = ir.raw_config

local function isBehaviourKey(name: string): boolean
	return constants.BEHAVIOUR_KEYS[name] == true
end

-- Whether a reference's own keys override its target's behaviour: it sets a
-- behaviour key, or it is tagged fb_override.
local function hasBehaviourOverrides(config: raw_config): boolean
	if table.find(config.tags, constants.TAG.override) ~= nil then
		return true
	end
	for _, name in config.attributeNames do
		if isBehaviourKey(name) then
			return true
		end
	end
	for _, tag in config.tags do
		if isBehaviourKey(tag) then
			return true
		end
	end
	return false
end

-- Whether a reference sets any language key at all.
local function hasKeys(config: raw_config): boolean
	return #config.attributeNames > 0 or #config.tags > 0
end

-- Effective language tags of an arbitrary ObjectValue, without reporting
-- anything. Nil when the target is missing or unsupported.
local function peekEffectiveTags(objectValue: ObjectValue): { [string]: boolean }?
	local target = references.peekTarget(objectValue)
	if target == nil then
		return nil
	end
	local own = parser.readConfig(objectValue)
	local overrides = hasBehaviourOverrides(own)
	local tags: { [string]: boolean } = {}
	for _, tag in parser.readConfig(target).tags do
		if not (overrides and isBehaviourKey(tag)) then
			tags[tag] = true
		end
	end
	for _, tag in own.tags do
		tags[tag] = true
	end
	return tags
end

return table.freeze({
	hasBehaviourOverrides = hasBehaviourOverrides,
	hasKeys = hasKeys,
	peekEffectiveTags = peekEffectiveTags,
})
