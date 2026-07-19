# LoopWarp

Loopwarp is a Timestretching playground for the Monome Norns

Load in a sample and then experiment with different timestretch algorithms. Try changing the tempo and the pitch. 

Each algorithm has different parameters associated with it that can make some pretty interesting effects. 

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