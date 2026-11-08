--!strict
--[[
	Attribute and tag validation.

	Validates a raw configuration against a node kind and converts it into a
	typed node_config. Every problem is reported; validation does not stop at
	the first one.

	Behaviour keys (what a node is):

		key                   kinds         type / semantics
		--------------------  ------------  ----------------------------------
		tag fb_conditional_model model      overlap-checked, may fail
		fb_max_count          model, asm    natural number; emissions per floor
		fb_pick_amount           pick          natural number or NumberRange, REQUIRED
		fb_pick_unique           pick          boolean, default false
		fb_pick_mode             pick          "strict" (default) or "fit"

	Use-site keys (how a node is used at one place):

		tag fb_optional       any           failure handled on this edge
		tag fb_room           model         the enclosing assembly's room
		tag fb_plug           model         seals unused room connections
		fb_pick_weight           model, asm    natural number, default 1
		fb_attach             model, asm    parent connection to place on
		fb_anchor             model, asm    own connection to mate
		fb_filter             each, model   connection name prefix (each / plugs)
		fb_max_depth          any           natural number; per-reference recursion limit

	A reference's effective configuration is its target's configuration with
	the reference's keys layered on top (see `layer`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local types = require(script.Parent.Parent.types)

type raw_config = ir.raw_config
type node_config = ir.node_config
type parsed_config = ir.parsed_config
type node_kind = ir.node_kind
type diagnostic = diagnostics.diagnostic
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors
local warningCodes = diagnostics.codes.warnings
local ATTRIBUTE = constants.ATTRIBUTE
local TAG = constants.TAG

local function set(list: { string }): { [string]: boolean }
	local s = {}
	for _, v in list do
		s[v] = true
	end
	return table.freeze(s)
end

local KNOWN_ATTRIBUTES = set({
	ATTRIBUTE.pickAmount,
	ATTRIBUTE.pickUnique,
	ATTRIBUTE.pickMode,
	ATTRIBUTE.pickWeight,
	ATTRIBUTE.attach,
	ATTRIBUTE.anchor,
	ATTRIBUTE.filter,
	ATTRIBUTE.maxDepth,
	ATTRIBUTE.maxCount,
})

-- fb_connection is a known tag, but it belongs on Attachments, never on nodes.
local KNOWN_TAGS = set({
	TAG.conditional,
	TAG.room,
	TAG.plug,
	TAG.optional,
	TAG.override,
	TAG.connection,
	TAG.removedAtomic,
})

local ALLOWED_ATTRIBUTES: { [node_kind]: { [string]: boolean } } = table.freeze({
	assembly = set({ ATTRIBUTE.pickWeight, ATTRIBUTE.attach, ATTRIBUTE.anchor, ATTRIBUTE.maxDepth, ATTRIBUTE.maxCount }),
	model = set({
		ATTRIBUTE.pickWeight,
		ATTRIBUTE.attach,
		ATTRIBUTE.anchor,
		ATTRIBUTE.filter,
		ATTRIBUTE.maxDepth,
		ATTRIBUTE.maxCount,
	}),
	try = set({ ATTRIBUTE.maxDepth }),
	pick = set({ ATTRIBUTE.pickAmount, ATTRIBUTE.pickUnique, ATTRIBUTE.pickMode, ATTRIBUTE.maxDepth }),
	each = set({ ATTRIBUTE.filter, ATTRIBUTE.maxDepth }),
})

local ALLOWED_TAGS: { [node_kind]: { [string]: boolean } } = table.freeze({
	assembly = set({ TAG.optional }),
	model = set({ TAG.conditional, TAG.room, TAG.plug, TAG.optional }),
	try = set({ TAG.optional }),
	pick = set({ TAG.optional }),
	each = set({ TAG.optional }),
})

local function isBehaviourKey(name: string): boolean
	return constants.BEHAVIOUR_KEYS[name] == true
end

-- Whether a raw configuration contains behaviour keys.
local function hasBehaviourKeys(raw: raw_config): boolean
	for _, name in raw.attributeNames do
		if isBehaviourKey(name) then
			return true
		end
	end
	for _, tag in raw.tags do
		if isBehaviourKey(tag) then
			return true
		end
	end
	return false
end

local function sortedKeys(s: { [string]: boolean }): string
	local list = {}
	for key in s do
		table.insert(list, key)
	end
	table.sort(list)
	if #list == 0 then
		return "none"
	end
	return table.concat(list, ", ")
end

local function isNaturalNumber(value: number): boolean
	return value == value -- not NaN
		and value >= 0
		and value <= constants.MAX_EXACT_INTEGER
		and math.floor(value) == value
end

type collector = {
	owner: Instance,
	errors: { diagnostic },
}

local function report(c: collector, code: string, name: string, message: string, hint: string?)
	table.insert(c.errors, diagnostics.makeError(code, c.owner, message, { attribute = name, hint = hint }))
end

local function readNatural(c: collector, name: string, value: unknown, code: string): number?
	if type(value) ~= "number" then
		report(c, errors.ATTRIBUTE_TYPE, name, string.format("%s must be a number, got %s.", name, typeof(value)))
		return nil
	end
	if not isNaturalNumber(value) then
		report(c, code, name, string.format("%s must be a whole number between 0 and 2^53, got %s.", name, tostring(value)))
		return nil
	end
	return value
end

local function readBoolean(c: collector, name: string, value: unknown): boolean?
	if type(value) ~= "boolean" then
		report(c, errors.ATTRIBUTE_TYPE, name, string.format("%s must be a boolean, got %s.", name, typeof(value)))
		return nil
	end
	return value
end

local function readName(c: collector, name: string, value: unknown): string?
	if type(value) ~= "string" then
		report(c, errors.ATTRIBUTE_TYPE, name, string.format("%s must be a string, got %s.", name, typeof(value)))
		return nil
	end
	if value == "" then
		report(c, errors.ATTRIBUTE_TYPE, name, string.format("%s must not be empty.", name))
		return nil
	end
	return value
end

-- fb_pick_amount: a natural number or a NumberRange of natural numbers.
local function readAmount(c: collector, name: string, value: unknown): (number?, number?)
	if typeof(value) == "NumberRange" then
		local range = value
		if not isNaturalNumber(range.Min) or not isNaturalNumber(range.Max) then
			report(
				c,
				errors.PICK_AMOUNT_INVALID,
				name,
				string.format("Both ends of the fb_pick_amount range must be whole numbers, got %s.", tostring(value))
			)
			return nil, nil
		end
		return range.Min, range.Max
	end
	if type(value) ~= "number" then
		report(
			c,
			errors.ATTRIBUTE_TYPE,
			name,
			string.format("%s must be a number or a NumberRange, got %s.", name, typeof(value))
		)
		return nil, nil
	end
	local amount = readNatural(c, name, value, errors.PICK_AMOUNT_INVALID)
	return amount, amount
end

local function readMode(c: collector, name: string, value: unknown): types.fb_pick_mode?
	if value == "strict" then
		return "strict"
	elseif value == "fit" then
		return "fit"
	end
	report(
		c,
		if type(value) == "string" then errors.PICK_MODE_INVALID else errors.ATTRIBUTE_TYPE,
		name,
		string.format("%s must be 'strict' or 'fit', got %s.", name, tostring(value))
	)
	return nil
end

local function emptyConfig(): node_config
	return {
		conditional = false,
		maxCount = nil,
		pickMin = nil,
		pickMax = nil,
		pickUnique = false,
		pickMode = "strict",
		room = false,
		plug = false,
		optional = false,
		pickWeight = nil,
		attach = nil,
		anchor = nil,
		filter = nil,
		maxDepth = nil,
	}
end

--[[
	Parses the language keys of one Instance for a node kind.

	`requireBehaviour` demands the required behaviour keys (fb_pick_amount); it is
	false for reference key sets that only contain use-site keys.
	`onReference` allows fb_override, which is only meaningful on references.
	`warn` receives non-fatal diagnostics.
]]
local function parse(
	kind: node_kind,
	raw: raw_config,
	owner: Instance,
	requireBehaviour: boolean,
	onReference: boolean,
	warn: (diagnostic) -> ()
): outcome<parsed_config>
	local c: collector = { owner = owner, errors = {} }
	local allowedAttributes = ALLOWED_ATTRIBUTES[kind]
	local allowedTags = ALLOWED_TAGS[kind]
	local config = emptyConfig()
	local present: { [string]: boolean } = {}

	for _, name in raw.attributeNames do
		local value = raw.attributes[name]
		if not KNOWN_ATTRIBUTES[name] then
			report(
				c,
				errors.ATTRIBUTE_UNKNOWN,
				name,
				string.format("'%s' is not a language attribute.", name),
				string.format("Valid attributes on a %s node: %s.", kind, sortedKeys(allowedAttributes))
			)
			continue
		elseif not allowedAttributes[name] then
			report(
				c,
				errors.ATTRIBUTE_NOT_APPLICABLE,
				name,
				string.format("'%s' cannot be used on a %s node.", name, kind),
				string.format("Valid attributes on a %s node: %s.", kind, sortedKeys(allowedAttributes))
			)
			continue
		end
		present[name] = true
		if name == ATTRIBUTE.pickAmount then
			config.pickMin, config.pickMax = readAmount(c, name, value)
		elseif name == ATTRIBUTE.pickUnique then
			config.pickUnique = readBoolean(c, name, value) == true
		elseif name == ATTRIBUTE.pickMode then
			config.pickMode = readMode(c, name, value) or "strict"
		elseif name == ATTRIBUTE.pickWeight then
			config.pickWeight = readNatural(c, name, value, errors.PICK_WEIGHT_INVALID)
		elseif name == ATTRIBUTE.attach then
			config.attach = readName(c, name, value)
		elseif name == ATTRIBUTE.anchor then
			config.anchor = readName(c, name, value)
		elseif name == ATTRIBUTE.filter then
			config.filter = readName(c, name, value)
		elseif name == ATTRIBUTE.maxDepth then
			config.maxDepth = readNatural(c, name, value, errors.ATTRIBUTE_TYPE)
		elseif name == ATTRIBUTE.maxCount then
			config.maxCount = readNatural(c, name, value, errors.ATTRIBUTE_TYPE)
		end
	end

	for _, tag in raw.tags do
		if tag == TAG.removedAtomic then
			warn(diagnostics.makeWarning(
				warningCodes.TAG_REMOVED,
				owner,
				"fb_atomic_assembly no longer has an effect: every assembly is all-or-nothing.",
				{ attribute = tag, hint = "Remove the tag. Use fb_optional on children that may fail on their own." }
			))
			continue
		end
		if tag == TAG.override then
			if not onReference then
				report(
					c,
					errors.TAG_NOT_APPLICABLE,
					tag,
					"fb_override only has a meaning on references.",
					"Remove the tag; put it on an ObjectValue reference to replace its target's behaviour keys."
				)
			end
			continue
		end
		if not KNOWN_TAGS[tag] then
			report(
				c,
				errors.TAG_UNKNOWN,
				tag,
				string.format("'%s' is not a language tag.", tag),
				string.format("Valid tags on a %s node: %s.", kind, sortedKeys(allowedTags))
			)
			continue
		elseif not allowedTags[tag] then
			report(
				c,
				errors.TAG_NOT_APPLICABLE,
				tag,
				string.format("Tag '%s' cannot be used on a %s node.", tag, kind),
				if tag == TAG.connection
					then "fb_connection belongs on Attachments inside models."
					else string.format("Valid tags on a %s node: %s.", kind, sortedKeys(allowedTags))
			)
			continue
		end
		present[tag] = true
		if tag == TAG.conditional then
			config.conditional = true
		elseif tag == TAG.room then
			config.room = true
		elseif tag == TAG.plug then
			config.plug = true
		elseif tag == TAG.optional then
			config.optional = true
		end
	end

	if requireBehaviour and kind == "pick" and raw.attributes[ATTRIBUTE.pickAmount] == nil then
		report(
			c,
			errors.ATTRIBUTE_MISSING,
			ATTRIBUTE.pickAmount,
			"Pick nodes require a fb_pick_amount attribute.",
			"Add fb_pick_amount: a number, or a NumberRange for a random amount."
		)
	end

	if #c.errors > 0 then
		return result.err(c.errors)
	end
	return result.ok({ config = config, present = present })
end

--[[
	Effective configuration of a reference.

	Behaviour: the reference's behaviour keys if it has any (a complete
	override), otherwise the target's. Use-site: the target's keys, with every
	key the reference sets taking precedence.
]]
local function layer(target: parsed_config, reference: parsed_config, overridesBehaviour: boolean): parsed_config
	local t = target.config
	local r = reference.config
	local rp = reference.present
	local b = overridesBehaviour

	local config: node_config = {
		conditional = if b then r.conditional else t.conditional,
		maxCount = if b then r.maxCount else t.maxCount,
		pickMin = if b then r.pickMin else t.pickMin,
		pickMax = if b then r.pickMax else t.pickMax,
		pickUnique = if b then r.pickUnique else t.pickUnique,
		pickMode = if b then r.pickMode else t.pickMode,
		room = if rp[TAG.room] then r.room else t.room,
		plug = if rp[TAG.plug] then r.plug else t.plug,
		optional = if rp[TAG.optional] then r.optional else t.optional,
		pickWeight = if rp[ATTRIBUTE.pickWeight] then r.pickWeight else t.pickWeight,
		attach = if rp[ATTRIBUTE.attach] then r.attach else t.attach,
		anchor = if rp[ATTRIBUTE.anchor] then r.anchor else t.anchor,
		filter = if rp[ATTRIBUTE.filter] then r.filter else t.filter,
		maxDepth = if rp[ATTRIBUTE.maxDepth] then r.maxDepth else t.maxDepth,
	}

	local present: { [string]: boolean } = {}
	for key in target.present do
		if not (b and isBehaviourKey(key)) then
			present[key] = true
		end
	end
	for key in rp do
		present[key] = true
	end
	return { config = config, present = present }
end

--[[
	Rules between keys of one effective configuration. Rules that depend on
	the position of the node (anchors, filters, plugs) are checked where the
	position is known (construction).
]]
local function crossCheck(kind: node_kind, config: node_config, owner: Instance): outcome<nil>
	local c: collector = { owner = owner, errors = {} }
	if config.room and config.attach then
		report(
			c,
			errors.ROOM_ATTACHED,
			ATTRIBUTE.attach,
			"A room defines its assembly's pivot and cannot be attached to a connection.",
			"Put fb_attach on the assembly that owns this room instead."
		)
	end
	if config.plug then
		if config.room then
			report(c, errors.PLUG_INVALID, TAG.plug, "A model cannot be both a room and a plug.")
		end
		if config.attach then
			report(
				c,
				errors.PLUG_INVALID,
				ATTRIBUTE.attach,
				"Plugs are placed on unused connections automatically and cannot use fb_attach.",
				"Use fb_filter to choose which connections the plug seals."
			)
		end
		if config.conditional or config.maxCount ~= nil or config.optional then
			report(
				c,
				errors.PLUG_INVALID,
				TAG.plug,
				"Plugs must always succeed, so they cannot be conditional, counted or optional."
			)
		end
	elseif kind == "model" and config.filter then
		report(
			c,
			errors.ATTRIBUTE_NOT_APPLICABLE,
			ATTRIBUTE.filter,
			"fb_filter on a model only has an effect on plugs (fb_plug).",
			"Tag the model fb_plug, or remove fb_filter."
		)
	end
	if #c.errors > 0 then
		return result.err(c.errors)
	end
	return result.ok(nil)
end

return table.freeze({
	parse = parse,
	layer = layer,
	crossCheck = crossCheck,
	hasBehaviourKeys = hasBehaviourKeys,
})
