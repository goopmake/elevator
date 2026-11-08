--!strict
--[[
	Weighted candidate selection for pick nodes (see the execution contract).

	A pick draws from its own generator, Random.new(stream seed). The amount is
	drawn first (only when amountMin < amountMax), then candidates are drawn
	one at a time: r = NextInteger(1, total eligible weight), walking eligible
	candidates in authored order and subtracting weights until r <= 0.
]]

local compiler = require(script.Parent.Parent.compiler)

export type draw = {
	amount: () -> number,
	-- Index of the next drawn candidate, or nil if none is eligible.
	next: () -> number?,
	exclude: (index: number) -> (),
}

local function new(pick: compiler.pick_node, seed: number): draw
	local rng = Random.new(seed)
	local eligible: { boolean } = table.create(#pick.candidates, true)
	for i, candidate in pick.candidates do
		if candidate.weight == 0 then
			eligible[i] = false
		end
	end

	local function amount(): number
		if pick.amountMax > pick.amountMin then
			return rng:NextInteger(pick.amountMin, pick.amountMax)
		end
		return pick.amountMin
	end

	local function nextIndex(): number?
		local total = 0
		for i, candidate in pick.candidates do
			if eligible[i] then
				total += candidate.weight
			end
		end
		if total == 0 then
			return nil
		end
		local r = rng:NextInteger(1, total)
		for i, candidate in pick.candidates do
			if eligible[i] then
				r -= candidate.weight
				if r <= 0 then
					return i
				end
			end
		end
		return nil
	end

	local function exclude(index: number)
		eligible[index] = false
	end

	return {
		amount = amount,
		next = nextIndex,
		exclude = exclude,
	}
end

return table.freeze({
	new = new,
})
