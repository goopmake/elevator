--!strict
--[[
	Warning codes. Warnings never make compilation fail.
]]

return table.freeze({
	-- A Model whose name looks like a language node is still a model declaration.
	MODEL_NAMED_LIKE_NODE = "MODEL_NAMED_LIKE_NODE",
	-- A Model contains Instances named like language nodes; they are not interpreted.
	MODEL_CONTAINS_NODES = "MODEL_CONTAINS_NODES",
	-- A model has an overlap part but is never used as a conditional model.
	MODEL_OVERLAP_UNUSED = "MODEL_OVERLAP_UNUSED",
	-- A pick selects nothing.
	PICK_AMOUNT_ZERO = "PICK_AMOUNT_ZERO",
	-- fb_pick_weight on an assembly that is not a pick candidate at this use.
	PICK_WEIGHT_UNUSED = "PICK_WEIGHT_UNUSED",
	-- A tag that was removed from the language.
	TAG_REMOVED = "TAG_REMOVED",
	-- A key that cannot have any effect where it is used.
	KEY_NO_EFFECT = "KEY_NO_EFFECT",
	-- An each node or plug matches no connection of its room.
	FILTER_MATCHES_NOTHING = "FILTER_MATCHES_NOTHING",
	-- A reference override set drops language keys that the target defines.
	OVERRIDE_REMOVES_KEYS = "OVERRIDE_REMOVES_KEYS",
	-- Authored placement cannot be derived; the child is placed at the pivot.
	PLACEMENT_UNAVAILABLE = "PLACEMENT_UNAVAILABLE",
	-- A referenced model or room has no fb_attach and is placed at the pivot.
	PLACEMENT_AT_PIVOT = "PLACEMENT_AT_PIVOT",
})
