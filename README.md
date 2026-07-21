# Elasticat

Elasticat is a sample-loop and slice playback playground for the Monome Norns.

Load samples into a 128-slot pool, choose a Machine, and sequence loop resets, loop regions, slices, sample slots, pitch, velocity, and note length from the grid.

Load with:

```lua
norns.script.load("code/elasticat/elasticat.lua")
```

Controls:

- `E1`: cycle parameter pages across MASTER, PATTERN, TRIG, SOURCE, FILTER, AMP, FX, and MOD.
- `E2` / `E3`: edit the active pair of parameters on the current page.
- `K2` / `K3`: previous/next parameter pair.
- `K1+E1 clockwise`: open the current category settings page.
- `K1+E1 counter-clockwise`: leave settings.
- `K1+E2` / `K1+E3`: snap the active parameter to useful values.
- Hold a step and turn `E2` / `E3`: parameter-lock the active parameter for that step.
- Hold a step and press `K2` / `K3`: clear the corresponding parameter lock on that step.
- Hold `K1` and press `K2` / `K3`: clear all locks for the corresponding parameter across the pattern.

Parameter pages:

- MASTER: BPM and volume.
- PATTERN: pattern length and playback scale.
- TRIG: note/pitch, default trig length, and default velocity.
- SOURCE: sample pool/source controls with waveform display, current-warp controls, and machine-specific playback controls.
- AMP: volume and slice envelope controls.
- FILTER, FX, and MOD are present as empty pages for future features.

Grid:

- Row 1: function, record, play, stop.
- Row 1 columns 7, 8, 11, 12, 13, 14, 15, 16: MASTER, PATTERN, TRIG, SOURCE, FILTER, AMP, FX, MOD shortcuts. Press a category repeatedly to cycle pages in that category. Hold FN and press a category to open its settings; from settings, FN plus a category returns to that main page.
- Row 2: loop controls in loop machines; slices 1-16 in slice machines.
- Row 3: slices 17-32 in slice machines.
- Row 5 columns 1-2: keyboard octave down/up.
- Row 6/7 columns 1-8: one-octave mini keyboard. Pressing a key sets pitch; holding a step and pressing a key locks pitch to that step.
- Row 6/7 arrow keys: cycle root pages, or navigate/change settings when a settings page is active.
- Row 7 column 11: NO, exits settings.
- Row 8: 16 step keys for the selected page. Quick press toggles a trig. Hold a step and adjust page parameters to lock them.
- `Page` on row 7 column 16 plus row 8 selects pages, page loop view, or rate view as before.

Timing parameters:

- `pattern steps`: sequencer length, 1-256 steps. Default is 16.
- `default trig length`: default note length for steps without a length lock.
- `default velocity`: default velocity for steps without a velocity lock.
- `sample slot`: active sample pool slot, 1-128. This can be parameter-locked per step.
- `sample bpm`: source tempo for the active slot, used when inferring steps on sample load.
- `sample steps`: full sample length for the active slot, where 16 steps is one bar.
- `sample start`: selected playback start, 0-128 across the full sample, normal step 1.0.
- `sample end`: selected playback end, 0-128 across the full sample, normal step 1.0.
- `slice count`: number of GridSlice/RazorSlice slices, 1-32.
- `slice clock sync`: when on, slice triggers fit their note length; when off, slices use `slice rate`.
- `slice rate`: independent slice playback rate used when slice clock sync is off.

Loading a sample writes it into the active `sample slot`. Filenames such as `break_bpm136.wav` auto-populate `sample bpm`, then `sample steps` is inferred from duration. `sample start` and `sample end` are not changed when a new sample loads.

Source page 1 shows the active pool slot and sample waveform. It overlays the playhead plus start/end markers; the start marker points right and the end marker points left. The eight compact parameter cells show abbreviated labels, then briefly show values while their encoder is moved.

The parameter menu is grouped into setup, loop playback, engine algorithms, slice machines, RazorSlice slice points, and system controls.

Machines:

- `loop`

Plays the selected sample region continuously when transport starts. Sequencer trigs restart playback. A one-key loop lock on a step restarts from that key's start position; a two-or-more-key lock sets both start and end.

- `loop_trig`

Only plays audio during triggered steps. Step loop locks set the region that is triggered for that step.

- `grid_slice`

Divides the selected sample region into `slice count` equal slices. Row 2 plays slices 1-16 and row 3 plays slices 17-32. Steps can sequence multiple slices unless slice polyphony is set to mono.

- `razor_slice`

Uses the same slice trigger engine as GridSlice, but each slice has precise `razor XX start` / `razor XX end` params. Moving a slice start also moves its end by the same amount to preserve slice length.

Lower-level engine modes:

- `tape`
  
Plays through the selected sample region at the sample’s native rate, like a tape deck. Internal BPM should not affect it. Pitch changes are varispeed: higher pitch means faster playback, lower pitch means slower playback. This mode is closest to BufRd over a moving sample position.

- `tempo_varispeed`
  
Forces the selected sample region to fit the current step length and internal BPM. The playhead is tempo-driven, so the sample reaches the region end exactly when the loop cycle ends. Pitch is intentionally neutral here because playback speed is determined by time fitting.

- `chopped`

Divides the loop into rhythmic slices using chop steps. At 1 step, a bar is split into 16 slices; 2 steps gives 8 slices; 0.5 gives 32 slices. It gates playback with an envelope and can read each active slice in different ways:
forward stop: play the slice, then stop under the envelope
loop forward: keep moving forward through the sample
ping pong: bounce back and forth inside the slice

- `granular`
  
Reads the sample with small overlapping grains. The playhead still follows the selected region and clock, but the audio is reconstructed from short windows. grain size controls grain duration, grain density controls grains per step, grain jitter adds positional smear. Pitch can shift grains without simply changing loop duration.

- `random_ola`

A randomized overlap-add style mode. It is similar in spirit to granular, but instead of a smooth grain cloud it places overlapping chunks around the moving playhead with some wander/randomness. This gives a looser, shuffled stretch texture. Pitch changes grain playback rate.

- `pitch_corrected`

Reads the selected region on the tempo-synced playhead, then runs a pitch-shift process over that audio. The goal is “fit the timing, then correct/shift pitch,” but SuperCollider’s PitchShift has a distinct robotic/formant texture, especially when pitch or window size changes. PC window changes the pitch-shift analysis window; PC dispersion adds time/pitch smear.
