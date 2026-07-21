engine.name = "Elasticat"

local elasticat = include("lib/elasticat")
local GridSequencer = include("lib/grid_sequencer")
local ParamItem = include("lib/ui/param_item")
local ParamRenderer = include("lib/ui/param_renderer")
local Header = include("lib/ui/header")
local MachineRegistry = include("lib/machines/registry")
local WarpRegistry = include("lib/warp_modes/registry")
local WavReader = include("lib/wav_reader")
local ScriptState = include("lib/script_state")
local Navigation = include("lib/pages/navigation")
local ParamValues = include("lib/ui/param_values")
local SourcePage = include("lib/ui/source_page")
local fileselect = require "fileselect"

local PREFIX = "elasticat_"
local playing = false
local alt = false
local browsing = false
local redraw_metro = nil
local redraw_pending = true
local grid_ui = nil
local ui_message = nil
local ui_message_clock = nil
local loop_trig_gate_clock = nil
local loop_trig_gate_token = 0
local previous_osc_event = osc.event
local select_sample = nil
local nav = nil
local param_values = nil
local quiet_osc_paths = {
  ["/elasticat/status"] = true,
  ["/elasticat/transport"] = true,
  ["/elasticat/pool/slot/active"] = true
}
local status = {
  phase = 0,
  phase_time = 0,
  frames = 0,
  amp_l = 0,
  amp_r = 0,
  derived_bpm = 0
}
local phase_report_ignore_until = 0
local active_step_lock_bases = {}
local active_step_lock_ids = {}
local default_trig_length = 1
local default_trig_velocity = 1
local sample_waveforms = {}
local value_flash_until = {}
local last_trim_focus = "trim_start"
local VALUE_FLASH_SECONDS = 0.85
local WAVEFORM_BUCKETS = 126
local SOURCE_CELL_X = {1, 33, 65, 97}
local SOURCE_CELL_WIDTH = 31
local SOURCE_CELL_HEIGHT = 11
local SOURCE_TOP_Y = 11
local SOURCE_WAVEFORM_Y = 23
local SOURCE_WAVEFORM_HEIGHT = 27
local SOURCE_BOTTOM_Y = 53

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

local script_state = ScriptState.new({id = id, elasticat = elasticat})

local function verbose_osc_logging()
  local param = params:lookup_param(id("debug"))
  return param ~= nil and params:get(id("debug")) >= 4
end

local function sample_name()
  if elasticat.pool_label ~= nil then
    return elasticat.pool_label(elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot() or nil)
  end

  local path = params:get(id("sample"))
  if path == nil or path == "-" or path == "" or path:sub(-1) == "/" then
    return "no sample"
  end
  return params:string(id("sample"))
end


local function cache_sample_waveform(slot, path)
  slot = math.floor((tonumber(slot) or 1) + 0.5)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    sample_waveforms[slot] = nil
    return
  end
  sample_waveforms[slot] = WavReader.read_wav_waveform(path, WAVEFORM_BUCKETS) or WavReader.fallback_waveform(path, WAVEFORM_BUCKETS)
end

local function active_waveform()
  local slot = elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot() or 1
  local waveform = sample_waveforms[slot]
  local path = elasticat.pool_path ~= nil and elasticat.pool_path(slot) or nil
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return nil
  end
  if waveform == nil and elasticat.pool_path ~= nil then
    if not playing or not param_values.applying_step_locks then
      cache_sample_waveform(slot, path)
      waveform = sample_waveforms[slot]
    else
      return WavReader.fallback_waveform(path, WAVEFORM_BUCKETS)
    end
  end
  return waveform
end

local function request_redraw()
  redraw_pending = true
end

local function set_visual_phase(phase)
  if phase ~= nil then
    status.phase = util.clamp(tonumber(phase) or status.phase, 0, 1)
  end
  status.phase_time = util.time()
end

local function reset_visual_phase()
  set_visual_phase(0)
  phase_report_ignore_until = util.time() + 1
end

local function phase_reports_allowed()
  return (not playing) and util.time() >= phase_report_ignore_until
end

local function machine_is_continuous()
  local machine_param = params:lookup_param(id("machine"))
  return machine_param == nil or params:get(id("machine")) == 1
end

