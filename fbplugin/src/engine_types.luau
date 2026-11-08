--!strict
--[[
	Types of the compiler and builder APIs used by the plugin.

	The plugin loads the compiler and builder from the open place at runtime
	(see engine.luau), so their types cannot be imported statically. These
	declarations mirror the parts of modules/server/floorgen/compiler/types.luau
	and modules/server/floorgen/builder/types.luau the plugin uses. engine.luau checks the
	shape of what it loads before using it.
]]

export type diagnostic = {
	severity: "error" | "warning",
	code: string,
	message: string,
	path: string?,
	instance: Instance?,
	attribute: string?,
	hint: string?,
}

export type outline_kind = "assembly" | "try" | "pick" | "each" | "model" | "reference" | "invalid"

export type outline_key = { name: string, value: string? }

export type outline_node = {
	instance: Instance,
	kind: outline_kind,
	label: string,
	keys: { outline_key },
	children: { outline_node },
	target: Instance?,
	targetKind: outline_kind?,
	compiled: boolean,
	mayFail: boolean,
	handled: boolean,
	recursive: boolean,
	contested: boolean,
	diagnostics: { diagnostic },
}

-- Only the parts of a compiled floor the plugin inspects.
export type compiled_floor = {
	formatVersion: number,
	nodes: { unknown },
	models: { { name: string, sourcePath: string } },
	counters: number,
}

export type compile_result = { ok: true, val: compiled_floor } | { ok: false, err: { errors: { diagnostic }, warnings: { diagnostic } } }

export type analysis = {
	result: compile_result,
	root: outline_node?,
	definitions: { outline_node },
	diagnostics: { diagnostic },
	elapsed: number,
}

export type constants = {
	PREFIX_SEPARATOR: string,
	PREFIX: { assembly: string, try: string, pick: string, each: string, reference: string },
	TAG: {
		conditional: string,
		room: string,
		plug: string,
		optional: string,
		override: string,
		connection: string,
		removedAtomic: string,
	},
	ATTRIBUTE: {
		pickAmount: string,
		pickUnique: string,
		pickMode: string,
		pickWeight: string,
		attach: string,
		anchor: string,
		filter: string,
		maxDepth: string,
		maxCount: string,
	},
	OVERLAP_PART_NAME: string,
}

export type compiler = {
	FORMAT_VERSION: number,
	constants: constants,
	analyze: (source: Instance) -> analysis,
	identify: (instance: Instance) -> outline_kind?,
	formatDiagnostic: (d: diagnostic) -> string,
}

export type failure_reason = "overlap" | "count" | "recursion" | "connection"

export type trace_failure = {
	reason: failure_reason,
	node: number,
	source: { label: string, path: string, className: string }?,
	pivot: CFrame,
}

export type plan = {
	emissions: { { model: number, pivot: CFrame, node: number } },
	stats: { executions: number, failures: { [string]: number } },
	trace: { picks: { unknown }, failures: { trace_failure } }?,
}

export type builder_error = { code: string, message: string }

export type plan_result = { ok: true, val: plan } | { ok: false, err: builder_error }

export type plan_options = {
	seed: number,
	maxRecursionDepth: number?,
	origin: CFrame?,
	planningParent: Instance?,
	trace: boolean?,
}

export type builder = {
	plan: (floor: compiled_floor, options: plan_options) -> plan_result,
	commit: (plan: plan, parent: Instance?, name: string?) -> Model,
	DEFAULT_MAX_RECURSION_DEPTH: number,
}

return table.freeze({})
