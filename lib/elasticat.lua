-- elasticat
--
-- Parameter helper for the bundled Engine_Elasticat.
--
-- Minimal script usage:
--   engine.name = "Elasticat"
--   local elasticat = include("lib/elasticat")
--   function init()
--     elasticat.params()
--   end

local cs = require "controlspec"
local unpack = table.unpack or unpack

local elasticat = {}

elasticat.machines = {
  "loop",
  "loop_trig",
  "grid_slice",
  "razor_slice"
}

elasticat.modes = {
  "tape",
  "tempo_varispeed",
  "chopped",
  "granular",
  "random_ola",
  "pitch_corrected"
}

local sync_thread = nil
local engine_send_metro = nil
local engine_send_interval = 1 / 12
local pending_engine_sends = {}
local pending_engine_order = {}
local clock_origin = 0
local clock_sequence = 0
local ids = {}
local sample_pool = {
  paths = {},
  samples = {},
  rates = {},
  channels = {},
  bpms = {},
  steps = {},
  trim_starts = {},
  trim_ends = {},
  gains = {}
}
local active_sample_slot = 1
-- The File page edits this slot independently of the track's playback slot
-- (active_sample_slot). The sample metadata params (bpm/steps/trim/gain/file)
-- reflect file_edit_slot; playback reads the active slot's pool metadata
-- directly. Editing only touches the engine when the two slots coincide.
local file_edit_slot = 1
local pool_options = {}

local function file_edits_active()
  return file_edit_slot == active_sample_slot
end
local pool_dirty = {}
local suppress_pool_callback = false
local engine_call = nil
local send_effective_amp
local razor_adjusting = false
local razor_start_values = {}
local audio_extensions = {
  wav = true,
  aif = true,
  aiff = true,
  flac = true,
  ogg = true
}

local function param_id(prefix, suffix)
  return prefix .. suffix
end

local function add_control(id, name, spec, action, formatter)
  params:add_control(id, name, spec, formatter)
  params:set_action(id, action)
end

local function is_audio_file(path)
  local ext = path:match("%.([^%.]+)$")
  return ext ~= nil and audio_extensions[ext:lower()] == true
end

local function bpm_from_filename(path)
  local bpm = path:match("[Bb][Pp][Mm][_%-%s]*(%d+%.?%d*)")
    or path:match("(%d+%.?%d*)[_%-%s]*[Bb][Pp][Mm]")
  if bpm == nil then
    return nil
  end
  return tonumber(bpm)
end

local function quantize_steps(value)
  return math.max(1, math.floor(value + 0.5))
end

local function sample_slot_number(slot)
  return util.clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, 128)
end

local function sample_duration(slot)
  slot = sample_slot_number(slot)
  local samples = sample_pool.samples[slot] or 0
  local rate = sample_pool.rates[slot] or 0
  if samples <= 0 or rate <= 0 then
    return 0
  end
  return samples / rate
end

local function sample_meta_path(path)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return nil
  end
  local replaced = path:gsub("%.[^%.\\/]+$", ".json")
  if replaced == path then
    return path .. ".json"
  end
  return replaced
end

local function read_sample_sidecar(path)
  local meta_path = sample_meta_path(path)
  if meta_path == nil or not util.file_exists(meta_path) then
    return {}
  end

  local file = io.open(meta_path, "rb")
  if file == nil then
    return {}
  end
  local content = file:read("*all") or ""
  file:close()

  return {
    bpm = tonumber(content:match('"bpm"%s*:%s*([%d%.%-]+)')),
    steps = tonumber(content:match('"steps"%s*:%s*([%d%.%-]+)')),
    trim_start = tonumber(content:match('"trim_start"%s*:%s*([%d%.%-]+)')),
    trim_end = tonumber(content:match('"trim_end"%s*:%s*([%d%.%-]+)')),
    gain = tonumber(content:match('"gain"%s*:%s*([%d%.%-]+)'))
  }
end

local function write_sample_sidecar(slot)
  slot = sample_slot_number(slot)
  local path = sample_pool.paths[slot]
  local meta_path = sample_meta_path(path)
  if meta_path == nil then
    return
  end

  local file = io.open(meta_path, "wb")
  if file == nil then
    print("elasticat: could not write sample sidecar " .. tostring(meta_path))
    return
  end

  file:write(string.format(
    '{\n  "bpm": %.6f,\n  "steps": %.6f,\n  "trim_start": %.6f,\n  "trim_end": %.6f,\n  "gain": %.6f\n}\n',
    sample_pool.bpms[slot] or 120,
    sample_pool.steps[slot] or 16,
    sample_pool.trim_starts[slot] or 0,
    sample_pool.trim_ends[slot] or sample_duration(slot),
    sample_pool.gains[slot] or 1
  ))
  file:close()
end

local function trim_bounds(slot)
  slot = sample_slot_number(slot or active_sample_slot)
  local duration = sample_duration(slot)
  local trim_start = util.clamp(sample_pool.trim_starts[slot] or 0, 0, math.max(0, duration))
  local trim_end = util.clamp(sample_pool.trim_ends[slot] or duration, 0, math.max(0, duration))
  if duration > 0 and trim_end <= trim_start then
    trim_end = duration
    if trim_end <= trim_start then
      trim_start = 0
    end
  end
  return trim_start, trim_end, duration
end

-- Active Range override: the three-layer model the loop region also uses. Track
-- Range = the range_start/range_end params (what the Range page edits, never
-- touched by step locks). Step Range = a triggering step's range lock, pushed
-- here by GridSequencer. Actual Range (used below) = Step Range when set, else
-- Track Range. nil per endpoint means "fall through to the Track param".
local active_range_start = nil
local active_range_end = nil

function elasticat.set_active_range(range_start, range_end)
  active_range_start = range_start
  active_range_end = range_end
end

-- The Actual Range (0-128) actually driving playback: Step Range override when
-- set, else the Track Range params. Used by the waveform view so it can follow
-- a sequenced range sweep during playback.
function elasticat.active_range()
  local rs = active_range_start
  local re = active_range_end
  if rs == nil and ids.range_start ~= nil and params:lookup_param(ids.range_start) ~= nil then
    rs = params:get(ids.range_start)
  end
  if re == nil and ids.range_end ~= nil and params:lookup_param(ids.range_end) ~= nil then
    re = params:get(ids.range_end)
  end
  return rs or 0, re or 128
end

-- Range Start/End (0-128) carve a live performance window *inside* the file
-- trim window: 0 = trim start, 128 = trim end. Unlike file trim (saved per
-- sample) this is a global, p-lockable layer. Returns the window in seconds.
local function range_bounds(trim_start, trim_end)
  local span = trim_end - trim_start
  local range_start = active_range_start
  local range_end = active_range_end
  if range_start == nil and ids.range_start ~= nil and params:lookup_param(ids.range_start) ~= nil then
    range_start = params:get(ids.range_start)
  end
  if range_end == nil and ids.range_end ~= nil and params:lookup_param(ids.range_end) ~= nil then
    range_end = params:get(ids.range_end)
  end
  range_start = range_start or 0
  range_end = range_end or 128
  local lo = trim_start + (span * (util.clamp(range_start, 0, 128) / 128))
  local hi = trim_start + (span * (util.clamp(range_end, 0, 128) / 128))
  if hi <= lo then
    hi = math.min(trim_end, lo + 0.0001)
  end
  return lo, hi
