# LoopWarp Test

LoopWarp v2 foundation test script for norns.

Load with:

```lua
norns.script.load("code/loopwarp_test/loopwarp_test.lua")
```

Controls:

- `K2`: open audio file browser
- `K3`: start/stop playback
- `E1`: norns clock BPM
- `E2` / `E3`: mode-specific controls
- `K1+E1`: pitch
- `K1+E2`: declared sample length in steps
- `K1+E3`: source sample BPM
- `K1+K2`: previous mode
- `K1+K3`: next mode

Mode-specific `E2` / `E3` controls:

- `tape`: sample start / sample end
- `tempo_varispeed`: sample start / sample end
- `chopped`: chop steps / chop loop mode
- `granular`: grain size / grain density
- `random_ola`: OLA window / OLA wander
- `pitch_corrected`: PC window / PC dispersion

Timing parameters:

- `sample bpm`: source tempo used when inferring steps on sample load.
- `sample steps`: full sample length, where 16 steps is one bar.
- `sample start`: selected playback start, 0-128 across the full sample, normal step 1.0.
- `sample end`: selected playback end, 0-128 across the full sample, normal step 1.0.
- `chop steps`: slice size in steps, where 1 step chops one bar into 16 parts.

Loading a sample can auto-populate `sample bpm` from filenames such as `break_bpm136.wav`, then infer `sample steps` from duration. `sample start` and `sample end` are not changed when a new sample loads.

Current modes:

- `tape`
- `tempo_varispeed`
- `chopped`
- `granular`
- `random_ola`
- `pitch_corrected`

This milestone implements the shared transport, active-mode lifecycle, phase-aware switching, clock observations, step-based sample timing, selected sample regions, and status instrumentation. It does not yet implement guarded loop-region buffers, deterministic `ola`, true WSOLA, or true phase-vocoder modes.
