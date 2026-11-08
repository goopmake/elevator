--!strict

export type err<e> = { ok: false, err: e }
export type ok<v> = { ok: true, val: v }
export type result<v, e> = ok<v> | err<e>

local function ok<v>(val: v): ok<v>
	return {
		ok = true,
		val = val,
	}
end

local function err<e>(err: e): err<e>
	return {
		ok = false,
		err = err,
	}
end

return {
	ok = ok,
	err = err,
}