end

-- Maps a Track point (0-128) through Range, then File Trim, into engine 0-128
-- (of the whole sample). One funnel: every engine region call (loop points,
-- slice ranges, set_loop_region) goes through here, so both the Range and the
-- File Trim layers apply everywhere with no downstream changes.
local function map_trim_point(point, slot)
  local trim_start, trim_end, duration = trim_bounds(slot)
  if duration <= 0 then
    return util.clamp(point or 0, 0, 128)
  end
  local range_lo, range_hi = range_bounds(trim_start, trim_end)
  local fraction = util.clamp(point or 0, 0, 128) / 128
  return ((range_lo + ((range_hi - range_lo) * fraction)) / duration) * 128
end

-- Maps a Track-space region (0-128) to the engine-space region actually played
-- (range + trim folded in). The visual playhead needs this so its rate matches
-- the true loop length -- e.g. a narrowed range loops far faster than the Track
-- width alone implies.
function elasticat.map_region(track_start, track_end)
  return map_trim_point(track_start), map_trim_point(track_end)
end

local function update_engine_loop_points()
  if ids.loop_start == nil or ids.loop_end == nil then
    return
  end
  local start_point = params:lookup_param(ids.loop_start) ~= nil and params:get(ids.loop_start) or 0
  local end_point = params:lookup_param(ids.loop_end) ~= nil and params:get(ids.loop_end) or 128
  engine_call("loopStart", map_trim_point(start_point))
  engine_call("loopEnd", map_trim_point(end_point))
end

local function format_ms(param)
  return tostring(math.floor((param:get() * 1000) + 0.5)) .. " ms"
end

local function clock_param_is_internal()
  return params:lookup_param("clock_source") ~= nil and params:get("clock_source") == 1
end

local function set_internal_clock_tempo(bpm)
  if ids.clock_sync ~= nil and params:get(ids.clock_sync) ~= 1 then
    return
  end
  if not clock_param_is_internal() then
    return
  end

  if params:lookup_param("clock_tempo") ~= nil then
    params:set("clock_tempo", bpm)
  elseif clock.internal ~= nil and clock.internal.set_tempo ~= nil then
    clock.internal.set_tempo(bpm)
  end
end

local function load_sample(path)
  if engine.loadSample ~= nil then
    print("elasticat: sending engine.loadSample " .. path)
    engine.loadSample(path)
  elseif engine.commands ~= nil and engine.commands.load ~= nil then
    -- Older compiled Elasticat versions registered a command named "load".
    -- Call through the command table to avoid norns' reserved engine.load().
    print("elasticat: sending legacy engine command load " .. path)
    engine.commands.load.func(path)
  else
    print("elasticat: engine loadSample command missing; restart/recompile norns")
  end
end

engine_call = function(name, ...)
  if engine[name] ~= nil then
    engine[name](...)
  else
    print("elasticat: engine command missing: " .. name)
  end
end

local function notify_pool_change(kind, slot, path)
  if suppress_pool_callback then
    return
  end
  if pool_options.on_pool_change ~= nil then
    pool_options.on_pool_change(elasticat.pool_snapshot(), slot, path, kind)
  end
end

-- Sidecar/pool-state disk writes are deferred: edits (trim, bpm, steps, gain)
-- just mark the slot dirty and update the screen/engine live. The actual
-- write only happens on flush (sample-slot change, page navigation, or
-- script cleanup), so scrubbing an encoder never triggers disk I/O per tick.
local function mark_pool_dirty(slot)
  pool_dirty[sample_slot_number(slot)] = true
end

function elasticat.flush_dirty_pool_state()
  local flushed_slot = nil
  for slot, dirty in pairs(pool_dirty) do
    if dirty then
      write_sample_sidecar(slot)
      pool_dirty[slot] = nil
      flushed_slot = flushed_slot or slot
    end
  end
  if flushed_slot ~= nil then
    notify_pool_change("flush", active_sample_slot, sample_pool.paths[active_sample_slot])
  end
end

local function load_sample_slot(slot, path)
  slot = sample_slot_number(slot)
  if engine.loadPoolSlot ~= nil then
    print("elasticat: sending engine.loadPoolSlot " .. tostring(slot) .. " " .. path)
    engine_call("loadPoolSlot", slot, path)
  elseif slot == active_sample_slot then
    load_sample(path)
  else
    print("elasticat: engine loadPoolSlot command missing; slot " .. tostring(slot) .. " cached in script only")
  end
end

-- Push the *active* slot's pool metadata (bpm/steps/trim/gain) to the engine.
-- Called when the active/playback slot changes, or when its own metadata is
-- edited. Does not touch the display params -- those follow the file-edit slot.
local function push_engine_slot_metadata(slot)
  slot = sample_slot_number(slot)
  if sample_pool.bpms[slot] ~= nil then
    engine_call("sourceBpm", sample_pool.bpms[slot])
  end
  if sample_pool.steps[slot] ~= nil then
    engine_call("setSampleSteps", sample_pool.steps[slot])
  end
  send_effective_amp()
  update_engine_loop_points()
end

-- Load the file-edit slot's pool metadata into the display params (silently) so
-- the File page reflects that slot without disturbing playback.
local function apply_file_slot_metadata(slot)
  slot = sample_slot_number(slot)
  if sample_pool.bpms[slot] ~= nil and params:lookup_param(ids.sample_bpm) ~= nil then
    params:set(ids.sample_bpm, sample_pool.bpms[slot], true)
  end
  if sample_pool.steps[slot] ~= nil and params:lookup_param(ids.sample_steps) ~= nil then
    params:set(ids.sample_steps, sample_pool.steps[slot], true)
  end
  if sample_pool.trim_starts[slot] ~= nil and ids.trim_start ~= nil and params:lookup_param(ids.trim_start) ~= nil then
    params:set(ids.trim_start, sample_pool.trim_starts[slot], true)
  end
  if sample_pool.trim_ends[slot] ~= nil and ids.trim_end ~= nil and params:lookup_param(ids.trim_end) ~= nil then
    params:set(ids.trim_end, sample_pool.trim_ends[slot], true)
  end
  if ids.gain ~= nil and params:lookup_param(ids.gain) ~= nil then
    params:set(ids.gain, sample_pool.gains[slot] or 1, true)
  end
  if ids.sample ~= nil and params:lookup_param(ids.sample) ~= nil then
    params:set(ids.sample, sample_pool.paths[slot] or _path.audio, true)
  end
end

local function sync_sample_file_param(path)
  if ids.sample ~= nil and params:lookup_param(ids.sample) ~= nil then
    params:set(ids.sample, path or _path.audio, true)
  end
end