local function show_message(text)
  ui_message = text
  if ui_message_clock ~= nil then
    clock.cancel(ui_message_clock)
  end
  ui_message_clock = clock.run(function()
    clock.sleep(1)
    ui_message = nil
    ui_message_clock = nil
    request_redraw()
  end)
  request_redraw()
end

local function visible_message()
  return ui_message
end

local function param_value_or(param_id, default)
  local full_id = id(param_id)
  if params:lookup_param(full_id) ~= nil then
    return params:get(full_id)
  end
  return default
end

local function source_sample_items()
  return MachineRegistry.source_items(param_value_or("machine", 1), ParamItem)
end

local function source_machine_items()
  return MachineRegistry.machine_items(param_value_or("machine", 1), ParamItem)
end

local function source_warp_items()
  return WarpRegistry.source_items(param_value_or("mode", 1), ParamItem)
end

local function page_items_for(category, page, page_index)
  if category == "source" and page_index == 1 then
    return source_sample_items()
  elseif category == "source" and page_index == 2 then
    local machine_items = MachineRegistry.source_page2_items(param_value_or("machine", 1), ParamItem)
    if machine_items ~= nil then
      return machine_items
    end
    return source_warp_items()
  elseif category == "source" and page_index == 4 then
    return source_machine_items()
  end
  return page.items or {}
end

nav = Navigation.new({
  page_items_for = page_items_for,
  show_message = show_message,
  request_redraw = request_redraw,
  on_navigate = function()
    if elasticat.flush_dirty_pool_state ~= nil then
      elasticat.flush_dirty_pool_state()
    end
  end
})

param_values = ParamValues.new({
  id = id,
  show_message = show_message,
  sample_name = sample_name,
  param_value_or = param_value_or,
  get_grid_ui = function() return grid_ui end,
  get_alt = function() return alt end,
  get_select_sample = function() return select_sample end,
  get_default_trig_length = function() return default_trig_length end,
  set_default_trig_length = function(v) default_trig_length = v end,
  get_default_trig_velocity = function() return default_trig_velocity end,
  set_default_trig_velocity = function(v) default_trig_velocity = v end,
  set_last_trim_focus = function(v) last_trim_focus = v end,
  active_step_lock_bases = active_step_lock_bases,
  active_step_lock_ids = active_step_lock_ids,
  value_flash_until = value_flash_until,
  value_flash_seconds = VALUE_FLASH_SECONDS
})

local function clear_lock_for_slot(slot, all_steps)
  local param_item = ({nav:current_group_items()})[slot]
  if param_item == nil or param_item.lockable ~= true or grid_ui == nil then
    return false
  end

  local lock_id = param_item.lock_id or param_item.id
  local did_clear
  if all_steps then
    did_clear = grid_ui:clear_all_param_locks(lock_id)
  else
    did_clear = grid_ui:clear_held_param_lock(lock_id)
  end
  if did_clear then
    show_message(param_values:item_long_name(param_item) .. " lock clear")
    request_redraw()
  end
  return did_clear
end

local function settings_delta_value(delta)
  local items = nav:settings_items()
  local index = nav.settings_item_index[nav:current_settings_category()] or 1
  local param_item = items[index]
  if param_item == nil then
    return
  end
  local current = param_values:item_raw_value(param_item)
  param_values:apply_item_value(param_item, param_values:adjusted_value(param_item, current, delta, false))
  param_values:flash_item_value(param_item)
  show_message(param_values:item_long_name(param_item) .. " " .. param_values:item_display_value(param_item))
  request_redraw()
end

local function pset_path(n)
  return norns.state.data .. norns.state.shortname .. "-" .. string.format("%02d", n) .. ".pset"
end

local function load_startup_pset()
  local path = pset_path(1)
  if util.file_exists(path) then
    print("elasticat: loading startup pset 1")
    params:read(1)
  end
end

local function active_region()
  if grid_ui ~= nil and grid_ui.active_region ~= nil then
    return grid_ui:active_region()
  end
  return params:get(id("loop_start")) or 0, params:get(id("loop_end")) or 128
end

local function visual_param_value(param_id, fallback)
  local lock_id = param_id
  local step_edit = grid_ui ~= nil and grid_ui.screen_edit ~= nil and grid_ui:screen_edit() or nil
  if step_edit ~= nil and grid_ui.held_param_lock ~= nil then
    local held = grid_ui:held_param_lock(lock_id)
    if held ~= nil then
      return held
    end
  end
  if active_step_lock_bases[lock_id] ~= nil then
    return active_step_lock_bases[lock_id]
  end
  return params:lookup_param(id(param_id)) ~= nil and params:get(id(param_id)) or fallback
