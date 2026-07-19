# Changelog

## LoopWarp v2 foundation

- Replaced the prototype all-modes-running SynthDef with one shared transport synth and one active mode synth.
- Renamed modes with accurate terminology while preserving legacy engine command aliases.
- Added immediate crossfaded mode switching.
- Added quarter-note Lua clock observations and bounded soft correction in the engine.
- Derived source BPM from loaded sample duration and declared sample steps.
- Added step/bar timing parameters, source sample BPM, and 0-128 sample start/end points.
- Tightened parameter increments for steps, start/end, pitch, timing, grain, and mode controls.
- Made tape playback independent of internal BPM and smoothed pitch/start/end modulation.
- Added chopped step slicing, chopped loop mode, and pitch-aware chopped playback.
- Updated the performance UI with shift-only metadata and a horizontal playhead.
- Added status payloads for phase, frames, RMS, tempo, correction, switches, realignments, stale observations, and load generation.
- Updated the test script for sample browsing, play/stop, norns BPM control, shifted mode switching, sample steps, and mode-specific controls.
