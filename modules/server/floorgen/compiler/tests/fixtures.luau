--!strict
--[[
	Test fixtures: concise construction of source hierarchies.

	Everything is created with Instance.new, so fixtures work in Studio (TestEZ)
	and in the headless Lune runner alike.
]]

local compiler = require(script.Parent.Parent)
local constants = require(script.Parent.Parent.constants)

export type options = {
	attributes: { [string]: unknown }?,
	tags: { string }?,
	children: { Instance }?,
}

export type model_options = {
	cframe: CFrame?,
	attributes: { [string]: unknown }?,
	tags: { string }?,
	-- Overlap part frame relative to the PrimaryPart.
	overlap: CFrame?,
	overlapSize: Vector3?,
	-- Connection Attachments on the PrimaryPart, relative to it.
	connections: { { name: string, cframe: CFrame } }?,
	-- Leave PrimaryPart unset.
	noPrimaryPart: boolean?,
}

local fixtures = {}

local function apply(instance: Instance, options: options?)
	if options == nil then
		return
	end
	if options.attributes then
		local names = {}
		for name in options.attributes do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			instance:SetAttribute(name, options.attributes[name])
		end
	end
	if options.tags then
		for _, tag in options.tags do
			instance:AddTag(tag)
		end
	end
	if options.children then
		for _, child in options.children do
			child.Parent = instance
		end
	end
end

function fixtures.node(className: string, name: string, options: options?): Instance
	local instance = Instance.new(className)
	instance.Name = name
	apply(instance, options)
	return instance
end

function fixtures.asm(label: string, children: { Instance }?, options: options?): Instance
	local o: options = options or {}
	return fixtures.node("Configuration", "asm " .. label, {
		attributes = o.attributes,
		tags = o.tags,
		children = children,
	})
end

function fixtures.each(label: string, children: { Instance }?, filter: string?): Instance
	return fixtures.node("Configuration", "each " .. label, {
		attributes = if filter then { [constants.ATTRIBUTE.filter] = filter } else nil,
		children = children,
	})
end

-- Tags an Instance fb_optional and returns it.
function fixtures.optional<T>(instance: T & Instance): T
	instance:AddTag(constants.TAG.optional)
	return instance
end

function fixtures.try(label: string, children: { Instance }?): Instance
	return fixtures.node("Configuration", "try " .. label, { children = children })
end

function fixtures.pick(label: string, amount: number | NumberRange, children: { Instance }?, unique: boolean?): Instance
	local attributes: { [string]: unknown } = { [constants.ATTRIBUTE.pickAmount] = amount }
	if unique ~= nil then
		attributes[constants.ATTRIBUTE.pickUnique] = unique
	end
	return fixtures.node("Configuration", "pick " .. label, { attributes = attributes, children = children })
end

function fixtures.ref(label: string, target: Instance?, options: options?): Instance
	local instance = Instance.new("ObjectValue")
	instance.Name = "ref " .. label
	if target ~= nil then
		instance.Value = target
	end
	apply(instance, options)
	return instance
end

function fixtures.folder(name: string, children: { Instance }?): Instance
	return fixtures.node("Folder", name, { children = children })
end

function fixtures.model(name: string, options: model_options?): Model
	local o: model_options = options or {}
	local model = Instance.new("Model")
	model.Name = name
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Size = Vector3.new(4, 1, 4)
	base.CFrame = o.cframe or CFrame.identity
	base.Parent = model
	if not o.noPrimaryPart then
		model.PrimaryPart = base
	end
	if o.overlap then
		local overlap = Instance.new("Part")
		overlap.Name = constants.OVERLAP_PART_NAME
		overlap.Size = o.overlapSize or Vector3.new(2, 2, 2)
		overlap.CFrame = base.CFrame * o.overlap
		overlap.Parent = model
	end
	if o.connections then
		for _, connection in o.connections do
			local attachment = Instance.new("Attachment")
			attachment.Name = connection.name
			attachment.CFrame = connection.cframe
			attachment:AddTag(constants.TAG.connection)
			attachment.Parent = base
		end
	end
	apply(model, { attributes = o.attributes, tags = o.tags })
	return model
end

-- A conditional model with a 2x2x2 overlap volume centred on its pivot.
function fixtures.conditional(name: string, options: model_options?): Model
	local o: model_options = table.clone(options or {})
	local tags = table.clone(o.tags or {})
	table.insert(tags, constants.TAG.conditional)
	o.tags = tags
	o.overlap = o.overlap or CFrame.identity
	return fixtures.model(name, o)
end

-- A room model (tagged fb_room).
function fixtures.room(name: string, options: model_options?): Model
	local o: model_options = table.clone(options or {})
	local tags = table.clone(o.tags or {})
	table.insert(tags, constants.TAG.room)
	o.tags = tags
	return fixtures.model(name, o)
end

-- Compiles and returns (ok, value-or-failure).
function fixtures.compile(root: Instance): compiler.compile_result
	return compiler.compile(root)
end

function fixtures.compileOk(root: Instance): compiler.compiled_floor
	local compiled = compiler.compile(root)
	if not compiled.ok then
		local lines = {}
		for _, d in compiled.err.errors do
			table.insert(lines, compiler.formatDiagnostic(d))
		end
		error("expected compilation to succeed:\n" .. table.concat(lines, "\n"), 2)
	end
	return compiled.val
end

function fixtures.compileErr(root: Instance): compiler.compile_failure
	local compiled = compiler.compile(root)
	if compiled.ok then
		error("expected compilation to fail", 2)
	end
	return compiled.err
end

-- Error codes of a failure, in report order.
function fixtures.codes(list: { compiler.diagnostic }): { string }
	local codes = {}
	for _, d in list do
		table.insert(codes, d.code)
	end
	return codes
end

function fixtures.count(list: { compiler.diagnostic }, code: string): number
	local n = 0
	for _, d in list do
		if d.code == code then
			n += 1
		end
	end
	return n
end

function fixtures.find(list: { compiler.diagnostic }, code: string): compiler.diagnostic?
	for _, d in list do
		if d.code == code then
			return d
		end
	end
	return nil
end

-- Nodes of a kind whose source label is `label`.
function fixtures.nodesLabelled(floor: compiler.compiled_floor, label: string): { compiler.node }
	local found = {}
	for _, n in floor.nodes do
		if n.source.label == label then
			table.insert(found, n)
		end
	end
	return found
end

function fixtures.cframeNear(a: CFrame, b: CFrame, epsilon: number?): boolean
	local e = epsilon or 1e-4
	local ca = { a:GetComponents() }
	local cb = { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ca[i] - cb[i]) > e then
			return false
		end
	end
	return true
end

return fixtures
