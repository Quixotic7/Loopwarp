-- loopwarp
--
-- Parameter helper for the bundled Engine_LoopWarp.
--
-- Minimal script usage:
--   engine.name = "LoopWarp"
--   local loopwarp = include("lib/loopwarp")
--   function init()
--     loopwarp.params()
--   end

local cs = require "controlspec"
local unpack = table.unpack or unpack

local loopwarp = {}

loopwarp.modes = {
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
  if bpm == nil then
    return nil
  end
  return tonumber(bpm)
end

local function quantize_steps(value)
  return math.max(1, math.floor(value + 0.5))
end

local function format_ms(param)
  return tostring(math.floor((param:get() * 1000) + 0.5)) .. " ms"
end

local function load_sample(path)
  if engine.loadSample ~= nil then
    print("loopwarp: sending engine.loadSample " .. path)
    engine.loadSample(path)
  elseif engine.commands ~= nil and engine.commands.load ~= nil then
    -- Older compiled LoopWarp versions registered a command named "load".
    -- Call through the command table to avoid norns' reserved engine.load().
    print("loopwarp: sending legacy engine command load " .. path)
    engine.commands.load.func(path)
  else
    print("loopwarp: engine loadSample command missing; restart/recompile norns")
  end
end

local function engine_call(name, ...)
  if engine[name] ~= nil then
    engine[name](...)
  else
    print("loopwarp: engine command missing: " .. name)
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
  print("loopwarp: params/play action " .. tostring(x))
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

function loopwarp.stop_clock_sync()
  if sync_thread ~= nil then
    clock.cancel(sync_thread)
    sync_thread = nil
  end
end

function loopwarp.stop_param_throttle()
  pending_engine_sends = {}
  pending_engine_order = {}
  if engine_send_metro ~= nil then
    engine_send_metro:stop()
    engine_send_metro = nil
  end
end

function loopwarp.start_clock_sync()
  loopwarp.stop_clock_sync()
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

function loopwarp.log_engine_commands()
  print("loopwarp: command loadSample = " .. tostring(engine.loadSample ~= nil))
  print("loopwarp: command legacy load = " .. tostring(engine.commands ~= nil and engine.commands.load ~= nil))
  print("loopwarp: command play = " .. tostring(engine.play ~= nil))
  print("loopwarp: command setMode = " .. tostring(engine.setMode ~= nil))
  print("loopwarp: command syncClock = " .. tostring(engine.syncClock ~= nil))
end

function loopwarp.play(state)
  set_engine_play(state and 1 or 0)
end

function loopwarp.request_status()
  engine_call("requestStatus")
end

function loopwarp.set_loop_region(start_point, end_point, reset_playhead)
  flush_engine_sends()
  engine_call("loopStart", start_point)
  engine_call("loopEnd", end_point)
  if reset_playhead then
    engine_call("playhead", 0)
  end
end

function loopwarp.params(options)
  options = options or {}
  local prefix = options.prefix or "loopwarp_"
  local default_sync = options.clock_sync == false and 0 or 1

  ids.sample = param_id(prefix, "sample")
  ids.mode = param_id(prefix, "mode")
  ids.play = param_id(prefix, "play")
  ids.clock_sync = param_id(prefix, "clock_sync")
  ids.target_bpm = param_id(prefix, "target_bpm")
  ids.sample_bpm = param_id(prefix, "sample_bpm")
  ids.sample_steps = param_id(prefix, "sample_steps")
  ids.loop_start = param_id(prefix, "loop_start")
  ids.loop_end = param_id(prefix, "loop_end")
  ids.mode_macro = param_id(prefix, "mode_macro")
  ids.mode_switch_fade = param_id(prefix, "mode_switch_fade")
  ids.debug = param_id(prefix, "debug")

  local function apply_current_mode_params()
    local mode = params:get(ids.mode)
    if mode == 1 or mode == 2 then
      engine_call("loopStart", params:get(ids.loop_start))
      engine_call("loopEnd", params:get(ids.loop_end))
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

  params:add_group(param_id(prefix, "group"), options.name or "loopwarp", 31)

  params:add_file(ids.sample, "sample", options.sample or _path.audio)
  params:set_action(ids.sample, function(path)
    print("loopwarp: sample param action " .. tostring(path))
    if path ~= nil and path ~= "-" and path ~= "" and is_audio_file(path) then
      if util.file_exists(path) then
        local _, samples, rate = audio.file_info(path)
        print("loopwarp: audio.file_info samples=" .. tostring(samples) .. " rate=" .. tostring(rate))
        if (samples or 0) <= 0 or (rate or 0) <= 0 then
          print("loopwarp: not an audio file: " .. path)
          params:set(ids.sample, _path.audio, true)
          return
        end
        local filename_bpm = bpm_from_filename(path)
        if filename_bpm ~= nil then
          params:set(ids.sample_bpm, filename_bpm)
        end
        if ids.sample_steps ~= nil then
          local duration = samples / rate
          local bpm = params:get(ids.sample_bpm)
          local inferred_steps = quantize_steps(duration * bpm / 60 * 4)
          print("loopwarp: sample bpm=" .. tostring(bpm) .. " inferred sample steps=" .. tostring(inferred_steps))
          params:set(ids.sample_steps, inferred_steps)
        end
        flush_engine_sends()
        load_sample(path)
      else
        print("loopwarp: sample missing, not loading: " .. path)
        params:set(ids.sample, _path.audio, true)
      end
    end
  end)

  params:add_option(ids.mode, "mode", loopwarp.modes, 1)
  params:set_action(ids.mode, function(x)
    flush_engine_sends()
    engine_call("setMode", x - 1)
    apply_current_mode_params()
  end)

  add_control(ids.mode_macro, "mode macro",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(ids.mode_macro, "setModeMacro", x) end)

  params:add_binary(ids.play, "play", "toggle", 0)
  params:set_action(ids.play, set_engine_play)

  params:add_binary(ids.clock_sync, "clock sync", "toggle", default_sync)
  params:set_action(ids.clock_sync, function(x)
    if x == 1 then
      send_clock_observation()
      loopwarp.start_clock_sync()
    else
      loopwarp.stop_clock_sync()
    end
  end)

  add_control(param_id(prefix, "amp"), "amp",
    cs.new(0, 2, "lin", 0.01, 0.8, "", 0.005),
    function(x) queue_engine_call(param_id(prefix, "amp"), "setAmp", x) end)

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
        if clock.set_tempo ~= nil then
          clock.set_tempo(x)
        end
        engine_call("targetBpm", x)
      end)
    end)

  add_control(ids.sample_bpm, "sample bpm",
    cs.new(20, 300, "lin", 1, 120, "bpm", 1 / 280),
    function(x) queue_engine_call(ids.sample_bpm, "sourceBpm", x) end)

  add_control(ids.sample_steps, "sample steps",
    cs.new(1, 512, "lin", 1, 16, "", 1 / 511),
    function(x) queue_engine_call(ids.sample_steps, "setSampleSteps", x) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  add_control(param_id(prefix, "playhead"), "playhead",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(param_id(prefix, "playhead"), "setPlayhead", x) end)
  if params.hide ~= nil then
    params:hide(param_id(prefix, "playhead"))
  end

  add_control(ids.loop_start, "sample start",
    cs.new(0, 128, "lin", 0.01, 0, "", 1 / 128),
    function(x) queue_engine_call(ids.loop_start, "loopStart", x) end)

  add_control(ids.loop_end, "sample end",
    cs.new(0, 128, "lin", 0.01, 128, "", 1 / 128),
    function(x) queue_engine_call(ids.loop_end, "loopEnd", x) end)

  add_control(param_id(prefix, "xfade"), "loop xfade",
    cs.new(0, 0.25, "lin", 0.001, 0.005, "", 0.004),
    function(x) queue_engine_call(param_id(prefix, "xfade"), "xfade", x) end,
    format_ms)

  add_control(param_id(prefix, "pitch"), "pitch",
    cs.new(-24, 24, "lin", 0.1, 0, "st", 0.1 / 48),
    function(x) queue_engine_call(param_id(prefix, "pitch"), "setPitch", x) end)

  add_control(ids.mode_switch_fade, "mode switch fade",
    cs.new(0.001, 0.25, "lin", 0.001, 0.05, "", 0.001 / 0.249),
    function(x) queue_engine_call(ids.mode_switch_fade, "setModeSwitchFade", x) end)

  add_control(param_id(prefix, "chop_steps"), "chop steps",
    cs.new(0.25, 16, "lin", 0.25, 1, "steps", 0.25 / 15.75),
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

  params:add_trigger(param_id(prefix, "reset"), "reset")
  params:set_action(param_id(prefix, "reset"), function() engine_call("reset") end)

  params:add_option(ids.debug, "debug", {"errors", "lifecycle", "clock", "verbose"}, 2)
  params:set_action(ids.debug, function(x) engine_call("setDebug", x - 1) end)

  if default_sync == 1 then
    send_clock_observation()
    loopwarp.start_clock_sync()
  end
end

return loopwarp
