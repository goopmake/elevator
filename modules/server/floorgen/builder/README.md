# Floor builder

Executes floors produced by the compiler (`modules/server/floorgen/compiler`).

```lua
local compiler = require(ServerStorage.modules.floorgen.compiler)
local builder = require(ServerStorage.modules.floorgen.builder)

local compiled = compiler.compile(workspace.Floors["asm Office"])
assert(compiled.ok)

local planned = builder.plan(compiled.val, { seed = 1234 })
if not planned.ok then
	warn(planned.err.code, planned.err.message)
	return
end
local floor = builder.commit(planned.val, workspace)
```

## Two phases

* **`plan(floor, options)`** decides every placement and spawns nothing.
  Overlaps, `fb_max_count` limits, recursion limits and taken doorways are
  ordinary outcomes handled inside the floor (the compiler proved the root can
  never fail). `plan` only returns an error for invalid input or when it
  detects that a compiler guarantee was broken (`COMPILER_DEFECT`); it never
  returns a half-planned floor.
* **`commit(plan, parent?, name?)`** spawns fresh copies of every planned model
  into a new `Model` and cannot fail. A plan can be committed many times.

`generate(floor, options, parent?)` does both.

## Options

| Option              | Default        | Meaning |
| ------------------- | -------------- | ------- |
| `seed`              | required       | any finite number; equal seeds give equal floors |
| `maxRecursionDepth` | 8              | nested recursive references allowed |
| `origin`            | identity       | CFrame of the root's pivot |
| `yieldBudget`       | none           | yield (`task.wait`) after this many seconds of work, for big floors |
| `trace`             | false          | record pick selections and failures in `plan.trace` |
| `planningParent`    | ServerStorage  | where the temporary planning WorldModel lives |
| `collision`         | WorldModel     | custom collision world factory (see `types.luau`) |

## How planning works

* Collision: overlap volumes are private copies of each model's `overlap`
  part, placed in a temporary `WorldModel` and tested with `GetPartsInPart`
  (full geometry; rotation and unions respected). Nothing touches Workspace.
  Make overlap parts slightly smaller than room shells so rooms sharing a wall
  can sit flush.
* Rollback: emissions, accepted volumes, used doorways and counter increments
  are append-only logs; a failed attempt truncates all of them together.
* Randomness: each node draws from its own stream (`compiler.stream`), so
  editing one part of a floor doesn't re-roll the rest.
* `plan.stats` counts executions and handled failures by reason.