local function set_active_pool_slot(slot)
  -- Slot 0 = Off: a deliberate silence slot (no sample loadable). The engine
  -- plays its zeroed buffers so audio stops while the transport keeps running.
  slot = util.clamp(math.floor((tonumber(slot) or 1) + 0.5), 0, 128)
  if slot ~= active_sample_slot then
    elasticat.flush_dirty_pool_state()
  end
  active_sample_slot = slot

  -- sample_slot is the SOURCE-page (track) selector; the File page has its own
  -- file_slot. We only sync the track selector here.
  if ids.sample_slot ~= nil and params:lookup_param(ids.sample_slot) ~= nil then
    if math.floor((params:get(ids.sample_slot) or 1) + 0.5) ~= slot then
      params:set(ids.sample_slot, slot, true)
    end
  end

  if slot == 0 then
    engine_call("setSampleSlot", 0)
    if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
      pool_options.on_sample_slot(0, nil)
    end
    return
  end

  -- Push the active slot's metadata to the engine (not the display params, which
  -- follow the file-edit slot).
  push_engine_slot_metadata(slot)
  engine_call("setSampleSlot", slot)

  if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
    pool_options.on_sample_slot(slot, sample_pool.paths[slot])
  end
end

-- Select which slot the File page edits, independent of playback. Loads that
-- slot's metadata into the display params so the editor reflects it.
local function set_file_edit_slot(slot)
  slot = sample_slot_number(slot)
  if slot ~= file_edit_slot then
    elasticat.flush_dirty_pool_state()
  end
  file_edit_slot = slot
  if ids.file_slot ~= nil and params:lookup_param(ids.file_slot) ~= nil then
    if math.floor((params:get(ids.file_slot) or 1) + 0.5) ~= slot then
      params:set(ids.file_slot, slot, true)
    end
  end
  apply_file_slot_metadata(slot)
  if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
    pool_options.on_sample_slot(slot, sample_pool.paths[slot])
  end
end

local flush_engine_sends

local function ensure_engine_send_metro()
  if engine_send_metro == nil then
    engine_send_metro = metro.init(function()
      flush_engine_sends()
    end, engine_send_interval, -1)
  end
  if engine_send_metro ~= nil and not engine_send_metro.is_running then
    engine_send_metro:start()
  end
end

local function queue_engine_send(key, action)
  if pending_engine_sends[key] == nil then
    table.insert(pending_engine_order, key)
  end
  pending_engine_sends[key] = action
  ensure_engine_send_metro()
end

local function queue_engine_call(key, name, ...)
  local args = {...}
  queue_engine_send(key, function()
    engine_call(name, unpack(args))
  end)
end

-- Coalesced (12Hz) version of update_engine_loop_points -- used when re-mapping
-- the loop points from a rapidly-scrubbed control (Range) during playback, so
-- per-detent edits don't flood the engine with immediate sends and feel laggy.
local function queue_engine_loop_points()
  if ids.loop_start == nil or ids.loop_end == nil then
    return
  end
  local start_point = params:lookup_param(ids.loop_start) ~= nil and params:get(ids.loop_start) or 0
  local end_point = params:lookup_param(ids.loop_end) ~= nil and params:get(ids.loop_end) or 128
  queue_engine_call(ids.loop_start, "loopStart", map_trim_point(start_point))
  queue_engine_call(ids.loop_end, "loopEnd", map_trim_point(end_point))
end

-- The engine only has one gain input (setAmp); the per-sample "gain" param
-- is a script-side multiplier on top of the track/master amp param, so both
-- combine into that single engine send instead of needing a second engine
-- parameter.
send_effective_amp = function()
  if ids.amp == nil or params:lookup_param(ids.amp) == nil then
    return
  end
  local base = params:get(ids.amp)
  local gain = sample_pool.gains[active_sample_slot] or 1
  queue_engine_call(ids.amp, "setAmp", base * gain)
end

flush_engine_sends = function()
  local sends = pending_engine_sends
  local order = pending_engine_order
  pending_engine_sends = {}
  pending_engine_order = {}

  for _, key in ipairs(order) do
    if sends[key] ~= nil then
      sends[key]()
    end
  end

  if next(pending_engine_sends) == nil and engine_send_metro ~= nil then
    engine_send_metro:stop()
  end
end

local function reset_clock_origin()
  clock_origin = clock.get_beats()
  clock_sequence = 0
end

local function set_engine_play(x)
  print("elasticat: params/play action " .. tostring(x))
  if x == 1 and ids.clock_sync ~= nil and params:get(ids.clock_sync) == 1 then
    reset_clock_origin()
    engine_call("setPlayhead", 0)
  end
  engine_call("play", x)
end

local function send_clock_observation()
  if ids.target_bpm == nil or ids.sample_steps == nil then
    return
  end

  local tempo = clock.get_tempo()
  local beats = clock.get_beats()
  local start_point = params:get(ids.loop_start) or 0
  local end_point = params:get(ids.loop_end) or 128
  local region = math.max(0.01, end_point - start_point) / 128
  local loop_beats = math.max(0.25, (params:get(ids.sample_steps) * region) / 4)
  local expected_phase = ((beats - clock_origin) / loop_beats) % 1

  clock_sequence = clock_sequence + 1
  params:set(ids.target_bpm, tempo, true)

  if engine.syncClock ~= nil then
    engine.syncClock(expected_phase, tempo, clock_sequence)
  elseif engine.targetBpm ~= nil then
    engine.targetBpm(tempo)
  end
end

function elasticat.stop_clock_sync()
  if sync_thread ~= nil then
    clock.cancel(sync_thread)
    sync_thread = nil
  end
end

function elasticat.stop_param_throttle()
  pending_engine_sends = {}
  pending_engine_order = {}
  if engine_send_metro ~= nil then
    engine_send_metro:stop()
    engine_send_metro = nil
  end
end

function elasticat.start_clock_sync()
  elasticat.stop_clock_sync()
  reset_clock_origin()
  sync_thread = clock.run(function()
    while true do
      clock.sync(1 / 4)
      if params:get(ids.clock_sync) == 1 then
        send_clock_observation()
      end
    end
  end)
end

function elasticat.log_engine_commands()
  print("elasticat: command loadSample = " .. tostring(engine.loadSample ~= nil))
  print("elasticat: command loadPoolSlot = " .. tostring(engine.loadPoolSlot ~= nil))
  print("elasticat: command setSampleSlot = " .. tostring(engine.setSampleSlot ~= nil))
  print("elasticat: command legacy load = " .. tostring(engine.commands ~= nil and engine.commands.load ~= nil))
  print("elasticat: command play = " .. tostring(engine.play ~= nil))
  print("elasticat: command setMode = " .. tostring(engine.setMode ~= nil))
  print("elasticat: command syncClock = " .. tostring(engine.syncClock ~= nil))
  print("elasticat: command triggerSlice = " .. tostring(engine.triggerSlice ~= nil))
  print("elasticat: command setSliceSyncToClock = " .. tostring(engine.setSliceSyncToClock ~= nil))
  print("elasticat: command setSliceRate = " .. tostring(engine.setSliceRate ~= nil))
end

function elasticat.play(state)
  set_engine_play(state and 1 or 0)
end

function elasticat.stop_reset()
  flush_engine_sends()
  if engine.stopAndReset ~= nil then
    engine_call("stopAndReset")
  elseif engine.stop ~= nil then
    engine_call("stop")
  else
    engine_call("play", 0)
    engine_call("playhead", 0)
  end
end

function elasticat.request_status()
  engine_call("requestStatus")
end

function elasticat.set_pitch(value)
  engine_call("setPitch", value)
end

function elasticat.set_reverse(reverse)
  engine_call("setReverse", (reverse == true or reverse == 1) and 1 or 0)
end

