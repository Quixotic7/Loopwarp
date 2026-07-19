engine.name = "LoopWarp"

local loopwarp = include("lib/loopwarp")
local fileselect = require "fileselect"

local PREFIX = "loopwarp_"
local playing = false
local alt = false
local browsing = false
local browser_state_file = nil
local last_sample_folder = nil
local redraw_metro = nil
local redraw_pending = true
local previous_osc_event = osc.event
local quiet_osc_paths = {
  ["/loopwarp/status"] = true,
  ["/loopwarp/transport"] = true
}
local status = {
  phase = 0,
  phase_time = 0,
  frames = 0,
  amp_l = 0,
  amp_r = 0,
  derived_bpm = 0
}
local mode_controls = {
  [1] = {
    {id = "loop_start", label = "st"},
    {id = "loop_end", label = "end"}
  },
  [2] = {
    {id = "loop_start", label = "st"},
    {id = "loop_end", label = "end"}
  },
  [3] = {
    {id = "chop_steps", label = "chop"},
    {id = "chop_loop_mode", label = "loop"}
  },
  [4] = {
    {id = "grain_size", label = "size"},
    {id = "grain_density", label = "dens"}
  },
  [5] = {
    {id = "wsola_window", label = "win"},
    {id = "wsola_search", label = "wnd"}
  },
  [6] = {
    {id = "pv_window", label = "win"},
    {id = "pv_dispersion", label = "disp"}
  }
}

local function format_args(args)
  local out = {}
  for i, value in ipairs(args or {}) do
    out[i] = tostring(value)
  end
  return table.concat(out, " ")
end

local function id(name)
  return PREFIX .. name
end

local function verbose_osc_logging()
  local param = params:lookup_param(id("debug"))
  return param ~= nil and params:get(id("debug")) >= 4
end

local function sample_name()
  local path = params:get(id("sample"))
  if path == nil or path == "-" or path == "" or path:sub(-1) == "/" then
    return "no sample"
  end
  return params:string(id("sample"))
end

local function parent_folder(path)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return nil
  end
  return path:match("^(.*[/\\])[^/\\]+$")
end

local function normalize_folder(path)
  if path == nil or path == "" then
    return nil
  end
  if path:sub(-1) ~= "/" then
    return path .. "/"
  end
  return path
end

local function state_file()
  browser_state_file = browser_state_file or (_path.data .. "loopwarp_test/browser_state.data")
  return browser_state_file
end

local function save_browser_folder(folder)
  folder = normalize_folder(folder)
  if folder == nil then
    return
  end

  last_sample_folder = folder
  util.make_dir(_path.data .. "loopwarp_test/")
  tab.save({sample_folder = folder}, state_file())
  print("loopwarp: sample browser folder " .. folder)
end

local function load_browser_folder()
  local sample_folder = normalize_folder(parent_folder(params:get(id("sample"))))
  if sample_folder ~= nil then
    last_sample_folder = sample_folder
    return
  end

  local data = tab.load(state_file())
  if type(data) == "table" then
    last_sample_folder = normalize_folder(data.sample_folder)
  end
end

local function browser_folder()
  return normalize_folder(parent_folder(params:get(id("sample")))) or last_sample_folder or _path.audio
end