end

local function loop_phase_rate(start_point, end_point)
  start_point = start_point or params:get(id("loop_start")) or 0
  end_point = end_point or params:get(id("loop_end")) or 128
  local region = math.max(0.01, end_point - start_point) / 128
  local steps = math.max(1, params:get(id("sample_steps")) or 16)
  local loop_beats = math.max(0.03125, (steps / 4) * region)

  if params:get(id("machine")) == 1 then
    local bpm = status.derived_bpm > 0 and status.derived_bpm or params:get(id("sample_bpm"))
    local pitch_ratio = math.pow(2, (params:get(id("pitch")) or 0) / 12)
    return (bpm / 60 / loop_beats) * pitch_ratio
  end

  return (params:get(id("target_bpm")) or 120) / 60 / loop_beats
end

local function display_phase()
  local phase = status.phase or 0
  local previewing = grid_ui ~= nil and grid_ui.preview_active == true
  if not playing and not previewing then
    return phase
  end

  local elapsed = util.time() - (status.phase_time or util.time())
  local start_point, end_point = active_region()
  return (phase + (elapsed * loop_phase_rate(start_point, end_point))) % 1
end

local function position_at_region(start_point, end_point, at_time)
  local elapsed = (at_time or util.time()) - (status.phase_time or util.time())
  local unwrapped = (status.phase or 0) + (elapsed * loop_phase_rate(start_point, end_point))
  local nearest = math.floor(unwrapped + 0.5)
  local phase
  if nearest == 1 and math.abs(unwrapped - nearest) < 0.01 then
    phase = 1
  else
    phase = unwrapped % 1
  end
  return start_point + ((end_point - start_point) * phase)
end

local function draw_page_header(title, page_number)
  local grid_status = nil
  if grid_ui ~= nil and grid_ui.screen_status ~= nil then
    grid_status = grid_ui:screen_status()
  end

  Header.draw({
    track = 1,
    message = visible_message() or grid_status or title or "ELASTICAT",
    tempo = param_value_or("target_bpm", 120),
    amp_l = status.amp_l,
    amp_r = status.amp_r,
    page = page_number or 1
  })
end

local function draw_selection_corner(x, y, width, height, corner)
  ParamRenderer.draw_selection_corner(x, y, width, height, corner)
end

local function draw_param_cell(param_item, x, y, corner)
  ParamRenderer.draw_param_cell(param_item, x, y, corner,
    function(pi) return param_values:item_locked(pi) end,
    function(pi) return param_values:item_display_value(pi) end)
end

local source_page = SourcePage.new({
  elasticat = elasticat,
  MachineRegistry = MachineRegistry,
  ParamRenderer = ParamRenderer,
  param_values = param_values,
  nav = nav,
  param_value_or = param_value_or,
  sample_name = sample_name,
  draw_page_header = draw_page_header,
  active_waveform = active_waveform,
  active_region = active_region,
  display_phase = display_phase,
  visual_param_value = visual_param_value,
  id = id,
  get_alt = function() return alt end,
  get_last_trim_focus = function() return last_trim_focus end
})

local function draw_root_page()
  local page, page_index, model = nav:current_page()
  local title = page.title or model.title or "ELASTICAT"
  local items = page_items_for(nav:current_category(), page, page_index)

  if nav:current_category() == "source" and (page_index == 1 or page_index == 3) then
    source_page:draw_sample_page(page, items)
    return
  end

  draw_page_header(title, page_index)
  if #items == 0 then
    screen.level(4)
    screen.move(0, 34)
    screen.text("empty")
    return
  end

  local selected_start = ((nav:clamp_current_group() - 1) * 2) + 1
  for i, param_item in ipairs(items) do
    local column = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    local x = column * 32
    local y = row == 0 and 18 or 44
    local corner = nil
    if i == selected_start then
      corner = "tl"
    elseif i == selected_start + 1 then
      corner = "br"
    end
    draw_param_cell(param_item, x, y, corner)
  end

end

