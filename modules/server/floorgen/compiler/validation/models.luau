--!strict
--[[
	Model inspection and validation.

	Reads the facts the compiler needs from a source Model without modifying
	it: PrimaryPart and its authoring frame, connection Attachments, and the
	overlap part. Results are memoised per Model in the session.

	Rules:
		* A model must have a PrimaryPart that is one of its descendants.
		* Connection points are Attachments tagged fb_connection. Each must be
		  parented to a BasePart and have a non-empty name that is unique among
		  the model's connections.
		* The overlap volume is the single descendant BasePart named "overlap".
		  Whether it is required depends on how the model is used (conditional
		  models need exactly one), so its count is recorded here and enforced
		  where the effective configuration is known.
		* Models do not own language nodes. Descendants named like nodes are
		  never interpreted and produce a warning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local types = require(script.Parent.Parent.types)
local node = require(script.Parent.Parent.parser.node)

type model_facts = ir.model_facts
type session = ir.session
type diagnostic = diagnostics.diagnostic
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors
local warningCodes = diagnostics.codes.warnings

local function inspectUncached(session: session, model: Model): outcome<model_facts>
	local primaryPart = model.PrimaryPart
	if primaryPart == nil or not primaryPart:IsDescendantOf(model) then
		return diagnostics.fail(
			errors.MODEL_NO_PRIMARY_PART,
			model,
			"Every model used by the floor builder needs a PrimaryPart.",
			{ attribute = "PrimaryPart", hint = "Set the Model's PrimaryPart to the part that should act as its pivot." }
		)
	end

	local pivot = primaryPart.CFrame
	local problems: { diagnostic } = {}
	local connections: { types.connection } = {}
	local connectionByName: { [string]: CFrame } = {}
	local connectionNames: { [string]: boolean } = {}
	local overlapCount = 0
	local overlapIsPrimaryPart = false
	local nodeLike = 0

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == constants.OVERLAP_PART_NAME then
			overlapCount += 1
			if descendant == primaryPart then
				overlapIsPrimaryPart = true
			end
		elseif descendant:IsA("Attachment") and descendant:HasTag(constants.TAG.connection) then
			local parent = descendant.Parent
			if parent == nil or not parent:IsA("BasePart") then
				table.insert(
					problems,
					diagnostics.makeError(
						errors.CONNECTION_INVALID_PARENT,
						descendant,
						"Connection Attachments must be parented directly to a BasePart.",
						{ attribute = constants.TAG.connection }
					)
				)
			elseif descendant.Name == "" then
				table.insert(
					problems,
					diagnostics.makeError(
						errors.CONNECTION_EMPTY_NAME,
						descendant,
						"Connection Attachments need a name; fb_attach and fb_anchor refer to them by name.",
						{ attribute = "Name" }
					)
				)
			elseif connectionNames[descendant.Name] then
				table.insert(
					problems,
					diagnostics.makeError(
						errors.CONNECTION_DUPLICATE_NAME,
						descendant,
						string.format("The model already has a connection named '%s'.", descendant.Name),
						{ attribute = "Name", hint = "Connection names must be unique within a model." }
					)
				)
			else
				local offset = pivot:ToObjectSpace(parent.CFrame * descendant.CFrame)
				connectionByName[descendant.Name] = offset
				connectionNames[descendant.Name] = true
				table.insert(connections, table.freeze({ name = descendant.Name, offset = offset }))
			end
		elseif node.looksLikeNode(descendant) then
			nodeLike += 1
		end
	end

	if nodeLike > 0 then
		diagnostics.warn(
			session.sink,
			warningCodes.MODEL_CONTAINS_NODES,
			model,
			string.format(
				"%d descendant(s) are named like language nodes. Models do not own language nodes, so they are ignored.",
				nodeLike
			),
			{ hint = "Move language nodes next to the model, inside the assembly." }
		)
	end

	if #problems > 0 then
		return result.err(problems)
	end

	table.sort(connections, function(a, b)
		return a.name < b.name
	end)

	return result.ok(table.freeze({
		model = model,
		path = diagnostics.pathOf(model),
		primaryPart = primaryPart,
		pivot = pivot,
		connections = table.freeze(connections),
		connectionByName = table.freeze(connectionByName),
		overlapCount = overlapCount,
		overlapIsPrimaryPart = overlapIsPrimaryPart,
	}))
end

local function inspect(session: session, model: Model): outcome<model_facts>
	local memo = session.modelFacts[model]
	if type(memo) == "table" then
		return result.ok(memo)
	elseif memo == false then
		-- Already reported.
		return result.err({})
	end
	local inspected = inspectUncached(session, model)
	if inspected.ok then
		session.modelFacts[model] = inspected.val
		return inspected
	end
	session.modelFacts[model] = false
	diagnostics.reportAll(session.sink, inspected.err)
	return result.err({})
end

-- Errors for using a model as a conditional model.
local function checkConditional(facts: model_facts): outcome<nil>
	if facts.overlapCount == 0 then
		return diagnostics.fail(
			errors.MODEL_OVERLAP_MISSING,
			facts.model,
			"Conditional models (fb_conditional_model) need a BasePart named 'overlap' defining their collision volume.",
			{ attribute = constants.TAG.conditional, hint = "Add a BasePart named 'overlap', or remove the tag." }
		)
	end
	if facts.overlapCount > 1 then
		return diagnostics.fail(
			errors.MODEL_OVERLAP_AMBIGUOUS,
			facts.model,
			string.format("Found %d BaseParts named 'overlap'; exactly one is required.", facts.overlapCount),
			{ attribute = constants.TAG.conditional, hint = "Combine the volumes into one part (a union is fine)." }
		)
	end
	if facts.overlapIsPrimaryPart then
		return diagnostics.fail(
			errors.MODEL_OVERLAP_IS_PRIMARY_PART,
			facts.model,
			"The overlap part cannot be the PrimaryPart: it is removed from the spawned model.",
			{ attribute = "PrimaryPart" }
		)
	end
	return result.ok(nil)
end

return table.freeze({
	inspect = inspect,
	checkConditional = checkConditional,
})
