--!strict
--[[
	Compilation driver.

	Pipeline:
		1. Source inspection     validate the root Instance
		2. Parsing               identify nodes, parse inline structure
		3. Resolution            resolve references, parse targets on demand
		4. Root validation       the root must be an unplaced, uncounted assembly
		5. Construction          validate configurations, overrides, models,
		                         structure and spatial metadata; register models;
		                         build the specialised execution graph
		   (includes connection scopes: which connection uses may collide)
		6. Recursion             mark reference edges that lie on cycles
		7. Failure analysis      prove that no failure can escape the root
		8. Verification          re-check every runtime invariant
		9. Freezing              produce the immutable compiled representation

	Every stage accumulates independent errors. Later stages tolerate missing
	pieces (they are skipped, never guessed), so one problem does not cascade
	into meaningless follow-up errors. Compilation is all-or-nothing: if any
	error was reported, no compiled representation is returned.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.constants)
local diagnostics = require(script.Parent.diagnostics)
local ir = require(script.Parent.ir)
local parser = require(script.Parent.parser)
local registryModule = require(script.Parent.registry)
local resolution = require(script.Parent.resolution)
local types = require(script.Parent.types)
local failurePaths = require(script.Parent.validation.failure_paths)
local construct = require(script.construct)
local freeze = require(script.freeze)
local recursion = require(script.recursion)
local verify = require(script.verify)

type session = ir.session
type definition = ir.definition
type node_config = ir.node_config
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors
local warningCodes = diagnostics.codes.warnings

local function newSession(): session
	return {
		sink = diagnostics.newSink(),
		definitions = {},
		definitionOf = {},
		referenceTargets = {},
		ownConfigs = {},
		referenceConfigs = {},
		modelFacts = {},
	}
end

type root = {
	definition: definition,
	-- Present when the root is a reference.
	reference: ir.reference_use?,
}

-- Stages 1-2: the root is an assembly Configuration, or a reference to one.
local function parseRoot(s: session, source: Instance): outcome<root>
	local classified = parser.classify(source)
	if not classified.ok then
		return classified
	end
	local classification = classified.val

	if classification.kind == "reference" then
		if not source:IsA("ObjectValue") then
			return diagnostics.fail(errors.INTERNAL_INVARIANT, source, "Reference root is not an ObjectValue.")
		end
		local ref: ir.reference_use = {
			instance = source,
			label = classification.label,
			path = diagnostics.pathOf(source),
			ownConfig = parser.readConfig(source),
		}
		local resolved = resolution.resolveReference(s, ref)
		if not resolved.ok then
			return resolved
		end
		return result.ok({ definition = s.definitions[resolved.val], reference = ref })
	elseif classification.kind == "container" or classification.kind == "model" then
		local parsed = parser.parseDefinition(s, source)
		if not parsed.ok then
			return parsed
		end
		return result.ok({ definition = s.definitions[parsed.val], reference = nil })
	end

	return diagnostics.fail(
		errors.ROOT_INVALID,
		source,
		"The root cannot be a Folder: Folders are never interpreted.",
		{ hint = "Pass the root 'asm <label>' Configuration to the compiler." }
	)
end

-- Stage 4: root invariants.
local function rootConfig(s: session, root: root): outcome<node_config>
	local def = root.definition
	local owner = if root.reference then root.reference.instance else def.instance
	if def.kind ~= "assembly" then
		return diagnostics.fail(
			errors.ROOT_NOT_ASSEMBLY,
			owner,
			string.format("The root must be an assembly, but it is a %s.", def.kind),
			{ hint = "Wrap the root in an 'asm <label>' Configuration." }
		)
	end

	local validated = if root.reference
		then construct.referenceConfig(s, root.reference, def)
		else construct.ownConfig(s, def)
	if not validated.ok then
		return validated
	end
	local config = validated.val.config

	local problems: { types.diagnostic } = {}
	if config.attach or config.anchor then
		table.insert(
			problems,
			diagnostics.makeError(
				errors.ROOT_PLACEMENT,
				owner,
				"The root has no parent to attach to.",
				{ attribute = constants.ATTRIBUTE.attach, hint = "Remove fb_attach and fb_anchor from the root." }
			)
		)
	end
	if config.maxCount ~= nil then
		table.insert(
			problems,
			diagnostics.makeError(
				errors.ROOT_COUNTED,
				owner,
				"The root is generated exactly once, so it cannot have fb_max_count.",
				{ attribute = constants.ATTRIBUTE.maxCount, hint = "Remove fb_max_count from the root." }
			)
		)
	end
	local noEffect: { string } = {}
	if config.pickWeight ~= nil then
		table.insert(noEffect, constants.ATTRIBUTE.pickWeight)
	end
	if config.optional then
		table.insert(noEffect, constants.TAG.optional)
	end
	if config.maxDepth ~= nil then
		table.insert(noEffect, constants.ATTRIBUTE.maxDepth)
	end
	for _, key in noEffect do
		diagnostics.warn(
			s.sink,
			warningCodes.KEY_NO_EFFECT,
			owner,
			string.format("%s has no effect on the root.", key),
			{ attribute = key }
		)
	end
	if #problems > 0 then
		return result.err(problems)
	end
	return result.ok(config)
end

-- Use-site keys that turned out to be meaningless where they are used.
local function warnIneffectiveEdges(s: session, g: ir.graph)
	for _, node in g.nodes do
		for _, edge in node.edges do
			if edge.maxDepth ~= nil and not edge.recursive then
				diagnostics.warn(
					s.sink,
					warningCodes.KEY_NO_EFFECT,
					edge.instance,
					"fb_max_depth only limits references that lead back into themselves; this one is not recursive.",
					{ attribute = constants.ATTRIBUTE.maxDepth }
				)
			end
			if edge.optional and not (edge.recursive or edge.contested or g.nodes[edge.node].mayFail) then
				diagnostics.warn(
					s.sink,
					warningCodes.KEY_NO_EFFECT,
					edge.instance,
					"fb_optional has no effect here: this can never fail.",
					{ attribute = constants.TAG.optional }
				)
			end
		end
	end
end

local function warnUnusedOverlaps(s: session, registry: registryModule.registry)
	for _, entry in registry.entries do
		if entry.overlap and not registry.usedConditionally[entry.id] then
			diagnostics.warn(
				s.sink,
				warningCodes.MODEL_OVERLAP_UNUSED,
				nil,
				string.format(
					"%s has an 'overlap' part but is never used as a conditional model; the part is not spawned.",
					entry.sourcePath
				),
				{ hint = "Tag the model fb_conditional_model, or rename the part." }
			)
		end
	end
end

local function failure(s: session): types.compile_result
	return result.err(table.freeze({
		errors = table.freeze(table.clone(s.sink.errors)),
		warnings = table.freeze(table.clone(s.sink.warnings)),
	}))
end

-- Everything a compilation produced, for tooling (see outline.luau).
export type run_output = {
	result: types.compile_result,
	session: session,
	-- Present when construction ran (also when compilation failed later).
	graph: ir.graph?,
	-- The root Instance as given.
	source: Instance?,
}

local function run(source: unknown): run_output
	local s = newSession()
	local function done(r: types.compile_result, graph: ir.graph?): run_output
		return {
			result = r,
			session = s,
			graph = graph,
			source = if typeof(source) == "Instance" then source else nil,
		}
	end

	-- 1. Source inspection.
	if typeof(source) ~= "Instance" then
		diagnostics.report(
			s.sink,
			diagnostics.makeError(
				errors.ROOT_INVALID,
				nil,
				string.format("compile expects an Instance, got %s.", typeof(source))
			)
		)
		return done(failure(s), nil)
	end

	-- 2. Parsing.
	local parsedRoot = parseRoot(s, source)
	local root = diagnostics.absorb(s.sink, parsedRoot)

	-- 3. Resolution (also covers definitions parsed before a root error).
	resolution.resolveAll(s)

	if root == nil then
		return done(failure(s), nil)
	end

	-- 4. Root validation.
	local config = diagnostics.absorb(s.sink, rootConfig(s, root))
	if config == nil then
		return done(failure(s), nil)
	end

	-- 5. Construction.
	local registry = registryModule.new()
	local graph = diagnostics.absorb(s.sink, construct.build(s, registry, root.definition, config))
	if graph == nil then
		return done(failure(s), nil)
	end

	-- 6. Recursion.
	recursion.markRecursiveEdges(graph)

	-- 7. Failure analysis. Runs even if earlier errors exist: missing pieces are
	-- simply absent from the graph, which can only hide failures, never invent
	-- them, so every failure reported here is real.
	diagnostics.absorb(s.sink, failurePaths.check(graph))

	warnUnusedOverlaps(s, registry)
	warnIneffectiveEdges(s, graph)

	if #s.sink.errors > 0 then
		return done(failure(s), graph)
	end

	-- 8. Verification.
	local verified = verify.verify(graph, registry)
	if not verified.ok then
		diagnostics.reportAll(s.sink, verified.err)
		return done(failure(s), graph)
	end

	-- 9. Freezing.
	return done(result.ok(freeze.freeze(graph, registry, s.sink.warnings)), graph)
end

local function compile(source: unknown): types.compile_result
	return run(source).result
end

return table.freeze({
	compile = compile,
	run = run,
})
