--!strict
--[[
	Diagnostic construction and accumulation.

	Fallible compiler operations return `outcome<T>`: the shared Result type
	whose error payload is a list of error diagnostics. Errors are accumulated
	by callers into a `sink` so that independent problems are all reported.
	Warnings never make an operation fail; they are reported straight into the
	sink.

	Memoised operations (model inspection, registration, reference resolution,
	configuration validation) report their errors to the sink themselves,
	exactly once, and fail with an EMPTY list on that and later calls. An empty
	error list therefore means "failed, already reported"; it never means
	success.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)
local types = require(script.Parent.types)

local errors = require(script.errors)
local warnings = require(script.warnings)

export type diagnostic = types.diagnostic
type severity = types.severity

export type outcome<T> = result.result<T, { diagnostic }>

export type details = {
	attribute: string?,
	hint: string?,
}

export type sink = {
	errors: { diagnostic },
	warnings: { diagnostic },
	-- Deduplication keys of everything reported so far.
	seen: { [string]: boolean },
}

local function pathOf(instance: Instance): string
	return instance:GetFullName()
end

local function make(
	severity: severity,
	code: string,
	instance: Instance?,
	message: string,
	details: details?
): diagnostic
	return table.freeze({
		severity = severity,
		code = code,
		message = message,
		path = if instance then pathOf(instance) else nil,
		instance = instance,
		attribute = if details then details.attribute else nil,
		hint = if details then details.hint else nil,
	})
end

local function makeError(code: string, instance: Instance?, message: string, details: details?): diagnostic
	return make("error", code, instance, message, details)
end

local function makeWarning(code: string, instance: Instance?, message: string, details: details?): diagnostic
	return make("warning", code, instance, message, details)
end

-- Shorthand for an operation that failed with a single error.
local function fail(code: string, instance: Instance?, message: string, details: details?): result.err<{ diagnostic }>
	return result.err({ makeError(code, instance, message, details) })
end

local function newSink(): sink
	return {
		errors = {},
		warnings = {},
		seen = {},
	}
end

local function keyOf(d: diagnostic): string
	return table.concat({ d.severity, d.code, d.path or "", d.attribute or "", d.message }, "\0")
end

-- Records a diagnostic. Identical diagnostics (for example the same broken
-- model reached through several references) are only recorded once.
local function report(target: sink, d: diagnostic)
	local key = keyOf(d)
	if target.seen[key] then
		return
	end
	target.seen[key] = true
	if d.severity == "error" then
		table.insert(target.errors, d)
	else
		table.insert(target.warnings, d)
	end
end

local function reportAll(target: sink, list: { diagnostic })
	for _, d in list do
		report(target, d)
	end
end

local function warn(target: sink, code: string, instance: Instance?, message: string, details: details?)
	report(target, makeWarning(code, instance, message, details))
end

-- Reports the errors of a failed outcome and returns its value, or nil.
local function absorb<T>(target: sink, o: outcome<T>): T?
	if o.ok then
		return o.val
	end
	reportAll(target, o.err)
	return nil
end

-- Renders a diagnostic as a single human readable line.
local function format(d: diagnostic): string
	local parts = { string.format("[%s %s]", d.severity, d.code) }
	if d.path then
		table.insert(parts, d.path)
	end
	if d.attribute then
		table.insert(parts, string.format("(%s)", d.attribute))
	end
	table.insert(parts, "- " .. d.message)
	if d.hint then
		table.insert(parts, "Hint: " .. d.hint)
	end
	return table.concat(parts, " ")
end

return table.freeze({
	codes = table.freeze({
		errors = errors,
		warnings = warnings,
	}),
	pathOf = pathOf,
	makeError = makeError,
	makeWarning = makeWarning,
	fail = fail,
	newSink = newSink,
	report = report,
	reportAll = reportAll,
	warn = warn,
	absorb = absorb,
	format = format,
})