local function folder_starts_with(folder, root)
  return folder ~= nil and root ~= nil and folder:sub(1, #root) == root
end

local function current_controls()
  return mode_controls[params:get(id("mode"))] or mode_controls[1]
end

local function option_value(param_id)
  local param = params:lookup_param(id(param_id))
  if param == nil or param.options == nil then
    return params:string(id(param_id))
  end
  return param.options[param:get()] or params:string(id(param_id))
end

local function short_mode()
  local mode = option_value("mode")
  if mode == "tempo_varispeed" then
    return "tempo"
  elseif mode == "granular" then
    return "grain"
  elseif mode == "pitch_corrected" then
    return "pc"
  elseif mode == "random_ola" then
    return "ola"
  end
  return mode
end

local function compact_value(param_id)
  local value = params:get(id(param_id))
  if param_id == "mode" then
    return short_mode()
  elseif param_id == "chop_loop_mode" then
    local mode = option_value(param_id)
    if mode == "forward stop" then
      return "stop"
    elseif mode == "loop forward" then
      return "loop"
    elseif mode == "ping pong" then
      return "pong"
    end
    return mode
  elseif param_id == "target_bpm" or param_id == "sample_bpm" then
    return tostring(math.floor(value + 0.5))
  elseif param_id == "sample_steps" or param_id == "grain_density" then
    return tostring(math.floor(value + 0.5))
  elseif param_id == "pitch" then
    return string.format("%.1f", value)
  elseif param_id == "loop_start" or param_id == "loop_end" then
    return string.format("%.0f", value)
  elseif param_id == "grain_size" or param_id == "grain_jitter"
    or param_id == "wsola_window" or param_id == "wsola_search"
    or param_id == "pv_window" then
    return tostring(math.floor((value * 1000) + 0.5))
  elseif param_id == "pv_dispersion" then
    return string.format("%.2f", value)
  elseif param_id == "chop_steps" then
    if math.abs(value - math.floor(value + 0.5)) < 0.001 then
      return tostring(math.floor(value + 0.5))
    end
    return string.format("%.2f", value)
  end
  return params:string(id(param_id))
end

local function draw_three_labels(a, b, c)
  screen.level(4)
  screen.move(0, 44)
  screen.text(a)
  screen.move(43, 44)
  screen.text(b)
  screen.move(86, 44)
  screen.text(c)
end

local function draw_three_values(a, b, c)
  screen.level(15)
  screen.move(0, 55)
  screen.text(a)
  screen.move(43, 55)
  screen.text(b)
  screen.move(86, 55)
  screen.text(c)
end

local function draw_two_pairs(left_label, left_value, right_label, right_value, y)
  screen.level(4)
  screen.move(0, y)
  screen.text(left_label)
  screen.level(15)
  screen.move(39, y)
  screen.text(left_value)

  screen.level(4)
  screen.move(73, y)
  screen.text(right_label)
  screen.level(15)
  screen.move(128, y)
  screen.text_right(right_value)
end

local function request_redraw()
  redraw_pending = true
end

local function loop_phase_rate()
  local start_point = params:get(id("loop_start")) or 0
  local end_point = params:get(id("loop_end")) or 128
  local region = math.max(0.01, end_point - start_point) / 128
  local steps = math.max(1, params:get(id("sample_steps")) or 16)
  local loop_beats = math.max(0.03125, (steps / 4) * region)

  if params:get(id("mode")) == 1 then
    local bpm = status.derived_bpm > 0 and status.derived_bpm or params:get(id("sample_bpm"))
    local pitch_ratio = math.pow(2, (params:get(id("pitch")) or 0) / 12)
    return (bpm / 60 / loop_beats) * pitch_ratio
  end

  return (params:get(id("target_bpm")) or 120) / 60 / loop_beats
end

local function display_phase()
  local phase = status.phase or 0
  if not playing then
    return phase
  end

  local elapsed = util.time() - (status.phase_time or util.time())
  return (phase + (elapsed * loop_phase_rate())) % 1
end

local function draw_playhead(y)
  local x0 = 4
  local x1 = 124
  local phase = util.clamp(display_phase(), 0, 1)
  local x = x0 + ((x1 - x0) * phase)

  screen.level(4)
  screen.move(x0, y)
  screen.line(x1, y)
  screen.stroke()

  screen.level(15)
  screen.move(x, y - 3)
  screen.line(x, y + 3)
  screen.stroke()
end

local function set_playing(state)
  playing = state
  status.phase_time = util.time()
  params:set(id("play"), playing and 1 or 0, true)
  print("loopwarp: K3/play state " .. tostring(playing and 1 or 0))
  loopwarp.play(playing)
  request_redraw()
end

local function load_file(path)
  print("loopwarp: file browser returned " .. tostring(path))
  browsing = false
  if path ~= "cancel" then
    save_browser_folder(parent_folder(path))
    set_playing(false)
    params:set(id("sample"), path)
  end
  request_redraw()
end

local function select_sample()
  local folder = browser_folder()
  set_playing(false)
  browsing = true
  if folder_starts_with(folder, _path.dust) then
    fileselect.enter(_path.dust, load_file, "audio")
    fileselect.pushd(folder)
  else
    fileselect.enter(_path.audio, load_file, "audio")
  end
end

local function start_redraw_metro()
  if redraw_metro ~= nil then
    redraw_metro:stop()
  end

  redraw_metro = metro.init(function()
    if not browsing and norns.menu.status() == false then
      if playing or redraw_pending then
        redraw_pending = false
        redraw()
      end
    end
  end, 1 / 12, -1)

  if redraw_metro ~= nil then
    redraw_metro:start()
  end
end

function init()
  loopwarp.params({
    prefix = PREFIX,
    name = "loopwarp test",
    clock_sync = false
  })
  load_browser_folder()

  loopwarp.log_engine_commands()
  osc.event = function(path, args, from)
    if path:sub(1, 9) == "/loopwarp" then
      if not quiet_osc_paths[path] or verbose_osc_logging() then
        print("loopwarp: osc " .. path .. " " .. format_args(args))
      end
      if path == "/loopwarp/status" then
        status.phase = tonumber(args[5]) or status.phase
        status.phase_time = util.time()
        status.frames = tonumber(args[6]) or status.frames
        status.amp_l = tonumber(args[7]) or status.amp_l
        status.amp_r = tonumber(args[8]) or status.amp_r
        status.derived_bpm = tonumber(args[10]) or status.derived_bpm
        if status.derived_bpm > 0 then
          params:set(id("source_bpm"), status.derived_bpm, true)
        end
      elseif path == "/loopwarp/transport" then
        status.phase = tonumber(args[1]) or status.phase
        status.phase_time = util.time()
      elseif path == "/loopwarp/requestedStatus" then
        status.phase = tonumber(args[4]) or status.phase
        status.phase_time = util.time()
        status.frames = tonumber(args[5]) or status.frames
        status.derived_bpm = tonumber(args[8]) or status.derived_bpm
        if status.derived_bpm > 0 then
          params:set(id("source_bpm"), status.derived_bpm, true)
        end
      elseif path == "/loopwarp/load/installed" then
        status.frames = tonumber(args[3]) or status.frames
        status.derived_bpm = tonumber(args[5]) or status.derived_bpm
      end
      if not browsing and not quiet_osc_paths[path] then
        request_redraw()
      end
    elseif previous_osc_event ~= nil then
      previous_osc_event(path, args, from)
    end
  end

  set_playing(false)
  start_redraw_metro()
  redraw()
end

function key(n, z)
  if n == 1 then
    alt = z == 1
    request_redraw()
    return
  end

  if z == 0 then
    return
  end

  if n == 2 and alt then
    params:delta(id("mode"), -1)
  elseif n == 3 and alt then
    params:delta(id("mode"), 1)
  elseif n == 2 then
    select_sample()
  elseif n == 3 then
    set_playing(not playing)
  end

  request_redraw()
end

function enc(n, d)
  if n == 1 and alt then
    params:delta(id("pitch"), d)
  elseif n == 2 and alt then
    params:delta(id("sample_steps"), d)
  elseif n == 3 and alt then
    params:delta(id("sample_bpm"), d)
  elseif n == 1 then
    params:delta(id("target_bpm"), d)
  elseif n == 2 then
    params:delta(id(current_controls()[1].id), d)
  elseif n == 3 then
    params:delta(id(current_controls()[2].id), d)
  end

  request_redraw()
end

function redraw()
  if browsing then
    return
  end

  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  screen.level(15)
  screen.move(0, 9)
  screen.text("LOOPWARP")

  screen.level(5)
  screen.move(128, 9)
  screen.text_right(playing and "PLAY" or "STOP")

  screen.level(15)
  screen.move(0, 21)
  screen.text_trim(sample_name(), 128)

  screen.level(4)
  screen.move(0, 33)
  screen.text("K2 sample  K3 play")

  if alt then
    draw_two_pairs("pitch", compact_value("pitch"), "mode", compact_value("mode"), 45)
    draw_two_pairs("steps", compact_value("sample_steps"), "src bpm", compact_value("sample_bpm"), 57)
  else
    local controls = current_controls()
    local left = controls[1]
    local right = controls[2]

    draw_three_labels("bpm", left.label, right.label)
    draw_three_values(compact_value("target_bpm"), compact_value(left.id), compact_value(right.id))
    draw_playhead(60)
  end

  screen.update()
end

function cleanup()
  if redraw_metro ~= nil then
    redraw_metro:stop()
    redraw_metro = nil
  end
  loopwarp.stop_param_throttle()
  loopwarp.stop_clock_sync()
  osc.event = previous_osc_event
  print("loopwarp: cleanup play 0")
  loopwarp.play(false)
end
