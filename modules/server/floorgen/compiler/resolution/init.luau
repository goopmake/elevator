--!strict
--[[
	Reference resolution stage.

	Resolves every reference reachable from the definitions parsed so far,
	parsing newly discovered targets on demand. Because definitions are
	memoised by Instance, cyclic references resolve to existing definitions and
	the loop terminates: each Instance is parsed at most once.

	Targets are never inlined. Recursive structure is preserved as definition
	ids and becomes graph edges during construction.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local diagnostics = require(script.Parent.diagnostics)
local ir = require(script.Parent.ir)
local parser = require(script.Parent.parser)
local overrides = require(script.overrides)
local references = require(script.references)

type session = ir.session
type reference_use = ir.reference_use
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors

-- Resolves a single reference to a definition id, parsing its target if needed.
local function resolveReference(session: session, ref: reference_use): outcome<number>
	local memo = session.referenceTargets[ref.instance]
	if type(memo) == "number" then
		return result.ok(memo)
	elseif memo == false then
		-- Already reported.
		return result.err({})
	end

	local target = references.resolveTarget(ref)
	if not target.ok then
		session.referenceTargets[ref.instance] = false
		return target
	end

	local parsed = parser.parseDefinition(session, target.val)
	if not parsed.ok then
		session.referenceTargets[ref.instance] = false
		-- Report the target's own problem and explain the consequence once.
		local list = table.clone(parsed.err)
		table.insert(
			list,
			diagnostics.makeError(
				errors.REFERENCE_TARGET_INVALID,
				ref.instance,
				string.format("The target %s could not be parsed.", diagnostics.pathOf(target.val)),
				{ attribute = "Value", hint = "Fix the errors reported for the target." }
			)
		)
		return result.err(list)
	end

	session.referenceTargets[ref.instance] = parsed.val
	return result.ok(parsed.val)
end

-- Resolves all references of all definitions, including definitions that
-- are discovered while resolving.
local function resolveAll(session: session)
	local index = 1
	while index <= #session.definitions do
		local def = session.definitions[index]
		for _, child in def.children do
			if child.kind == "reference" then
				local resolved = resolveReference(session, child.reference)
				if not resolved.ok then
					diagnostics.reportAll(session.sink, resolved.err)
				end
			end
		end
		index += 1
	end
end

-- The resolved target of a reference, or nil if it was unresolvable.
local function targetOf(session: session, ref: reference_use): number?
	local memo = session.referenceTargets[ref.instance]
	return if type(memo) == "number" then memo else nil
end

return table.freeze({
	resolveReference = resolveReference,
	resolveAll = resolveAll,
	targetOf = targetOf,
	hasBehaviourOverrides = overrides.hasBehaviourOverrides,
	hasKeys = overrides.hasKeys,
	peekEffectiveTags = overrides.peekEffectiveTags,
	peekTarget = references.peekTarget,
})
