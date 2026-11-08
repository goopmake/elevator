--!strict
--[[
	Outline: an annotated view of the source hierarchy for tools.

	Built from a compilation run, whether or not it succeeded, so editors can
	show every node with its diagnostics and analysis results (can it fail, is
	that handled, is it recursive or contested) next to the source Instance.
]]

local ir = require(script.Parent.Parent.ir)
local parser = require(script.Parent.Parent.parser)
local types = require(script.Parent.Parent.types)
local constants = require(script.Parent.Parent.constants)

type outline_node = types.outline_node
type outline_kind = types.outline_kind
type diagnostic = types.diagnostic

export type run = {
	result: types.compile_result,
	session: ir.session,
	graph: ir.graph?,
	source: Instance?,
}

type use_info = {
	fails: boolean,
	handled: boolean,
	recursive: boolean,
	contested: boolean,
}

-- Whether an Instance appears in the outline (Folders do not).
local function isShown(instance: Instance): boolean
	local classified = parser.classify(instance)
	return not classified.ok or classified.val.kind ~= "ignored"
end

-- What a shown Instance is.
local function kindOf(instance: Instance): outline_kind
	local classified = parser.classify(instance)
	if not classified.ok then
		return "invalid"
	end
	local c = classified.val
	if c.kind == "model" then
		return "model"
	elseif c.kind == "reference" then
		return "reference"
	elseif c.kind == "container" then
		return c.nodeKind
	end
	return "invalid"
end

-- Comparisons are kept in helpers so the kind keeps its singleton type.
local function hasChildren(kind: outline_kind): boolean
	return kind == "assembly" or kind == "try" or kind == "pick" or kind == "each"
end

local function isReference(kind: outline_kind): boolean
	return kind == "reference"
end

local function labelOf(instance: Instance): string
	local classified = parser.classify(instance)
	if classified.ok then
		local c = classified.val
		if c.kind == "container" or c.kind == "reference" then
			return c.label
		end
	end
	return instance.Name
end

local function formatValue(value: unknown): string
	if typeof(value) == "NumberRange" then
		local range = value
		return string.format("%s..%s", tostring(range.Min), tostring(range.Max))
	elseif type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function keysOf(instance: Instance): { types.outline_key }
	local raw = parser.readConfig(instance)
	local keys: { types.outline_key } = {}
	for _, tag in raw.tags do
		table.insert(keys, table.freeze({ name = tag, value = nil }))
	end
	for _, name in raw.attributeNames do
		table.insert(keys, table.freeze({ name = name, value = formatValue(raw.attributes[name]) }))
	end
	return table.freeze(keys)
end

local function isContainer(instance: Instance): boolean
	if instance.ClassName ~= constants.CLASS.container then
		return false
	end
	local classified = parser.classify(instance)
	return classified.ok and classified.val.kind == "container"
end

local function build(r: run, elapsed: number): types.analysis
	-- Diagnostics by Instance.
	local byInstance: { [Instance]: { diagnostic } } = {}
	local all: { diagnostic } = {}
	local compileErrors: { diagnostic }
	local compileWarnings: { diagnostic }
	if r.result.ok then
		compileErrors = {}
		compileWarnings = r.result.val.warnings
	else
		compileErrors = r.result.err.errors
		compileWarnings = r.result.err.warnings
	end
	for _, list in { compileErrors, compileWarnings } do
		for _, d in list do
			table.insert(all, d)
			local instance = d.instance
			if instance then
				local entries = byInstance[instance] or {}
				table.insert(entries, d)
				byInstance[instance] = entries
			end
		end
	end

	-- Analysis results by Instance.
	local uses: { [Instance]: use_info } = {}
	local nodes: { [Instance]: boolean } = {}
	local graph = r.graph
	if graph then
		for _, node in graph.nodes do
			local instance = node.definition.instance
			nodes[instance] = (nodes[instance] or false) or node.mayFail
			local function record(edge: ir.edge_draft)
				local fails = edge.recursive or edge.contested or graph.nodes[edge.node].mayFail
				local info = uses[edge.instance]
				if info then
					info.fails = info.fails or fails
					info.handled = info.handled and edge.optional
					info.recursive = info.recursive or edge.recursive
					info.contested = info.contested or edge.contested
				else
					uses[edge.instance] = {
						fails = fails,
						handled = edge.optional,
						recursive = edge.recursive,
						contested = edge.contested,
					}
				end
			end
			for _, edge in node.edges do
				record(edge)
			end
			for _, edge in node.plugs do
				record(edge)
			end
		end
	end

	local outlined: { [Instance]: boolean } = {}

	local function outline(instance: Instance): outline_node?
		if not isShown(instance) then
			return nil
		end
		local kind: outline_kind = kindOf(instance)
		outlined[instance] = true

		local children: { outline_node } = {}
		if hasChildren(kind) then
			for _, child in instance:GetChildren() do
				local node = outline(child)
				if node then
					table.insert(children, node)
				end
			end
		end

		local target: Instance? = nil
		local targetKind: outline_kind? = nil
		if isReference(kind) and instance:IsA("ObjectValue") then
			target = instance.Value
			if target then
				targetKind = if isShown(target) then kindOf(target) else "invalid"
			end
		end

		local use = uses[instance]
		local nodeFails = nodes[instance]
		local node: outline_node = {
			instance = instance,
			kind = kind,
			label = labelOf(instance),
			keys = keysOf(instance),
			children = table.freeze(children),
			target = target,
			targetKind = targetKind,
			compiled = use ~= nil or nodeFails ~= nil,
			mayFail = (use ~= nil and use.fails) or nodeFails == true,
			handled = use ~= nil and use.handled,
			recursive = use ~= nil and use.recursive,
			contested = use ~= nil and use.contested,
			diagnostics = table.freeze(byInstance[instance] or {}),
		}
		return table.freeze(node)
	end

	local root = if r.source then outline(r.source) else nil

	-- Referenced definitions outside the root hierarchy, outlined from their
	-- topmost enclosing language node.
	local definitions: { outline_node } = {}
	for _, def in r.session.definitions do
		local instance = def.instance
		if outlined[instance] then
			continue
		end
		local top = instance
		while true do
			local parent = top.Parent
			if parent == nil or not isContainer(parent) then
				break
			end
			top = parent
		end
		if not outlined[top] then
			local node = outline(top)
			if node then
				table.insert(definitions, node)
			end
		end
	end

	return table.freeze({
		result = r.result,
		root = root,
		definitions = table.freeze(definitions),
		diagnostics = table.freeze(all),
		elapsed = elapsed,
	})
end

-- What language construct an Instance is; nil for Folders (never interpreted).
local function identify(instance: Instance): outline_kind?
	if not isShown(instance) then
		return nil
	end
	return kindOf(instance)
end

return table.freeze({
	build = build,
	identify = identify,
})
