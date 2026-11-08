--!strict
--[[
	Floor builder compiler: public API.

		local compiler = require(path.to.compiler)

		local compiled = compiler.compile(rootAssembly)
		if not compiled.ok then
			for _, d in compiled.err.errors do
				warn(compiler.formatDiagnostic(d))
			end
			return
		end
		local floor = compiled.val -- types.compiled_floor

	`compile` returns the shared Result type (ReplicatedStorage.shared.modules.result).
	On success the value is an immutable compiled floor that is independent of
	the source Instances and can be executed any number of times with any seed.
	On failure the error value lists every error and warning; no partial
	compiled floor is ever returned.

	See types.luau for the compiled representation and the execution contract
	the runtime builder must follow.
]]

local compilation = require(script.compilation)
local outline = require(script.compilation.outline)
local constants = require(script.constants)
local diagnostics = require(script.diagnostics)
local stream = require(script.stream)
local types = require(script.types)

export type severity = types.severity
export type diagnostic = types.diagnostic
export type compile_failure = types.compile_failure
export type compile_result = types.compile_result
export type node_id = types.node_id
export type model_id = types.model_id
export type source_info = types.source_info
export type edge = types.edge
export type candidate = types.candidate
export type assembly_node = types.assembly_node
export type try_node = types.try_node
export type pick_node = types.pick_node
export type fb_pick_mode = types.fb_pick_mode
export type each_node = types.each_node
export type counter_id = types.counter_id
export type model_node = types.model_node
export type node = types.node
export type connection = types.connection
export type overlap_volume = types.overlap_volume
export type model_entry = types.model_entry
export type compiled_floor = types.compiled_floor
export type outline_kind = types.outline_kind
export type outline_key = types.outline_key
export type outline_node = types.outline_node
export type analysis = types.analysis

export type stream_functions = {
	rootSeed: (seed: number) -> number,
	childSeed: (parentSeed: number, key: number, ordinal: number) -> number,
}

export type compiler = {
	-- Version of the compiled representation produced by this compiler.
	FORMAT_VERSION: number,
	-- Language names (prefixes, tags, attributes) for tools.
	constants: typeof(constants),
	compile: (source: Instance) -> compile_result,
	-- Compiles and returns an annotated outline of the source for tools.
	analyze: (source: Instance) -> analysis,
	-- What language construct an Instance is ("invalid" for Instances in a
	-- language position that are not valid nodes); nil for Folders.
	identify: (instance: Instance) -> outline_kind?,
	formatDiagnostic: (d: diagnostic) -> string,
	-- Random stream derivation the builder must use (see stream.luau).
	stream: stream_functions,
}

local function analyze(source: Instance): analysis
	local started = os.clock()
	local run = compilation.run(source)
	return outline.build(run, os.clock() - started)
end

local compiler: compiler = table.freeze({
	FORMAT_VERSION = constants.FORMAT_VERSION,
	constants = constants,
	compile = compilation.compile,
	analyze = analyze,
	identify = outline.identify,
	formatDiagnostic = diagnostics.format,
	stream = table.freeze({
		rootSeed = stream.rootSeed,
		childSeed = stream.childSeed,
	}),
})

return compiler
