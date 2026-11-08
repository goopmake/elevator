--!strict
--[[
	Structural parsing of the children of a container node (asm / try / pick).

	Children are visited in authored order (GetChildren order), which is the
	semantic order of try alternatives, assembly emission and pick candidates.
	Folders are skipped entirely together with all their descendants.

	Reference targets are not followed here: references are recorded as uses
	and resolved by the resolution stage.
]]

local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local node = require(script.Parent.node)
local source = require(script.Parent.source)

type session = ir.session
type definition = ir.definition
type child = ir.child

local warningCodes = diagnostics.codes.warnings

-- Parses one child Instance into a definition id. Provided by parser/init so
-- that this module does not depend on it.
export type parse_inline = (session: session, instance: Instance) -> diagnostics.outcome<number>

local function parseChildren(session: session, parent: definition, parseInline: parse_inline): ({ child }, boolean)
	local children: { child } = {}
	local complete = true

	for _, instance in parent.instance:GetChildren() do
		local classified = node.classify(instance)
		if not classified.ok then
			diagnostics.reportAll(session.sink, classified.err)
			complete = false
			continue
		end

		local classification = classified.val
		if classification.kind == "ignored" then
			continue
		elseif classification.kind == "reference" then
			-- classify only returns "reference" for ObjectValues.
			if not instance:IsA("ObjectValue") then
				diagnostics.report(
					session.sink,
					diagnostics.makeError(
						diagnostics.codes.errors.INTERNAL_INVARIANT,
						instance,
						"A reference was identified on an Instance that is not an ObjectValue."
					)
				)
				complete = false
				continue
			end
			local entry: child = {
				kind = "reference",
				instance = instance,
				reference = {
					instance = instance,
					label = classification.label,
					path = diagnostics.pathOf(instance),
					ownConfig = source.readConfig(instance),
				},
			}
			table.insert(children, entry)
		else
			if classification.kind == "model" and classification.namedLikeNode then
				diagnostics.warn(
					session.sink,
					warningCodes.MODEL_NAMED_LIKE_NODE,
					instance,
					"This Model is named like a language node but is treated as a model declaration.",
					{ hint = "Use a Configuration for asm/try/pick nodes, or rename the Model." }
				)
			end
			local parsed = parseInline(session, instance)
			if parsed.ok then
				local entry: child = {
					kind = "inline",
					instance = instance,
					definition = parsed.val,
				}
				table.insert(children, entry)
			else
				diagnostics.reportAll(session.sink, parsed.err)
				complete = false
			end
		end
	end

	return children, complete
end

return table.freeze({
	parseChildren = parseChildren,
})
