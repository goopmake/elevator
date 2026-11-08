# Floor builder compiler

Compiles a developer-authored Instance hierarchy into an immutable, reusable
execution graph for the runtime floor builder.

```lua
local compiler = require(ServerStorage.modules.floorgen.compiler)

local compiled = compiler.compile(workspace.Floors["asm Office"])
if not compiled.ok then
	for _, d in compiled.err.errors do
		warn(compiler.formatDiagnostic(d))
	end
	return
end
local floor = compiled.val
```

`compile` returns the shared Result (`modules/shared/result.luau`). On
failure `err` holds every error and warning; no compiled floor is returned.
The execution contract the builder must follow is in `types.luau`.

## Language reference

| Source                          | Meaning                     |
| ------------------------------- | --------------------------- |
| `Configuration` `asm <label>`   | assembly (all-or-nothing)   |
| `Configuration` `try <label>`   | ordered alternatives        |
| `Configuration` `pick <label>`  | random selection of assemblies/models |
| `Configuration` `each <label>`  | its single child, once per free room connection |
| `ObjectValue` `ref <label>`     | reference (Value = target)  |
| `Model`                         | model declaration           |
| `Folder`                        | ignored, with all descendants |

Children are processed in authored (`GetChildren`) order.

### Behaviour keys (what a node is)

| Key                          | On          | Meaning |
| ---------------------------- | ----------- | ------- |
| tag `fb_conditional_model`   | model       | collision-checked; may fail |
| `fb_max_count`               | model, asm  | emitted at most N times per floor (all uses together) |
| `fb_pick_amount` (required)     | pick        | natural number, or `NumberRange` for a random amount |
| `fb_pick_unique` (default false)| pick        | no repeated selection |
| `fb_pick_mode` (default strict) | pick        | `"strict"`: a failing selection fails the pick; `"fit"`: keep drawing until enough succeed |

### Use-site keys (how a node is used here)

| Key                | On                 | Meaning |
| ------------------ | ------------------ | ------- |
| tag `fb_optional`  | any                | a failure here is handled here (like a one-alternative try) |
| tag `fb_room`      | model, direct child of asm | the assembly's room / pivot |
| tag `fb_plug`      | model, direct child of asm with room | placed on every room connection still unused when the assembly finishes |
| `fb_pick_weight`      | pick candidate     | natural number, default 1, 0 = never |
| `fb_attach`        | model, asm         | room connection to place on (uses it up) |
| `fb_anchor`        | model, asm         | own connection mated to the parent connection |
| `fb_filter`        | each, plug         | connection name prefix to act on |
| `fb_max_depth`     | recursive reference| per-reference recursion limit |
| tag `fb_connection`| Attachment in a model | named connection point |

Attributes and tags starting with `fb_` belong
to the language: unknown ones are errors (typos). Anything else is developer
data and is ignored.

### References

A reference's use-site keys are layered over its target's, key by key, so
`ref Hall` with only `fb_attach = "East"` keeps everything else about the hall.
Setting any behaviour key (or the tag `fb_override`) replaces the target's
behaviour keys completely; a warning lists any that get dropped. Effective
configurations are validated like inline ones. Targets can be anywhere,
including inside Folders; references to references are rejected. Cycles are
allowed: reference edges on a cycle are marked `recursive`.

### Spatial composition

* An assembly's pivot is its room's PrimaryPart.
* `fb_attach` places a child on a connection of the nearest enclosing
  assembly's room and uses that connection up. With `fb_anchor` the two
  connections are mated (same position, opposite facing; author connection
  LookVectors pointing out of the room), and the anchor connection of an
  arriving assembly is used up in that assembly.
* `each` places its child on every matching connection that is still free.
* Otherwise a child declared inline keeps its authored position relative to
  the enclosing room, so Studio previews match generation.
* Otherwise (a reference without `fb_attach`) the child sits at the pivot.

### Failures

Runtime failures come from conditional-model overlaps, `fb_max_count`
limits, recursion limits, and connections that another use may already have
taken (the compiler works out which uses can actually collide). They pass
through assemblies (which discard everything they planned), picks and each
nodes, and stop at `try` nodes and `fb_optional` edges. The compiler proves
the root can never fail and reports every escaping failure source with its
path.

### Random streams

Every node draws from its own random stream derived from the seed and its
position (`compiler.stream`), so editing one part of a floor does not re-roll
the rest. Renaming or moving a node re-rolls only that subtree.

## Design decisions

* **Plain models never fail.** Only conditional models are collision-checked.
* **Only recursive references consume recursion depth.**
* **Use-site tags cannot be removed by a reference** (they are layered, not
  replaced). Wrap the target instead.
* **Connection-using try/pick/each nodes cannot be referenced**, because the
  connections they use belong to the room they were written in.

## Tests

Specs live in `tests/` and use the TestEZ API. Headless runner:

```
rokit install
lune run scripts/run_tests [filter]
```

Semantic tests run compiled floors through the real builder
(`tests/planning.luau`) with a test-only box collision world, and the builder
raises an error whenever it observes a broken compiler guarantee.
