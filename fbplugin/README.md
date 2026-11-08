# Floor Builder Studio plugin

Live tooling for floor programs: an annotated tree, live diagnostics,
previews generated with the project's own builder, in-world visualisations
and authoring helpers.

## Install

```
rojo build fbplugin --plugin FloorBuilder.rbxmx
```

Run it from the project root. It writes the plugin into your local Studio
plugins folder (`%LOCALAPPDATA%\Roblox\Plugins` on Windows), not the project. Restart Studio
or reopen the place, then click **Floor Builder** in the Plugins tab.

The plugin does not contain the compiler or builder. It loads them from the
open place (default `ServerStorage / modules / floorgen`, where this project's Rojo setup
puts them), so it always uses the same engine version as the game. When the
engine's source changes (for example through Rojo sync) it reloads by itself.
The engine location can be changed in the View section.

## Using it

**Opening a root** works like opening a folder in VS Code: press **Open…**
for recent roots and every top-level assembly in the place, or select an
`asm` Configuration (or a reference to one) in the Explorer and press **Use
selection**. The open root is remembered per place.

**Tree.** One row per node:

```
- [asm] Lobby  {pick_weight=2}   1 warning   may fail · handled
```

* label colour: red = errors on this node, orange = warnings
* `+`/`-` expands; a red `!` on a collapsed node means errors inside it
* badges: `may fail` (failure goes up to the nearest try/optional),
  `may fail · handled` (fb_optional here), `contested` (its doorway may already
  be taken), `recursive`, `unused` (not reached by the compiled floor)
* click selects the Instance (Explorer and Properties follow); selecting in the
  Explorer reveals the node in the tree; double click on a reference selects
  its target

**Details** explains the selected node: kind, path, keys, whether and how it
can fail, and every diagnostic with its hint. **Problems** lists all
diagnostics; click one to jump to it.

**Live recompile** reacts to structure, property, attribute and tag changes in
the root and everything it references (debounced).

**Edit** acts on the Explorer selection, each as one undo step:
add asm/try/pick/each, wrap in try (keeps child order), toggle
optional/conditional/room/plug/override, copy a reference target and paste a
reference, add a connection Attachment to a part, add an overlap volume to a
model (bounding box inset by 0.1 studs).

**Preview** plans and spawns the floor with the project's builder:
seed (with -1 / +1 / random), recursion depth, and offset. The preview is
not saved with the place, its parts can be locked so clicks select the
source, and the source can be ghosted (made see-through) while it is shown.
**Live preview** regenerates after every successful recompile. Statistics show
models, node runs, timings and handled failures by reason.

**View** toggles in-world visualisations (drawn as CoreGui adornments, never
saved or put in undo history):

* connections: green cone pointing out of the room along each connection,
  with its name
* overlaps: red translucent box on every overlap volume
* problems: red/orange outline around models with errors/warnings
* failures: pink marker and reason where the last preview had a handled
  failure (why something is missing)
* the selected node's models are outlined in blue

## Notes

* Planning runs in a temporary WorldModel in CoreGui. The plugin first checks
  that collision queries work there (falling back to ServerStorage) and
  refuses to preview rather than show a preview without collision.
* Logic that does not need Studio (formatting, settings, root paths) is
  covered by `fbplugin/src/tests`, run headlessly with `lune run scripts/run_tests`.
  The UI itself can only be checked in Studio.