function elasticat.trigger_slice(slice_index, start_point, end_point, play_mode, reverse, velocity, length_seconds, pitch_value)
  local reverse_flag = (reverse == true or reverse == 1) and 1 or 0
  engine_call(
    "triggerSlice",
    slice_index,
    map_trim_point(start_point),
    map_trim_point(end_point),
    play_mode,
    reverse_flag,
    velocity or 1,
    length_seconds or 0,
    pitch_value or 0
  )
end

function elasticat.release_slice(slice_index)
  engine_call("releaseSlice", slice_index)
end

function elasticat.release_all_slices()
  engine_call("releaseAllSlices")
end

function elasticat.set_loop_region(start_point, end_point, reset_playhead)
  flush_engine_sends()
  local engine_start = map_trim_point(start_point)
  local engine_end = map_trim_point(end_point)
  if reset_playhead ~= nil and engine.loopRegionPlayhead ~= nil then
    local phase = type(reset_playhead) == "number" and reset_playhead or 0
    engine_call("loopRegionPlayhead", engine_start, engine_end, phase)
    return
  end

  engine_call("loopStart", engine_start)
  engine_call("loopEnd", engine_end)
  if type(reset_playhead) == "number" then
    engine_call("playhead", reset_playhead)
  elseif reset_playhead then
    engine_call("playhead", 0)
  end
end

-- Auditions the File-edit slot as a raw looped sample -- native rate, no
-- timestretch / pitch / warp -- through its own preview synth (engine
-- previewSlot), using the slot's trim window and gain. Only while master
-- transport is stopped so it never fights sequenced playback.
function elasticat.preview_trim(on)
  if on then
    if ids.play ~= nil and params:get(ids.play) == 1 then
      return
    end
    local slot = file_edit_slot
    local trim_start, trim_end, duration = trim_bounds(slot)
    local start_frac, end_frac = 0, 1
    if duration > 0 then
      start_frac = util.clamp(trim_start / duration, 0, 0.999)
      end_frac = util.clamp(trim_end / duration, start_frac + 0.001, 1)
    end
    local gain = sample_pool.gains[slot] or 1
    flush_engine_sends()
    engine_call("previewSlot", slot, start_frac, end_frac, gain, 1)
  else
    engine_call("previewSlot", 0, 0, 1, 1, 0)
  end
end

function elasticat.active_pool_slot()
  return active_sample_slot
end

function elasticat.file_edit_slot()
  return file_edit_slot
end

-- Active (playback) slot's BPM/steps, read straight from the pool so the visual
-- playhead rate stays correct even when the File page is editing another slot.
function elasticat.active_bpm()
  return sample_pool.bpms[active_sample_slot] or 120
end

function elasticat.active_steps()
  return sample_pool.steps[active_sample_slot] or 16
end

function elasticat.pool_path(slot)
  slot = slot or active_sample_slot
  if slot == 0 then
    return nil
  end
  return sample_pool.paths[sample_slot_number(slot)]
end

function elasticat.pool_label(slot)
  local path = elasticat.pool_path(slot)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return "empty"
  end
  return path:match("[^/\\]+$") or path
end

function elasticat.pool_meta(slot)
  slot = slot or active_sample_slot
  if slot == 0 then
    return { duration = 0, gain = 1 }
  end
  slot = sample_slot_number(slot)
  return {
    path = sample_pool.paths[slot],
    samples = sample_pool.samples[slot],
    rate = sample_pool.rates[slot],
    channels = sample_pool.channels[slot],
    bpm = sample_pool.bpms[slot],
    steps = sample_pool.steps[slot],
    trim_start = sample_pool.trim_starts[slot],
    trim_end = sample_pool.trim_ends[slot],
    gain = sample_pool.gains[slot] or 1,
    duration = sample_duration(slot)
  }
end

function elasticat.pool_snapshot()
  local snapshot = {}
  for slot = 1, 128 do
    if sample_pool.paths[slot] ~= nil then
      snapshot[slot] = {
        path = sample_pool.paths[slot],
        bpm = sample_pool.bpms[slot],
        steps = sample_pool.steps[slot],
        trim_start = sample_pool.trim_starts[slot],
        trim_end = sample_pool.trim_ends[slot],
        gain = sample_pool.gains[slot]
      }
    end
  end
  return snapshot
end

function elasticat.set_pool_slot(slot)
  set_active_pool_slot(slot)
end

-- Recompute BPM (filename, else keep current) and steps (from duration * bpm)
-- for the File-edit slot, applying to the pool + params (+ engine if it's also
-- the active slot).
function elasticat.recalc_bpm_steps()
  local slot = file_edit_slot
  local path = sample_pool.paths[slot]
  local samples = sample_pool.samples[slot] or 0
  local rate = sample_pool.rates[slot] or 0
  if path == nil or samples <= 0 or rate <= 0 then
    return
  end
  local duration = samples / rate
  local bpm = bpm_from_filename(path) or sample_pool.bpms[slot] or 120
  local steps = quantize_steps(duration * bpm / 60 * 4)
  sample_pool.bpms[slot] = bpm
  sample_pool.steps[slot] = steps
  -- Silent: update the display params (which track the file-edit slot) without
  -- firing their actions, then push to the engine only if this slot is playing.
  if params:lookup_param(ids.sample_bpm) ~= nil then
    params:set(ids.sample_bpm, bpm, true)
  end
  if params:lookup_param(ids.sample_steps) ~= nil then
    params:set(ids.sample_steps, steps, true)
  end
  if file_edits_active() then
    push_engine_slot_metadata(slot)
  end
  mark_pool_dirty(slot)
end

