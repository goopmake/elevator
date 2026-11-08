--!strict
--[[
	Stable random streams.

	Every node execution draws its random numbers from its own stream. The
	stream seed of a child is derived from its parent's stream seed and the
	stable key of the edge that leads to it, never from how many numbers were
	drawn elsewhere. Editing one part of a floor therefore does not re-roll
	unrelated parts.

		rootSeed(seed)                         -- seed of the root node
		childSeed(parentSeed, edge.key, ordinal)

	`ordinal` distinguishes repeated executions of the same edge from the same
	parent: the 1-based selection index of a strict pick, the 1-based attempt
	index of a fit pick, 0 otherwise.

	Edge keys are computed by the compiler from the child's name (see
	compilation/construct). All arithmetic is exact unsigned 32-bit.
]]

local TWO_32 = 4294967296

-- (a * b) mod 2^32 without losing precision in doubles.
local function mul32(a: number, b: number): number
	local aLow = bit32.band(a, 0xFFFF)
	local aHigh = bit32.rshift(a, 16)
	local bLow = bit32.band(b, 0xFFFF)
	local bHigh = bit32.rshift(b, 16)
	local cross = bit32.band(aHigh * bLow + aLow * bHigh, 0xFFFF)
	return (aLow * bLow + cross * 65536) % TWO_32
end

-- Reduces any finite number to an unsigned 32-bit integer.
local function u32(value: number): number
	return math.floor(value) % TWO_32
end

-- FNV-1a over the bytes of a string.
local function hashString(text: string): number
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = mul32(h, 16777619)
	end
	return h
end

-- Combines two 32-bit values into a well-distributed 32-bit value.
local function mix(a: number, b: number): number
	local h = bit32.bxor(u32(a), mul32(u32(b), 0x9E3779B1))
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

local function rootSeed(seed: number): number
	return mix(u32(seed), 0)
end

local function childSeed(parentSeed: number, key: number, ordinal: number): number
	return mix(mix(parentSeed, key), ordinal)
end

return table.freeze({
	hashString = hashString,
	mix = mix,
	rootSeed = rootSeed,
	childSeed = childSeed,
})
