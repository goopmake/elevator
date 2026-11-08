--!strict
--[[
	Pure presentation logic: turns analyses into rows, badges and text.
	No Instances are created here, so it is unit-tested headlessly.
]]

local engineTypes = require(script.Parent.engine_types)

type outline_node = engineTypes.outline_node
type outline_kind = engineTypes.outline_kind
type diagnostic = engineTypes.diagnostic
type analysis = engineTypes.analysis

export type tone = "error" | "warning" | "fail" | "handled" | "info" | "muted" | "normal"

export type badge = {
	text: string,
	tone: tone,
}

export type row = {
	-- Either a node row or a section header.
	node: outline_node?,
	header: string?,
	depth: number,
	hasChildren: boolean,
	expanded: boolean,
}

local KIND_TAG: { [outline_kind]: string } = {
	assembly = "asm",
	try = "try",
	pick = "pick",
	each = "each",
	model = "model",
	reference = "ref",
	invalid = "??",
}

local function kindTag(kind: outline_kind): string
	return KIND_TAG[kind] or "?"
end

-- "fb_pick_amount" + "2" -> "pick_amount=2"; tags lose their prefix too.
local function keyText(key: engineTypes.outline_key): string
	local name = key.name
	if string.sub(name, 1, 3) == "fb_" then
		name = string.sub(name, 4)
	end
	if key.value == nil then
		return name
	end
	return name .. "=" .. key.value
end

local function countSeverity(list: { diagnostic }, severity: "error" | "warning"): number
	local n = 0
	for _, d in list do
		if d.severity == severity then
			n += 1
		end
	end
	return n
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

-- Status badges of a node, most important first.
local function badges(node: outline_node, compiledOk: boolean): { badge }
	local list: { badge } = {}
	local errors = countSeverity(node.diagnostics, "error")
	local warnings = countSeverity(node.diagnostics, "warning")
	if errors > 0 then
		table.insert(list, { text = plural(errors, "error"), tone = "error" })
	end
	if warnings > 0 then
		table.insert(list, { text = plural(warnings, "warning"), tone = "warning" })
	end
	if node.mayFail then
		if node.handled then
			table.insert(list, { text = "may fail · handled", tone = "handled" })
		elseif node.kind ~= "try" then
			table.insert(list, { text = "may fail", tone = "fail" })
		end
	end
	if node.contested then
		table.insert(list, { text = "contested", tone = "fail" })
	end
	if node.recursive then
		table.insert(list, { text = "recursive", tone = "info" })
	end
	if compiledOk and not node.compiled and node.kind ~= "invalid" then
		table.insert(list, { text = "unused", tone = "muted" })
	end
	return list
end

-- Main text of a row: kind tag, label and the keys set on the Instance.
local function rowText(node: outline_node): string
	local parts = { string.format("[%s] %s", kindTag(node.kind), if node.label == "" then "(no label)" else node.label) }
	if node.kind == "reference" then
		if node.target then
			table.insert(parts, string.format("→ %s", node.target.Name))
		else
			table.insert(parts, "→ (empty)")
		end
	end
	local keys = {}
	for _, key in node.keys do
		table.insert(keys, keyText(key))
	end
	if #keys > 0 then
		table.insert(parts, "{" .. table.concat(keys, ", ") .. "}")
	end
	return table.concat(parts, "  ")
end

-- The strongest tone among a node's badges, for colouring its label.
local function rowTone(node: outline_node): tone
	if countSeverity(node.diagnostics, "error") > 0 then
		return "error"
	elseif countSeverity(node.diagnostics, "warning") > 0 then
		return "warning"
	end
	return "normal"
end

-- Whether a node or any descendant has an error (for collapsed rows).
local function subtreeHasErrors(node: outline_node): boolean
	if countSeverity(node.diagnostics, "error") > 0 then
		return true
	end
	for _, child in node.children do
		if subtreeHasErrors(child) then
			return true
		end
	end
	return false
end

--[[
	Flattens the outline into visible rows. `expanded` maps Instances to their
	expansion state; nodes default to expanded down to `autoDepth`.
]]
local function flatten(a: analysis, expanded: { [Instance]: boolean }, autoDepth: number): { row }
	local rows: { row } = {}
	local function visit(node: outline_node, depth: number)
		local hasChildren = #node.children > 0
		local state = expanded[node.instance]
		local isExpanded = if state == nil then depth < autoDepth else state
		table.insert(rows, { node = node, header = nil, depth = depth, hasChildren = hasChildren, expanded = isExpanded })
		if hasChildren and isExpanded then
			for _, child in node.children do
				visit(child, depth + 1)
			end
		end
	end
	if a.root then
		visit(a.root, 0)
	end
	if #a.definitions > 0 then
		table.insert(rows, {
			node = nil,
			header = "Referenced definitions outside the root",
			depth = 0,
			hasChildren = false,
			expanded = false,
		})
		for _, def in a.definitions do
			visit(def, 0)
		end
	end
	return rows