function elasticat.load_pool_slot(slot, path, make_active)
  if math.floor((tonumber(slot) or 1) + 0.5) < 1 then
    print("elasticat: slot 0 is Off; cannot load a sample there")
    return false
  end
  slot = sample_slot_number(slot)
  print("elasticat: pool slot " .. tostring(slot) .. " load " .. tostring(path))
  if path == nil or path == "-" or path == "" or path:sub(-1) == "/" or not is_audio_file(path) then
    print("elasticat: pool slot " .. tostring(slot) .. " ignored non-audio path")
    return false
  end
  if not util.file_exists(path) then
    print("elasticat: pool slot " .. tostring(slot) .. " missing " .. path)
    return false
  end

  local channels, samples, rate = audio.file_info(path)
  print("elasticat: audio.file_info slot=" .. tostring(slot) .. " ch=" .. tostring(channels) .. " samples=" .. tostring(samples) .. " rate=" .. tostring(rate))
  if (samples or 0) <= 0 or (rate or 0) <= 0 then
    print("elasticat: not an audio file: " .. path)
    return false
  end

  local filename_bpm = bpm_from_filename(path)
  local sidecar = read_sample_sidecar(path)
  local duration = samples / rate
  local param_bpm = params:lookup_param(ids.sample_bpm) ~= nil and params:get(ids.sample_bpm) or 120
  local param_steps = params:lookup_param(ids.sample_steps) ~= nil and params:get(ids.sample_steps) or 16
  -- BPM/step derivation mode: 1 auto (json > filename > current), 2 no change
  -- (keep current), 3 json only, 4 filename only. Governs whether a load
  -- overrides the BPM/steps you already dialed in.
  local mode = ids.bpm_step_mode ~= nil and params:lookup_param(ids.bpm_step_mode) ~= nil
    and params:get(ids.bpm_step_mode) or 1
  local bpm, steps
  if mode == 2 then
    bpm = sample_pool.bpms[slot] or param_bpm
    steps = sample_pool.steps[slot] or param_steps
  elseif mode == 3 then
    bpm = sidecar.bpm or sample_pool.bpms[slot] or param_bpm
    steps = sidecar.steps or quantize_steps(duration * bpm / 60 * 4)
  elseif mode == 4 then
    bpm = filename_bpm or sample_pool.bpms[slot] or param_bpm
    steps = quantize_steps(duration * bpm / 60 * 4)
  else
    bpm = sidecar.bpm or filename_bpm or sample_pool.bpms[slot] or param_bpm
    steps = sidecar.steps or quantize_steps(duration * bpm / 60 * 4)
  end
  local trim_start = util.clamp(sidecar.trim_start or sample_pool.trim_starts[slot] or 0, 0, duration)
  local trim_end = util.clamp(sidecar.trim_end or sample_pool.trim_ends[slot] or duration, 0, duration)
  if trim_end <= trim_start then
    trim_start = 0
    trim_end = duration
  end
  local gain = sidecar.gain or sample_pool.gains[slot] or 1

  sample_pool.paths[slot] = path
  sample_pool.samples[slot] = samples
  sample_pool.rates[slot] = rate
  sample_pool.channels[slot] = channels
  sample_pool.bpms[slot] = bpm
  sample_pool.steps[slot] = steps
  sample_pool.trim_starts[slot] = trim_start
  sample_pool.trim_ends[slot] = trim_end
  sample_pool.gains[slot] = gain

  if make_active then
    set_active_pool_slot(slot)
  end

  flush_engine_sends()
  load_sample_slot(slot, path)
  -- Refresh the File-page display if this is the edit slot, and re-push metadata
  -- to the engine if this is the playing slot.
  if slot == file_edit_slot then
    apply_file_slot_metadata(slot)
  end
  if slot == active_sample_slot then
    push_engine_slot_metadata(slot)
  end
  notify_pool_change("load", slot, path)
  return true
end

function elasticat.load_pool_paths(paths, selected_slot)
  if type(paths) ~= "table" then
    return
  end

  suppress_pool_callback = true
  selected_slot = sample_slot_number(selected_slot or active_sample_slot)
  for slot = 1, 128 do
    local entry = paths[slot] or paths[tostring(slot)]
    local path = type(entry) == "table" and entry.path or entry
    if path ~= nil and path ~= "" and path ~= "-" and util.file_exists(path) then
      elasticat.load_pool_slot(slot, path, slot == selected_slot)
      if type(entry) == "table" then
        sample_pool.bpms[slot] = tonumber(entry.bpm) or sample_pool.bpms[slot]
        sample_pool.steps[slot] = tonumber(entry.steps) or sample_pool.steps[slot]
        sample_pool.trim_starts[slot] = tonumber(entry.trim_start) or sample_pool.trim_starts[slot]
        sample_pool.trim_ends[slot] = tonumber(entry.trim_end) or sample_pool.trim_ends[slot]
        sample_pool.gains[slot] = tonumber(entry.gain) or sample_pool.gains[slot]
        if slot == active_sample_slot then
          push_engine_slot_metadata(slot)
        end
        if slot == file_edit_slot then
          apply_file_slot_metadata(slot)
        end
      end
    end
  end
  suppress_pool_callback = false
  notify_pool_change("restore", selected_slot, sample_pool.paths[selected_slot])
end