local function draw_settings_page()
  local category = nav:current_settings_category()
  local model = nav:category_model(category)
  draw_page_header((model.title or category) .. " SETTINGS", 1)

  local items = nav:settings_items()
  if #items == 0 then
    screen.level(4)
    screen.move(0, 34)
    screen.text("empty")
    return
  end

  local selected = util.clamp(nav.settings_item_index[category] or 1, 1, #items)
  nav.settings_item_index[category] = selected
  local first = util.clamp(selected - 2, 1, math.max(1, #items - 4))

  for row = 0, 4 do
    local index = first + row
    local param_item = items[index]
    if param_item ~= nil then
      local y = 20 + (row * 9)
      screen.level(index == selected and 15 or 5)
      screen.move(0, y)
      screen.text(index == selected and ">" or " ")
      screen.move(10, y)
      screen.text_trim(param_item.short or param_item.id, 42)
      screen.move(128, y)
      screen.text_right(param_values:item_display_value(param_item))
    end
  end
end

local function set_playing(state, reset_transport)
  reset_transport = reset_transport == true
  local frozen_phase = playing and display_phase() or status.phase
  if not state and loop_trig_gate_clock ~= nil then
    clock.cancel(loop_trig_gate_clock)
    loop_trig_gate_clock = nil
    loop_trig_gate_token = loop_trig_gate_token + 1
  end
  playing = state
  if reset_transport then
    reset_visual_phase()
  elseif not playing then
    set_visual_phase(frozen_phase)
  else
    status.phase_time = util.time()
  end
  params:set(id("play"), playing and 1 or 0, true)
  print("elasticat: K3/play state " .. tostring(playing and 1 or 0))
  if not reset_transport then
    elasticat.play(playing and machine_is_continuous())
  end
  if grid_ui ~= nil then
    grid_ui:set_transport(playing, reset_transport)
  end
  if reset_transport then
    elasticat.stop_reset()
    reset_visual_phase()
  end
  request_redraw()
end

local function trigger_loop_region(start_point, end_point, options)
  if loop_trig_gate_clock ~= nil then
    clock.cancel(loop_trig_gate_clock)
    loop_trig_gate_clock = nil
  end

  loop_trig_gate_token = loop_trig_gate_token + 1
  local token = loop_trig_gate_token
  elasticat.set_loop_region(start_point, end_point, 0)
  elasticat.play(true)

  local length_seconds = options.length_seconds or 0
  if length_seconds > 0 then
    loop_trig_gate_clock = clock.run(function()
      clock.sleep(length_seconds)
      if token == loop_trig_gate_token and playing and params:get(id("machine")) == 2 then
        elasticat.play(false)
      end
    end)
  end
end

local function load_file(path)
  print("elasticat: file browser returned " .. tostring(path))
  browsing = false
  if path ~= "cancel" then
    script_state:save_browser_folder(ScriptState.parent_folder(path))
    if elasticat.load_pool_slot ~= nil then
      local slot = elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot() or param_value_or("sample_slot", 1)
      elasticat.load_pool_slot(slot, path, true)
    else
      params:set(id("sample"), path)
    end
    value_flash_until.sample = util.time() + VALUE_FLASH_SECONDS
  end
  request_redraw()
end

local function enter_sample_browser(root)
  fileselect.enter(root, load_file, "audio")
  local browser_enc = enc
  enc = function(n, d)
    if n == 3 and playing then
      return
    end
    if browser_enc ~= nil then
      browser_enc(n, d)
    end
  end
end

select_sample = function()
  local folder = script_state:browser_folder()
  browsing = true
  if ScriptState.folder_starts_with(folder, _path.dust) then
    enter_sample_browser(_path.dust)
    fileselect.pushd(folder)
  else
    enter_sample_browser(_path.audio)
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
    if grid_ui ~= nil then
      grid_ui:redraw()
    end
  end, 1 / 30, -1)

  if redraw_metro ~= nil then
    redraw_metro:start()
  end
end

function init()
  elasticat.params({
    prefix = PREFIX,
    name = "elasticat",
    clock_sync = false,
    on_pool_change = function(snapshot, slot, path)
      if path ~= nil then
        cache_sample_waveform(slot, path)
      end
      if not param_values.applying_step_locks then
        script_state:save_sample_pool_state(snapshot)
      end
      request_redraw()
    end,
    on_sample_slot = function(slot, path)
      if path ~= nil and sample_waveforms[slot] == nil and (not playing or not param_values.applying_step_locks) then
        cache_sample_waveform(slot, path)
      end
      if not param_values.applying_step_locks then
        script_state:save_sample_pool_state()
      end
      request_redraw()
    end
  })
  load_startup_pset()
  script_state:load_sample_pool_state()
  script_state:load_browser_folder()
  grid_ui = GridSequencer.new({
    set_playing = set_playing,
    set_loop_region = function(start_point, end_point, reset_playhead)
      elasticat.set_loop_region(start_point, end_point, reset_playhead)
      if type(reset_playhead) == "number" then
        set_visual_phase(reset_playhead)
      elseif reset_playhead then
        set_visual_phase(0)
      end
    end,
    base_region = function()
      return params:get(id("loop_start")), params:get(id("loop_end"))
    end,
    get_machine = function()
      return params:get(id("machine"))
    end,
    get_pattern_steps = function()
      return params:get(id("pattern_steps"))
    end,
    get_loop_division = function()
      return params:get(id("loop_division"))
    end,
    get_trig_polyphony = function()
      return params:get(id("trig_polyphony"))
    end,
    get_live_performance_mode = function()
      return params:get(id("live_performance_mode")) == 1
    end,
    get_step_preview = function()
      return params:get(id("step_preview")) == 1
    end,
    get_playhead_return = function()
      return params:get(id("playhead_return"))
    end,
    play = function(state)
      elasticat.play(state)
    end,
    get_slice_count = function()
      return params:get(id("slice_count"))
    end,
    get_slice_index = function()
      return params:get(id("slice_index"))
    end,
    get_slice_play_mode = function()
      return params:get(id("slice_play_mode"))
    end,
    get_slice_polyphony = function()
      return params:get(id("slice_polyphony"))
    end,
    get_hold_to_step = function()
      return params:get(id("slice_hold_to_step")) == 1
    end,
    get_slice_hold = function()
      return params:get(id("slice_hold"))
    end,
    get_slice_range = function(slice)
      if params:get(id("machine")) == 4 then
        local start_point = params:get(id(string.format("razor_%02d_start", slice)))
        local end_point = params:get(id(string.format("razor_%02d_end", slice)))
        if end_point <= start_point then
          end_point = math.min(start_point + 0.01, 128)
        end
        return start_point, end_point
      end
      local count = math.max(1, params:get(id("slice_count")))
      local loop_start = params:get(id("loop_start"))
      local loop_end = params:get(id("loop_end"))
      local width = (loop_end - loop_start) / count
      return loop_start + ((slice - 1) * width), loop_start + (slice * width)
    end,
    get_tempo = function()
      return params:get(id("target_bpm"))
    end,
    get_default_velocity = function()
      return param_value_or("default_velocity", default_trig_velocity)
    end,
    get_default_length = function()
      return param_value_or("default_length", default_trig_length)
    end,
    base_pitch = function()
      return params:get(id("pitch"))
    end,
    set_pitch = function(pitch)
      elasticat.set_pitch(pitch)
    end,
    set_pitch_param = function(pitch)
      params:set(id("pitch"), pitch)
    end,
    trigger_region = function(start_point, end_point, options)
      trigger_loop_region(start_point, end_point, options)
    end,
    trigger_slice = function(slice, start_point, end_point, options)
      elasticat.trigger_slice(
        slice,
        start_point,
        end_point,
        params:get(id("slice_play_mode")) - 1,
        params:get(id("slice_reverse")) == 1,
        options.velocity,
        options.length_seconds,
        options.pitch
      )
    end,
    release_slice = function(slice)
      elasticat.release_slice(slice)
    end,
    release_all_slices = function()
      elasticat.release_all_slices()
    end,
    apply_step_param_locks = function(locks)
      param_values:apply_step_param_locks(locks)
    end,
    current_param_category = function()
      return nav:current_category()
    end,
    select_param_category = function(category)
      nav:select_category(category)
    end,
    select_param_page_delta = function(delta)
      nav:select_page_delta(delta)
    end,
    open_param_settings = function(category)
      nav:open_param_settings(category)
    end,
    close_param_settings = function()
      nav:close_param_settings()
    end,
    return_to_param_category = function(category)
      nav:return_to_param_category(category)
    end,
    param_settings_active = function()
      return nav.settings_layer
    end,
    param_settings_select_delta = function(delta)
      nav:settings_select_delta(delta)
    end,
    param_settings_value_delta = settings_delta_value,
    phase = display_phase,
    position_at_region = position_at_region,
    show_message = show_message,
    request_redraw = request_redraw
  })

  elasticat.log_engine_commands()
  osc.event = function(path, args, from)
    if path:sub(1, #"/elasticat") == "/elasticat" then
      if not quiet_osc_paths[path] or verbose_osc_logging() then
        print("elasticat: osc " .. path .. " " .. format_args(args))
      end
      if path == "/elasticat/status" then
        if phase_reports_allowed() then
          set_visual_phase(args[5])
        end
        status.frames = tonumber(args[6]) or status.frames
        status.amp_l = tonumber(args[7]) or status.amp_l
        status.amp_r = tonumber(args[8]) or status.amp_r
        status.derived_bpm = tonumber(args[10]) or status.derived_bpm
        if status.derived_bpm > 0 then
          params:set(id("source_bpm"), status.derived_bpm, true)
        end
      elseif path == "/elasticat/transport" then
        if phase_reports_allowed() then
          set_visual_phase(args[1])
        end
      elseif path == "/elasticat/reset" then
        reset_visual_phase()
      elseif path == "/elasticat/requestedStatus" then
        if phase_reports_allowed() then
          set_visual_phase(args[4])
        end
        status.frames = tonumber(args[5]) or status.frames
        status.derived_bpm = tonumber(args[8]) or status.derived_bpm
        if status.derived_bpm > 0 then
          params:set(id("source_bpm"), status.derived_bpm, true)
        end
      elseif path == "/elasticat/load/installed" then
        status.frames = tonumber(args[3]) or status.frames
        status.derived_bpm = tonumber(args[5]) or status.derived_bpm
        if status.derived_bpm > 0 then
          params:set(id("source_bpm"), status.derived_bpm, true)
        end
      elseif path == "/elasticat/pool/slot/active" then
        status.frames = tonumber(args[2]) or status.frames
      end
      if not browsing and not quiet_osc_paths[path] then
        request_redraw()
      end
    elseif previous_osc_event ~= nil then
      previous_osc_event(path, args, from)
    end
  end

  set_playing(false, true)
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

  if nav.settings_layer then
    if n == 2 then
      nav:settings_select_delta(-1)
    elseif n == 3 then
      nav:settings_select_delta(1)
    end
    return
  end

  local step_edit = grid_ui ~= nil and grid_ui.screen_edit ~= nil and grid_ui:screen_edit() or nil
  if n == 2 or n == 3 then
    local slot = n == 2 and 1 or 2
    if step_edit ~= nil then
      clear_lock_for_slot(slot, false)
      return
    elseif alt then
      clear_lock_for_slot(slot, true)
      return
    end

    local delta = n == 2 and -1 or 1
    nav:cycle_group(delta)
    request_redraw()
  end

  request_redraw()
end

function enc(n, d)
  if n == 1 and alt then
    if d > 0 then
      nav:open_param_settings(nav:current_category())
    elseif d < 0 then
      nav:close_param_settings()
    end
  elseif nav.settings_layer then
    if n == 1 then
      nav:settings_category_delta(d)
    elseif n == 2 then
      nav:settings_select_delta(d)
    elseif n == 3 then
      settings_delta_value(d)
    end
  elseif n == 1 then
    nav:select_global_page_delta(d)
  elseif n == 2 then
    local left = nav:current_group_items()
    param_values:delta_item(left, d)
  elseif n == 3 then
    local _, right = nav:current_group_items()
    param_values:delta_item(right, d)
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

  if nav.settings_layer then
    draw_settings_page()
  else
    draw_root_page()
  end

  screen.update()
end

function cleanup()
  if elasticat.flush_dirty_pool_state ~= nil then
    elasticat.flush_dirty_pool_state()
  end
  if ui_message_clock ~= nil then
    clock.cancel(ui_message_clock)
    ui_message_clock = nil
  end
  if loop_trig_gate_clock ~= nil then
    clock.cancel(loop_trig_gate_clock)
    loop_trig_gate_clock = nil
  end
  if grid_ui ~= nil then
    grid_ui:cleanup()
    grid_ui = nil
  end
  if redraw_metro ~= nil then
    redraw_metro:stop()
    redraw_metro = nil
  end
  elasticat.stop_param_throttle()
  elasticat.stop_clock_sync()
  osc.event = previous_osc_event
  print("elasticat: cleanup play 0")
  elasticat.play(false)
end