end

-- Instances from the outline root to `target` (inclusive), or nil.
local function ancestry(a: analysis, target: Instance): { Instance }?
	local trail: { Instance } = {}
	local function search(node: outline_node): boolean
		table.insert(trail, node.instance)
		if node.instance == target then
			return true
		end
		for _, child in node.children do
			if search(child) then
				return true
			end
		end
		table.remove(trail)
		return false
	end
	if a.root and search(a.root) then
		return trail
	end
	for _, def in a.definitions do
		trail = {}
		if search(def) then
			return trail
		end
	end
	return nil
end

local function findNode(a: analysis, target: Instance): outline_node?
	local function search(node: outline_node): outline_node?
		if node.instance == target then
			return node
		end
		for _, child in node.children do
			local found = search(child)
			if found then
				return found
			end
		end
		return nil
	end
	if a.root then
		local found = search(a.root)
		if found then
			return found
		end
	end
	for _, def in a.definitions do
		local found = search(def)
		if found then
			return found
		end
	end
	return nil
end

local function countNodes(a: analysis): number
	local n = 0
	local function visit(node: outline_node)
		n += 1
		for _, child in node.children do
			visit(child)
		end
	end
	if a.root then
		visit(a.root)
	end
	for _, def in a.definitions do
		visit(def)
	end
	return n
end

-- One-line status of an analysis.
local function summary(a: analysis): (string, tone)
	local errors = countSeverity(a.diagnostics, "error")
	local warnings = countSeverity(a.diagnostics, "warning")
	local parts = {}
	local tone: tone
	if errors > 0 then
		table.insert(parts, plural(errors, "error"))
		tone = "error"
	else
		table.insert(parts, "OK")
		tone = if warnings > 0 then "warning" else "normal"
	end
	if warnings > 0 then
		table.insert(parts, plural(warnings, "warning"))
	end
	table.insert(parts, plural(countNodes(a), "node"))
	table.insert(parts, string.format("%.1f ms", a.elapsed * 1000))
	return table.concat(parts, " · "), tone
end

local function diagnosticLine(d: diagnostic): string
	local marker = if d.severity == "error" then "E" else "W"
	local where = d.path or "(no instance)"
	return string.format("%s  %s  %s — %s", marker, d.code, where, d.message)
end

local KIND_NAME: { [outline_kind]: string } = {
	assembly = "Assembly (all-or-nothing group, pivot = its room)",
	try = "Try (first alternative that succeeds; never fails)",
	pick = "Pick (random selection)",
	each = "Each (its child on every free room connection)",
	model = "Model",
	reference = "Reference",
	invalid = "Not a valid language node",
}

-- Multi-line description of a node for the details pane.
local function details(node: outline_node): string
	local lines = {
		KIND_NAME[node.kind] or node.kind,
		"Path: " .. node.instance:GetFullName(),
	}
	if node.kind == "reference" then
		local target = node.target
		if target then
			table.insert(lines, string.format("Target: %s (%s)", target:GetFullName(), node.targetKind or "?"))
		else
			table.insert(lines, "Target: none")
		end
	end
	if #node.keys > 0 then
		local keys = {}
		for _, key in node.keys do
			table.insert(keys, keyText(key))
		end
		table.insert(lines, "Keys: " .. table.concat(keys, ", "))
	end
	if node.compiled then
		if node.mayFail and node.handled then
			table.insert(lines, "Can fail at runtime; handled here (fb_optional).")
		elseif node.mayFail then
			table.insert(lines, "Can fail at runtime; the failure goes up to the nearest try or optional.")
		else
			table.insert(lines, "Cannot fail at runtime.")
		end
		if node.recursive then
			table.insert(lines, "Recursive: leads back into itself; limited by the recursion depth.")
		end
		if node.contested then
			table.insert(lines, "Contested: its connection may already be used when it runs.")
		end
	end
	for _, d in node.diagnostics do
		table.insert(lines, "")
		table.insert(lines, string.format("%s %s: %s", if d.severity == "error" then "Error" else "Warning", d.code, d.message))
		if d.hint then
			table.insert(lines, "Hint: " .. d.hint)
		end
	end
	return table.concat(lines, "\n")
end

return table.freeze({
	kindTag = kindTag,
	keyText = keyText,
	badges = badges,
	rowText = rowText,
	rowTone = rowTone,
	subtreeHasErrors = subtreeHasErrors,
	flatten = flatten,
	ancestry = ancestry,
	findNode = findNode,
	countNodes = countNodes,
	summary = summary,
	diagnosticLine = diagnosticLine,
	details = details,
})