function elasticat.params(options)
  options = options or {}
  pool_options = options
  local prefix = options.prefix or "elasticat_"
  local default_sync = options.clock_sync == false and 0 or 1

  ids.sample_slot = param_id(prefix, "sample_slot")
  ids.sample = param_id(prefix, "sample")
  ids.machine = param_id(prefix, "machine")
  ids.mode = param_id(prefix, "mode")
  ids.play = param_id(prefix, "play")
  ids.clock_sync = param_id(prefix, "clock_sync")
  ids.target_bpm = param_id(prefix, "target_bpm")
  ids.sample_bpm = param_id(prefix, "sample_bpm")
  ids.sample_steps = param_id(prefix, "sample_steps")
  ids.file_slot = param_id(prefix, "file_slot")
  ids.bpm_step_mode = param_id(prefix, "bpm_step_mode")
  ids.recalc_bpm_steps = param_id(prefix, "recalc_bpm_steps")
  ids.trim_start = param_id(prefix, "trim_start")
  ids.trim_end = param_id(prefix, "trim_end")
  ids.gain = param_id(prefix, "gain")
  ids.amp = param_id(prefix, "amp")
  ids.loop_division = param_id(prefix, "loop_division")
  ids.trig_polyphony = param_id(prefix, "trig_polyphony")
  ids.playhead_return = param_id(prefix, "playhead_return")
  ids.pattern_steps = param_id(prefix, "pattern_steps")
  ids.default_length = param_id(prefix, "default_length")
  ids.default_velocity = param_id(prefix, "default_velocity")
  ids.env_reset = param_id(prefix, "env_reset")
  ids.lfo_reset = param_id(prefix, "lfo_reset")
  ids.filter_reset = param_id(prefix, "filter_reset")
  ids.loop_start = param_id(prefix, "loop_start")
  ids.loop_end = param_id(prefix, "loop_end")
  ids.range_start = param_id(prefix, "range_start")
  ids.range_end = param_id(prefix, "range_end")
  ids.range_end_sync = param_id(prefix, "range_end_sync")
  ids.sample_preview = param_id(prefix, "sample_preview")
  ids.mode_macro = param_id(prefix, "mode_macro")
  ids.mode_switch_fade = param_id(prefix, "mode_switch_fade")
  ids.debug = param_id(prefix, "debug")
  ids.live_performance_mode = param_id(prefix, "live_performance_mode")
  ids.step_preview = param_id(prefix, "step_preview")

  local function apply_current_mode_params()
    local mode = params:get(ids.mode)
    if mode == 1 or mode == 2 then
      engine_call("loopStart", map_trim_point(params:get(ids.loop_start)))
      engine_call("loopEnd", map_trim_point(params:get(ids.loop_end)))
    elseif mode == 3 then
      engine_call("chopSteps", params:get(param_id(prefix, "chop_steps")))
      engine_call("chopLoopMode", params:get(param_id(prefix, "chop_loop_mode")) - 1)
      engine_call("chopAttack", params:get(param_id(prefix, "chop_attack")))
      engine_call("chopHold", params:get(param_id(prefix, "chop_hold")))
      engine_call("chopRelease", params:get(param_id(prefix, "chop_release")))
    elseif mode == 4 then
      engine_call("grainSize", params:get(param_id(prefix, "grain_size")))
      engine_call("grainDensity", params:get(param_id(prefix, "grain_density")))
      engine_call("grainJitter", params:get(param_id(prefix, "grain_jitter")))
    elseif mode == 5 then
      engine_call("wsolaWindow", params:get(param_id(prefix, "wsola_window")))
      engine_call("wsolaSearch", params:get(param_id(prefix, "wsola_search")))
    elseif mode == 6 then
      engine_call("pvWindow", params:get(param_id(prefix, "pv_window")))
      engine_call("pvDispersion", params:get(param_id(prefix, "pv_dispersion")))
    end
  end

  params:add_group(param_id(prefix, "group_setup"), "elasticat setup", 18)

  add_control(ids.sample_slot, "sample slot",
    cs.new(0, 128, "lin", 1, 1, "", 1 / 128),
    function(x)
      set_active_pool_slot(x)
    end,
    function(param)
      local v = math.floor(param:get() + 0.5)
      return v < 1 and "off" or tostring(v)
    end)

  -- File-editor slot: which slot the File page edits, independent of the track's
  -- playback slot (sample_slot).
  add_control(ids.file_slot, "file edit slot",
    cs.new(1, 128, "lin", 1, 1, "", 1 / 127),
    function(x)
      set_file_edit_slot(x)
    end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_file(ids.sample, "sample", options.sample or _path.audio)
  params:set_action(ids.sample, function(path)
    print("elasticat: sample param action " .. tostring(path))
    if path ~= nil and path ~= "-" and path ~= "" and is_audio_file(path) then
      if not elasticat.load_pool_slot(file_edit_slot, path) then
        params:set(ids.sample, _path.audio, true)
      end
    end
  end)

  params:add_option(ids.machine, "machine", elasticat.machines, 1)
  params:set_action(ids.machine, function(x)
    flush_engine_sends()
    engine_call("setMode", params:get(ids.mode) - 1)
    apply_current_mode_params()
    if x == 1 then
      engine_call("play", params:get(ids.play))
    else
      engine_call("play", 0)
    end
  end)

  params:add_option(ids.mode, "engine mode", elasticat.modes, 1)
  params:set_action(ids.mode, function(x)
    flush_engine_sends()
    engine_call("setMode", x - 1)
    apply_current_mode_params()
  end)

  -- Lua-side grid-interaction settings only; never sent to the engine.
  add_control(ids.loop_division, "loop key division",
    cs.new(2, 32, "lin", 2, 16, "", 2 / 30),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(ids.trig_polyphony, "trig polyphony", {"mono", "poly"}, 1)

  -- Where the playhead lands when the last live loop key is released during
  -- playback: return (rejoin the sequence), boomerang (keep going from the
  -- current position), reset (jump to the region start). grid_sequencer reads
  -- this live; no engine action.
  params:add_option(ids.playhead_return, "playhead return", {"return", "boomerang", "reset"}, 2)

  add_control(ids.mode_macro, "mode macro",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(ids.mode_macro, "setModeMacro", x) end)

  params:add_binary(ids.play, "play", "toggle", 0)
  params:set_action(ids.play, set_engine_play)

  params:add_binary(ids.clock_sync, "clock sync", "toggle", default_sync)
  params:set_action(ids.clock_sync, function(x)
    if x == 1 then
      send_clock_observation()
      elasticat.start_clock_sync()
    else
      elasticat.stop_clock_sync()
    end
  end)

  -- Pure UI-behavior toggles, no engine action: live performance mode governs
  -- whether held loop keys override the sequencer during playback (grid_sequencer
  -- reads this live), and step preview gates whether holding a step/loop key while
  -- stopped audibly previews it.
  params:add_binary(ids.live_performance_mode, "live performance mode", "toggle", 0)
  params:add_binary(ids.step_preview, "step preview", "toggle", 1)

  add_control(ids.amp, "amp",
    cs.new(0, 2, "lin", 0.01, 0.8, "", 0.005),
    function(_) send_effective_amp() end)

  add_control(param_id(prefix, "pan"), "pan",
    cs.new(-1, 1, "lin", 0.01, 0, "", 0.005),
    function(x) queue_engine_call(param_id(prefix, "pan"), "setPan", x) end)

  add_control(param_id(prefix, "source_bpm"), "derived source bpm",
    cs.new(20, 300, "lin", 0.1, 120, "bpm", 1 / 280),
    function(_) end)

  add_control(ids.target_bpm, "target bpm",
    cs.new(20, 300, "lin", 1, 120, "bpm", 1 / 280),
    function(x)
      queue_engine_send(ids.target_bpm, function()
        set_internal_clock_tempo(x)
        engine_call("targetBpm", x)
      end)
    end)

  add_control(ids.sample_bpm, "sample bpm",
    cs.new(20, 300, "lin", 1, 120, "bpm", 1 / 280),
    function(x)
      sample_pool.bpms[file_edit_slot] = x
      mark_pool_dirty(file_edit_slot)
      if file_edits_active() then
        if params:lookup_param(param_id(prefix, "source_bpm")) ~= nil then
          params:set(param_id(prefix, "source_bpm"), x, true)
        end
        queue_engine_call(ids.sample_bpm, "sourceBpm", x)
      end
    end)

  add_control(ids.sample_steps, "sample steps",
    cs.new(1, 512, "lin", 1, 16, "", 1 / 511),
    function(x)
      sample_pool.steps[file_edit_slot] = x
      mark_pool_dirty(file_edit_slot)
      if file_edits_active() then
        queue_engine_call(ids.sample_steps, "setSampleSteps", x)
      end
    end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(ids.bpm_step_mode, "bpm/step mode",
    {"auto", "no change", "json", "filename"}, 1)

  -- Recalc trigger: selecting "run" recompiles BPM (filename, else current) and
  -- steps for the active sample slot, then snaps back to "-".
  params:add_option(ids.recalc_bpm_steps, "recalc bpm/steps", {"-", "run"}, 1)
  params:set_action(ids.recalc_bpm_steps, function(x)
    if x == 2 then
      elasticat.recalc_bpm_steps()
      params:set(ids.recalc_bpm_steps, 1, true)
    end
  end)

  add_control(ids.trim_start, "sample trim start",
    cs.new(0, 3600, "lin", 0.001, 0, "s", 0.001),
    function(x)
      local slot = file_edit_slot
      local prev_start, prev_end, duration = trim_bounds(slot)
      -- Dragging trim start shifts trim end by the same amount, so the
      -- trimmed length stays constant while scrubbing -- unless trim end is
      -- pinned at the sample's actual end, in which case it stops there and
      -- further start movement just shortens the trim. Deriving trim end
      -- from its own previous value (not a remembered "original" length)
      -- means it un-pins the instant start moves back the other way.
      local next_start = util.clamp(x, 0, duration)
      local delta = next_start - prev_start
      local next_end = util.clamp(prev_end + delta, 0, duration)
      next_start = util.clamp(next_start, 0, math.max(0, next_end - 0.001))
      sample_pool.trim_starts[slot] = next_start
      sample_pool.trim_ends[slot] = next_end
      if math.abs(next_start - x) > 0.000001 then
        params:set(ids.trim_start, next_start, true)
      end
      if math.abs(next_end - prev_end) > 0.000001 then
        params:set(ids.trim_end, next_end, true)
      end
      if file_edits_active() then
        update_engine_loop_points()
      end
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.3f s", param:get()) end)

  add_control(ids.trim_end, "sample trim end",
    cs.new(0, 3600, "lin", 0.001, 0, "s", 0.001),
    function(x)
      local slot = file_edit_slot
      local trim_start, _, duration = trim_bounds(slot)
      local next_end = util.clamp(x, math.min(duration, trim_start + 0.001), duration)
      sample_pool.trim_ends[slot] = next_end
      if math.abs(next_end - x) > 0.000001 then
        params:set(ids.trim_end, next_end, true)
      end
      if file_edits_active() then
        update_engine_loop_points()
      end
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.3f s", param:get()) end)

  add_control(ids.gain, "sample gain",
    cs.new(0, 4, "lin", 0.01, 1, "x", 0.005),
    function(x)
      local slot = file_edit_slot
      sample_pool.gains[slot] = x
      if file_edits_active() then
        send_effective_amp()
      end
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.2fx", param:get()) end)

  add_control(ids.pattern_steps, "pattern steps",
    cs.new(1, 256, "lin", 1, 16, "", 1 / 255),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  add_control(ids.default_length, "default trig length",
    cs.new(0.25, 16, "lin", 0.25, 1, "", 0.25 / 15.75),
    function(_) end,
    function(param) return string.format("%.2f", param:get()) end)

  add_control(ids.default_velocity, "default velocity",
    cs.new(0, 1, "lin", 0.01, 1, "", 0.01),
    function(_) end,
    function(param) return tostring(math.floor((param:get() * 100) + 0.5)) end)

  -- Ghost-trigger reset flags (default on). A normal trigger resets envelope /
  -- LFO / filter; a ghost trigger has these off. No engine action yet -- env /
  -- LFO / filter don't exist until Phase 2/3, so these are forward-compatible
  -- placeholders that also feed the ghost/normal derivation in grid_sequencer.
  params:add_binary(ids.env_reset, "env reset", "toggle", 1)
  params:add_binary(ids.lfo_reset, "lfo reset", "toggle", 1)
  params:add_binary(ids.filter_reset, "filter reset", "toggle", 1)

  params:add_group(param_id(prefix, "group_loop"), "loop playback", 6)

  add_control(param_id(prefix, "playhead"), "playhead",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(param_id(prefix, "playhead"), "setPlayhead", x) end)
  if params.hide ~= nil then
    params:hide(param_id(prefix, "playhead"))
  end

  add_control(ids.loop_start, "sample start",
    cs.new(0, 128, "lin", 0.01, 0, "", 1 / 128),
    function(x) queue_engine_call(ids.loop_start, "loopStart", map_trim_point(x)) end)

  add_control(ids.loop_end, "sample end",
    cs.new(0, 128, "lin", 0.01, 128, "", 1 / 128),
    function(x) queue_engine_call(ids.loop_end, "loopEnd", map_trim_point(x)) end)

  -- Range narrows the trim window; changing it re-maps the current loop points
  -- through map_trim_point. During sequenced playback the grid re-sets the
  -- region every step, so this just handles the base/encoder-driven case.
  local last_range_start = 0

  add_control(ids.range_start, "range start",
    cs.new(0, 128, "lin", 0.01, 0, "", 1 / 128),
    function(x)
      -- When E-SNC is on, range start and end move as one rigid pair: the shared
      -- delta is clamped so end stays <= 128 and start stays >= 0, which keeps
      -- the length constant even on a fast overshoot into the boundary. (Moving
      -- end freely then clamping only end used to collapse the gap at 128 and
      -- then drag end back down on the way out -- the "bounce to 120".)
      if ids.range_end_sync ~= nil and params:get(ids.range_end_sync) == 1 then
        local prev_start = last_range_start
        local prev_end = params:get(ids.range_end) or 128
        local delta = util.clamp(x - prev_start, -prev_start, 128 - prev_end)
        local next_start = prev_start + delta
        local next_end = prev_end + delta
        if math.abs(next_start - x) > 0.000001 then
          params:set(ids.range_start, next_start, true)
        end
        params:set(ids.range_end, next_end, true)
        last_range_start = next_start
      else
        -- Independent: start can never reach end. Clamp to end - 1 (so its max
        -- is 127 when end is 128), which stops the start marker at the end
        -- rather than crossing it.
        local max_start = util.clamp((params:get(ids.range_end) or 128) - 1, 0, 127)
        if x > max_start then
          params:set(ids.range_start, max_start, true)
          last_range_start = max_start
        else
          last_range_start = x
        end
      end
      queue_engine_loop_points()
    end)

  add_control(ids.range_end, "range end",
    cs.new(0, 128, "lin", 0.01, 128, "", 1 / 128),
    function(x)
      -- End can never reach start: its minimum is start + 1.
      local min_end = util.clamp((params:get(ids.range_start) or 0) + 1, 1, 128)
      if x < min_end then
        params:set(ids.range_end, min_end, true)
      end
      queue_engine_loop_points()
    end)

  -- E-SNC: when on, range end tracks range start (see range_start action and the
  -- grid p-lock auto-lock in param_values). Default off -- a new user could be
  -- confused that start won't move independently until end is adjusted. Pure UI
  -- behavior, no engine action.
  params:add_binary(ids.range_end_sync, "range end sync", "toggle", 0)

  -- Sample preview: momentary audition of the current sample's trim window,
  -- only while master playback is stopped (see elasticat.preview_trim). Driven
  -- by encoder on the File page and/or a grid hold.
  params:add_binary(ids.sample_preview, "sample preview", "toggle", 0)
  params:set_action(ids.sample_preview, function(x)
    elasticat.preview_trim(x == 1)
  end)

  add_control(param_id(prefix, "xfade"), "loop xfade",
    cs.new(0, 0.25, "lin", 0.001, 0.005, "", 0.004),
    function(x) queue_engine_call(param_id(prefix, "xfade"), "xfade", x) end,
    format_ms)

  add_control(param_id(prefix, "pitch"), "pitch",
    cs.new(-24, 24, "lin", 0.1, 0, "st", 0.1 / 48),
    function(x) queue_engine_call(param_id(prefix, "pitch"), "setPitch", x) end)

  params:add_binary(param_id(prefix, "loop_reverse"), "loop reverse", "toggle", 0)
  params:set_action(param_id(prefix, "loop_reverse"), function(x)
    queue_engine_call(param_id(prefix, "loop_reverse"), "setReverse", x)
  end)

  params:add_group(param_id(prefix, "group_engine_modes"), "engine algorithms", 13)

  add_control(ids.mode_switch_fade, "mode switch fade",
    cs.new(0.001, 0.25, "lin", 0.001, 0.05, "", 0.001 / 0.249),
    function(x) queue_engine_call(ids.mode_switch_fade, "setModeSwitchFade", x) end)

  add_control(param_id(prefix, "chop_steps"), "chop steps",
    cs.new(0.05, 16, "lin", 0.05, 1, "steps", 0.05 / 15.95),
    function(x) queue_engine_call(param_id(prefix, "chop_steps"), "chopSteps", x) end)

  params:add_option(param_id(prefix, "chop_loop_mode"), "chop loop mode", {"forward stop", "loop forward", "ping pong"}, 1)
  params:set_action(param_id(prefix, "chop_loop_mode"), function(x) engine_call("chopLoopMode", x - 1) end)

  add_control(param_id(prefix, "chop_attack"), "chop attack",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.002, "s", 0.0005 / 0.1999),
    function(x) queue_engine_call(param_id(prefix, "chop_attack"), "chopAttack", x) end,
    format_ms)

  add_control(param_id(prefix, "chop_hold"), "chop hold",
    cs.new(0, 0.5, "lin", 0.001, 0.04, "s", 0.001 / 0.5),
    function(x) queue_engine_call(param_id(prefix, "chop_hold"), "chopHold", x) end,
    format_ms)

  add_control(param_id(prefix, "chop_release"), "chop release",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.01, "s", 0.0005 / 0.1999),
    function(x) queue_engine_call(param_id(prefix, "chop_release"), "chopRelease", x) end,
    format_ms)

  add_control(param_id(prefix, "grain_size"), "grain size",
    cs.new(0.002, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.498),
    function(x) queue_engine_call(param_id(prefix, "grain_size"), "grainSize", x) end,
    format_ms)

  add_control(param_id(prefix, "grain_density"), "grain density",
    cs.new(1, 64, "lin", 1, 8, "gr/step", 1 / 63),
    function(x) queue_engine_call(param_id(prefix, "grain_density"), "grainDensity", x) end)

  add_control(param_id(prefix, "grain_jitter"), "grain jitter",
    cs.new(0, 0.25, "lin", 0.001, 0.01, "s", 0.001 / 0.25),
    function(x) queue_engine_call(param_id(prefix, "grain_jitter"), "grainJitter", x) end,
    format_ms)

  add_control(param_id(prefix, "wsola_window"), "OLA window",
    cs.new(0.005, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.495),
    function(x) queue_engine_call(param_id(prefix, "wsola_window"), "wsolaWindow", x) end,
    format_ms)

  add_control(param_id(prefix, "wsola_search"), "OLA wander",
    cs.new(0, 0.1, "lin", 0.001, 0.015, "s", 0.001 / 0.1),
    function(x) queue_engine_call(param_id(prefix, "wsola_search"), "wsolaSearch", x) end,
    format_ms)

  add_control(param_id(prefix, "pv_window"), "PC window",
    cs.new(0.005, 2, "lin", 0.001, 0.2, "", 0.001 / 1.995),
    function(x) queue_engine_call(param_id(prefix, "pv_window"), "pvWindow", x) end,
    format_ms)

  add_control(param_id(prefix, "pv_dispersion"), "PC dispersion",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(param_id(prefix, "pv_dispersion"), "pvDispersion", x) end)

  params:add_group(param_id(prefix, "group_slices"), "slice machines", 11)

  add_control(param_id(prefix, "slice_count"), "slice count",
    cs.new(1, 32, "lin", 1, 16, "", 1 / 31),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  add_control(param_id(prefix, "slice_index"), "slice index",
    cs.new(1, 32, "lin", 1, 1, "", 1 / 31),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(param_id(prefix, "slice_play_mode"), "slice play mode", {"1 shot", "1 shot hold", "loop", "continue"}, 1)
  params:set_action(param_id(prefix, "slice_play_mode"), function(_) end)

  params:add_binary(param_id(prefix, "slice_reverse"), "slice reverse", "toggle", 0)
  params:set_action(param_id(prefix, "slice_reverse"), function(_) end)

  params:add_binary(param_id(prefix, "slice_sync"), "slice clock sync", "toggle", 1)
  params:set_action(param_id(prefix, "slice_sync"), function(x)
    queue_engine_call(param_id(prefix, "slice_sync"), "setSliceSyncToClock", x)
  end)

  add_control(param_id(prefix, "slice_rate"), "slice rate",
    cs.new(0.125, 8, "exp", 0.01, 1, "x", 0.01),
    function(x) queue_engine_call(param_id(prefix, "slice_rate"), "setSliceRate", x) end,
    function(param) return string.format("%.2fx", param:get()) end)

  params:add_option(param_id(prefix, "slice_polyphony"), "slice polyphony", {"poly 8", "mono"}, 1)
  params:set_action(param_id(prefix, "slice_polyphony"), function(x)
    engine_call("setSliceMono", x == 2 and 1 or 0)
  end)

  params:add_binary(param_id(prefix, "slice_hold_to_step"), "slice hold to step", "toggle", 1)
  params:set_action(param_id(prefix, "slice_hold_to_step"), function(_) end)

  add_control(param_id(prefix, "slice_attack"), "slice attack",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.002, "", 0.0005 / 0.1999),
    function(x) queue_engine_call(param_id(prefix, "slice_attack"), "sliceAttack", x) end,
    format_ms)

  add_control(param_id(prefix, "slice_hold"), "slice hold",
    cs.new(0, 4, "lin", 0.01, 0.25, "", 0.01 / 4),
    function(_) end,
    format_ms)

  add_control(param_id(prefix, "slice_release"), "slice release",
    cs.new(0.0001, 0.5, "lin", 0.0001, 0.02, "", 0.001 / 0.4999),
    function(x) queue_engine_call(param_id(prefix, "slice_release"), "sliceRelease", x) end,
    format_ms)

  params:add_group(param_id(prefix, "group_razor"), "razor slices", 65)

  params:add_trigger(param_id(prefix, "razor_reset"), "reset razor slices")
  params:set_action(param_id(prefix, "razor_reset"), function()
    for i = 1, 32 do
      local start_id = param_id(prefix, string.format("razor_%02d_start", i))
      local end_id = param_id(prefix, string.format("razor_%02d_end", i))
      local start_point = (i - 1) * 4
      local end_point = i * 4
      razor_start_values[i] = start_point
      params:set(start_id, start_point, true)
      params:set(end_id, end_point, true)
    end
  end)

  for i = 1, 32 do
    local start_id = param_id(prefix, string.format("razor_%02d_start", i))
    local end_id = param_id(prefix, string.format("razor_%02d_end", i))
    local default_start = (i - 1) * 4
    local default_end = i * 4
    razor_start_values[i] = default_start

    add_control(start_id, string.format("razor %02d start", i),
      cs.new(0, 128, "lin", 0.01, default_start, "", 1 / 128),
      function(x)
        if razor_adjusting then
          razor_start_values[i] = x
          return
        end
        local previous = razor_start_values[i] or default_start
        local delta = x - previous
        razor_start_values[i] = x
        if math.abs(delta) > 0 then
          local current_end = params:get(end_id)
          local next_end = util.clamp(current_end + delta, 0, 128)
          if next_end <= x then
            next_end = util.clamp(x + 0.01, 0.01, 128)
          end
          razor_adjusting = true
          params:set(end_id, next_end)
          razor_adjusting = false
        end
      end)

    add_control(end_id, string.format("razor %02d end", i),
      cs.new(0, 128, "lin", 0.01, default_end, "", 1 / 128),
      function(x)
        if razor_adjusting then
          return
        end
        local current_start = params:get(start_id)
        if x <= current_start then
          razor_adjusting = true
          params:set(end_id, util.clamp(current_start + 0.01, 0.01, 128))
          razor_adjusting = false
        end
      end)
  end

  params:add_group(param_id(prefix, "group_system"), "system", 2)

  params:add_trigger(param_id(prefix, "reset"), "reset")
  params:set_action(param_id(prefix, "reset"), function() engine_call("reset") end)

  params:add_option(ids.debug, "debug", {"errors", "lifecycle", "clock", "verbose"}, 2)
  params:set_action(ids.debug, function(x) engine_call("setDebug", x - 1) end)

  if default_sync == 1 then
    send_clock_observation()
    elasticat.start_clock_sync()
  end
end

return elasticat
