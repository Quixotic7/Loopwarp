# Elasticat Architecture

Elasticat is now large enough that feature work should happen through small modules, not by adding more conditionals to `elasticat.lua`.
This document describes the current module boundaries and the rules for future changes.

For the 8-track instrument design (filters, sends, mod matrix, scenes, neighbor routing, projects) and its phased rollout, see `docs/MULTITRACK_ARCHITECTURE.md`. This document only covers code organization.

## References

- `groovecats` keeps domain behavior in object-like modules such as `GrooveCat`, with the top-level script coordinating pages, grid state, and engine calls.
- `gridstep` shows a page-oriented style: top-level state selects a page, and each page or grid mode owns its rendering and interaction rules.
- Elasticat combines those patterns: machine, warp, page, and value-model behavior live in focused modules, while the top-level script only coordinates transport, page dispatch, and norns callbacks.

## Current Boundaries

- `elasticat.lua`
  - norns script entry point.
  - Owns short-lived session state (`playing`, `alt`, `browsing`, step-lock editing bases, message/flash state) and the norns callbacks: `init`, `key`, `enc`, `redraw`, `cleanup`.
  - Wires `GridSequencer`, `Navigation`, `ParamValues`, and `SourcePage` together via dependency injection, the same way it always has for `GridSequencer`.
  - `page_items_for` and the `source_*_items` resolvers stay here: they need `MachineRegistry`/`WarpRegistry`/`params` together, which is genuine coordinator wiring, not page-navigation or value-model logic.
  - Should stay a coordinator, not a feature dumping ground.
- `lib/elasticat.lua`
  - Lua facade for `Engine_Elasticat`.
  - Owns norns params, sample pool metadata, trim sidecars, and throttled engine sends.
- `lib/grid_sequencer.lua`
  - Grid controller and sequencer runtime.
  - Owns grid key handling, step advancement, loop/slice trigger dispatch.
- `lib/wav_reader.lua`
  - Pure WAV file parsing and waveform bucket extraction.
  - No script state; takes a path, returns data or nil.
- `lib/script_state.lua`
  - `dust/data` persistence: browser folder and sample-pool-snapshot save/load.
  - Built as a `.new()` instance (like `GridSequencer`); includes `lib/elasticat` directly for pool state access.
- `lib/pages/model.lua`
  - The `page_model` table: declarative category/page/item definitions for MASTER, PATTERN, TRIG, SOURCE, FILTER, AMP, FX, MOD.
  - Pure data, no functions beyond the shared `item()` descriptor helper.
- `lib/pages/navigation.lua`
  - Category/page/K2-K3-pair/settings selection state machine, built as a `.new()` instance.
  - Owns the selection *indices*; does not resolve what items a page shows (that needs `MachineRegistry`/`WarpRegistry`/`params`, so it's a `page_items_for` callback injected from `elasticat.lua`).
- `lib/ui/param_values.lua`
  - The parameter-item value runtime: raw value, display formatting, snap/delta adjustment, apply-to-params, step-lock apply/read.
  - Built via constructor injection (`get_grid_ui`, `get_alt`, step-lock tables, etc.), the same idiom `GridSequencer.new()` already used for its callbacks.
  - `format_item_value` is an id → formatter lookup table for the common numeric-display case; only params needing bespoke display logic (enum remapping, pseudo-items) get an explicit branch.
- `lib/ui/source_page.lua`
  - Source-category rendering: the pitch ruler, sample-slot tab, waveform box + start/end/playhead markers, and the main/sample-edit cell renderers.
  - Pure rendering, like `param_renderer.lua`: receives `param_values` and `nav` as objects and coordinator-only helpers (`draw_page_header`, `active_waveform`, `active_region`, `display_phase`, `visual_param_value`) as callbacks, so it never touches engine/param state directly.
- `lib/Engine_Elasticat.sc`
  - SuperCollider engine implementation.
  - Owns buffer loading, continuous machines, slice voices, and warp DSP.

## Already Well-Factored (unchanged by this pass)

- `lib/ui/header.lua`, `lib/ui/param_renderer.lua`, `lib/ui/param_item.lua`, `lib/ui/param_bank.lua`
  - Shared header, parameter item descriptors, banks, and rendering helpers.
  - No engine calls and no sequencer mutation.
- `lib/machines/*`
  - One module per machine.
  - Owns source-page item layout, machine-specific page overrides, and machine-specific lifecycle hooks.
- `lib/warp_modes/*`
  - One module per warp mode.
  - Owns warp parameter layout and warp-specific behavior.
- `lib/sequencer/*`
  - Step data objects and sequencer model helpers.
  - Grid controller asks step objects about content instead of inspecting raw tables everywhere.

## Modularity Rules

1. Do not add new machine-specific `if machine == ...` branches to `elasticat.lua`.
   Add or update a module in `lib/machines/` instead.
2. Do not add new warp-mode-specific branches to `elasticat.lua`.
   Add or update a module in `lib/warp_modes/` instead.
3. Screen parameter cells should be rendered through `lib/ui/param_renderer.lua` (generic pages) or `lib/ui/source_page.lua` (Source-category pages).
   Do not copy text-fit or selected-corner logic into feature code.
4. Page headers must be rendered through `lib/ui/header.lua`, via `elasticat.lua`'s single `draw_page_header` wrapper.
   Do not add page-specific header implementations; pass page title, message, tempo, meter, and page number into the shared header.
5. Parameter layouts should be lists of item descriptors from `lib/ui/param_item.lua`, defined in `lib/pages/model.lua`.
   Use `blank()` for intentional empty cells so the 4x2 layout remains explicit.
6. Step records should be created through `lib/sequencer/step.lua`.
   This keeps trig, slice, pitch, length, velocity, and param-lock behavior coherent.
7. New parameter-formatting rules go in `lib/ui/param_values.lua`'s `ID_FORMATTERS` table (or an explicit branch in `format_item_value` if the param needs bespoke logic), not inline in `elasticat.lua`.
8. New category/page selection behavior goes in `lib/pages/navigation.lua`, not as new loose file-locals in `elasticat.lua`.
9. `elasticat.lua` should be allowed to coordinate state, but feature logic belongs to modules.
10. Every refactor or feature change must pass:
    - `bin/test-elasticat-lua`
    - `bin/test-elasticat-sclang`
    - `git diff --check`

## Extension Flow

To add a machine:

1. Create `lib/machines/<machine>.lua`.
2. Return a table with `id`, `name`, `is_slice`, `source_items()`, and optional page override functions.
3. Register it in `lib/machines/registry.lua`.
4. Add the engine-facing parameter and command behavior in `lib/elasticat.lua` or `Engine_Elasticat.sc` only if required.

To add a warp mode:

1. Create `lib/warp_modes/<mode>.lua`.
2. Return a table with `id`, `name`, and `source_items()`.
3. Register it in `lib/warp_modes/registry.lua`.
4. Keep DSP implementation in SuperCollider and parameter definitions in `lib/elasticat.lua`.

To add a parameter page:

1. Define item descriptors in `lib/pages/model.lua` (or the owning machine/warp module for Source sub-pages).
2. Render them through the existing page renderer (`param_renderer.lua` or `source_page.lua`).
3. Avoid direct screen drawing unless the page is a custom visual page, such as waveform editing.

To add a new parameter's display formatting:

1. If it's a simple numeric display, add one entry to `ID_FORMATTERS` in `lib/ui/param_values.lua`, reusing an existing `fmt_*` helper if one already matches the shape you need.
2. If it needs bespoke logic (enum remapping, a pseudo-item), add an explicit branch in `format_item_value` before the table lookup.
