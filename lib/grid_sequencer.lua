local GridSequencer = {}
GridSequencer.__index = GridSequencer

local PAGE_MODES = {"select", "loop", "rate"}
local PAGE_MODE_LABELS = {
  select = "Page Select",
  loop = "Page Loop",
  rate = "Pattern Rate"
}
local RATES = {0.125, 0.25, 0.5, 1, 2, 4, 8, 16}
local LOOP_UNITS_PER_KEY = 8
local STEP_HOLD_SECONDS = 0.25

local function any_keys(t)
  for _, held in pairs(t) do
    if held then
      return true
    end
  end
  return false
end

local function sorted_held_keys(t)
  local keys = {}
  for x, held in pairs(t) do
    if held then
      table.insert(keys, x)
    end
  end
  table.sort(keys)
  return keys
end

local function rate_label(rate)
  if rate < 1 then
    return string.format("%.3gx", rate)
  end
  return string.format("%gx", rate)
end

local function format_region(start_point, end_point)
  return string.format("st %03.0f end %03.0f", start_point, end_point)
end

function GridSequencer.new(options)
  local self = setmetatable({}, GridSequencer)
  self.options = options or {}
  self.g = grid.connect()
  self.page_mode = "select"
  self.selected_page = 1
  self.play_page = 1
  self.play_step = 1
  self.playing = false
  self.recording = false
  self.fn_down = false
  self.page_down = false
  self.pressed = {}
  self.loop_holds = {}
  self.step_holds = {}
  self.step_press_time = {}
  self.step_edited = {}
  self.page_loop = {}
  self.page_loop[1] = true
  self.rate_index = 4
  self.step_locks = {}
  self.manual_region = nil
  self.seq_metro = nil
  self.next_step_time = nil
  self.seq_remaining_time = nil
  self.current_region_start = nil
  self.current_region_end = nil
  self.g.key = function(x, y, z) self:key(x, y, z) end
  return self
end

function GridSequencer:cleanup()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
    self.seq_metro = nil
  end
  if self.g ~= nil then
    self.g:all(0)
    self.g:refresh()
    self.g.key = nil
  end
end

function GridSequencer:message(text)
  if self.options.show_message ~= nil then
    self.options.show_message(text)
  end
end

function GridSequencer:request_redraw()
  if self.options.request_redraw ~= nil then
    self.options.request_redraw()
  end
end

function GridSequencer:base_region()
  if self.options.base_region ~= nil then
    return self.options.base_region()
  end
  return 0, 128
end

function GridSequencer:region_is_current(start_point, end_point)
  return self.current_region_start ~= nil
    and math.abs(self.current_region_start - start_point) < 0.0001
    and math.abs(self.current_region_end - end_point) < 0.0001
end

function GridSequencer:mark_region_current(start_point, end_point)
  self.current_region_start = start_point
  self.current_region_end = end_point
end

function GridSequencer:set_region(start_point, end_point)
  if self:region_is_current(start_point, end_point) then
    return
  end
  if self.options.set_loop_region ~= nil then
    self.options.set_loop_region(start_point, end_point)
  end
  self:mark_region_current(start_point, end_point)
end

function GridSequencer:set_region_and_phase(start_point, end_point)
  if self.options.set_loop_region ~= nil then
    self.options.set_loop_region(start_point, end_point, true)
  end
  self:mark_region_current(start_point, end_point)
end

function GridSequencer:set_region_with_phase(start_point, end_point, phase)
  if self.options.set_loop_region ~= nil then
    self.options.set_loop_region(start_point, end_point, phase)
  end
  self:mark_region_current(start_point, end_point)
end

function GridSequencer:reset_region()
  local start_point, end_point = self:base_region()
  self:set_region(start_point, end_point)
end

function GridSequencer:phase_for_position(start_point, end_point, position)
  local range = math.max(0.01, end_point - start_point)
  return ((position - start_point) / range) % 1
end

function GridSequencer:position_at_region(start_point, end_point, at_time)
  if self.options.position_at_region ~= nil then
    return self.options.position_at_region(start_point, end_point, at_time)
  end
  local phase = self.options.phase ~= nil and (self.options.phase() or 0) or 0
  return start_point + ((end_point - start_point) * phase)
end

function GridSequencer:loop_region_from_holds(holds)
  local keys = sorted_held_keys(holds)
  if #keys == 0 then
    return nil
  end

  local start_point = math.min((keys[1] - 1) * LOOP_UNITS_PER_KEY, 127)
  local end_point = math.min(keys[#keys] * LOOP_UNITS_PER_KEY, 128)
  if end_point <= start_point then
    end_point = math.min(start_point + LOOP_UNITS_PER_KEY, 128)
  end
  return start_point, end_point
end

function GridSequencer:step_lock(page, step)
  self.step_locks[page] = self.step_locks[page] or {}
  return self.step_locks[page][step]
end

function GridSequencer:set_step_lock(page, step, start_point, end_point)
  self.step_locks[page] = self.step_locks[page] or {}
  self.step_locks[page][step] = {
    start_point = start_point,
    end_point = end_point
  }
end

function GridSequencer:clear_step_lock(page, step)
  if self.step_locks[page] ~= nil then
    self.step_locks[page][step] = nil
  end
end

function GridSequencer:lock_held_steps(start_point, end_point)
  local did_lock = false
  for step, held in pairs(self.step_holds) do
    if held then
      self:set_step_lock(self.selected_page, step, start_point, end_point)
      self.step_edited[step] = true
      did_lock = true
    end
  end
  if did_lock then
    self:message(string.format("Step %02d Lock", self:first_held_step() or 1))
  end
  return did_lock
end

function GridSequencer:first_held_step()
  for step = 1, 16 do
    if self.step_holds[step] then
      return step
    end
  end
  return nil
end

function GridSequencer:apply_current_region(reset_locked_step, restore_position)
  if self.manual_region ~= nil then
    return
  end

  local lock = self:step_lock(self.play_page, self.play_step)
  if self.playing and lock ~= nil then
    if reset_locked_step then
      self:set_region_and_phase(lock.start_point, lock.end_point)
    else
      self:set_region(lock.start_point, lock.end_point)
    end
  else
    local start_point, end_point = self:base_region()
    if restore_position ~= nil then
      self:set_region_with_phase(start_point, end_point, self:phase_for_position(start_point, end_point, restore_position))
    else
      self:set_region(start_point, end_point)
    end
  end
end

function GridSequencer:start_current_region()
  if self.manual_region ~= nil then
    return
  end

  local lock = self:step_lock(self.play_page, self.play_step)
  if self.playing and lock ~= nil then
    self:set_region_and_phase(lock.start_point, lock.end_point)
  else
    local start_point, end_point = self:base_region()
    self:set_region_with_phase(start_point, end_point, 0)
  end
end

function GridSequencer:first_loop_page()
  for page = 1, 16 do
    if self.page_loop[page] then
      return page
    end
  end
  self.page_loop[1] = true
  return 1
end

function GridSequencer:next_loop_page(page)
  local count = 0
  for loop_page = 1, 16 do
    if self.page_loop[loop_page] then
      count = count + 1
    end
  end
  if count < 2 then
    return self:first_loop_page()
  end

  for offset = 1, 16 do
    local next_page = ((page - 1 + offset) % 16) + 1
    if self.page_loop[next_page] then
      return next_page
    end
  end
  return self:first_loop_page()
end

function GridSequencer:current_rate()
  return RATES[self.rate_index] or 1
end

function GridSequencer:current_bpm()
  if self.options.get_tempo ~= nil then
    return math.max(1, self.options.get_tempo() or 120)
  end
  if clock.get_tempo ~= nil then
    return math.max(1, clock.get_tempo())
  end
  return 120
end

function GridSequencer:step_seconds()
  return 60 / self:current_bpm() / 4 / self:current_rate()
end

function GridSequencer:metro_interval()
  return util.clamp(self:step_seconds() / 2, 0.005, 0.05)
end

function GridSequencer:ensure_sequence_metro()
  if self.seq_metro == nil then
    self.seq_metro = metro.init(function()
      self:tick_sequence()
    end, self:metro_interval(), -1)
  end
  return self.seq_metro
end

function GridSequencer:start_sequence(reset_sequence)
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  self.playing = true
  if self.seq_remaining_time ~= nil and not reset_sequence then
    self.next_step_time = util.time() + self.seq_remaining_time
    self.seq_remaining_time = nil
    self:apply_current_region(false)
  else
    self.seq_remaining_time = nil
    self.play_page = self:first_loop_page()
    self.play_step = 1
    self:start_current_region()
    self.next_step_time = util.time() + self:step_seconds()
  end
  local seq_metro = self:ensure_sequence_metro()
  if seq_metro ~= nil then
    seq_metro:start(self:metro_interval(), -1)
  end
  self:request_redraw()
end

function GridSequencer:pause_sequence()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  if self.next_step_time ~= nil then
    self.seq_remaining_time = math.max(0.001, self.next_step_time - util.time())
  end
  self.next_step_time = nil
  self:request_redraw()
end

function GridSequencer:stop_sequence()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  self.next_step_time = nil
  self.seq_remaining_time = nil
  self.play_step = 1
  self.play_page = self:first_loop_page()
  local start_point, end_point = self:base_region()
  self:set_region_with_phase(start_point, end_point, 0)
  self:request_redraw()
end

function GridSequencer:set_transport(playing, reset_sequence)
  if playing then
    self:start_sequence(reset_sequence == true)
  elseif reset_sequence then
    self:stop_sequence()
  else
    self:pause_sequence()
  end
end

function GridSequencer:tick_sequence()
  if not self.playing then
    if self.seq_metro ~= nil then
      self.seq_metro:stop()
    end
    return
  end

  local now = util.time()
  if self.next_step_time == nil then
    self.next_step_time = now + self:step_seconds()
  end

  local advanced = false
  local guard = 0
  while self.playing and now >= self.next_step_time and guard < 8 do
    self:advance_step()
    self.next_step_time = self.next_step_time + self:step_seconds()
    advanced = true
    guard = guard + 1
  end

  if advanced and self.next_step_time < now then
    self.next_step_time = now + self:step_seconds()
  end

  if self.seq_metro ~= nil then
    self.seq_metro.time = self:metro_interval()
  end
end

function GridSequencer:advance_step()
  local prev_lock = self.playing and self:step_lock(self.play_page, self.play_step) or nil
  local restore_position = nil
  if prev_lock ~= nil then
    restore_position = self:position_at_region(
      prev_lock.start_point,
      prev_lock.end_point,
      self.next_step_time or util.time()
    )
  end

  self.play_step = self.play_step + 1
  if self.play_step > 16 then
    self.play_step = 1
    self.play_page = self:next_loop_page(self.play_page)
  end

  local lock = self:step_lock(self.play_page, self.play_step)
  if lock ~= nil then
    restore_position = nil
  end
  self:apply_current_region(true, restore_position)
  self:request_redraw()
end

function GridSequencer:screen_status()
  if self.manual_region ~= nil then
    return "temp " .. format_region(self.manual_region.start_point, self.manual_region.end_point)
  end

  local held_step = self:first_held_step()
  if held_step ~= nil then
    local lock = self:step_lock(self.selected_page, held_step)
    if lock ~= nil then
      return string.format("step %02d %s", held_step, format_region(lock.start_point, lock.end_point))
    end
    return string.format("step %02d empty", held_step)
  end

  return nil
end

function GridSequencer:active_region()
  if self.manual_region ~= nil then
    return self.manual_region.start_point, self.manual_region.end_point
  end

  local lock = self:step_lock(self.play_page, self.play_step)
  if self.playing and lock ~= nil then
    return lock.start_point, lock.end_point
  end

  return self:base_region()
end

function GridSequencer:handle_page_step(x)
  if self.page_mode == "select" then
    self.selected_page = x
    self:message(string.format("Page %02d", x))
  elseif self.page_mode == "loop" then
    self.page_loop[x] = not self.page_loop[x]
    if not any_keys(self.page_loop) then
      self.page_loop[x] = true
    end
    self:message(string.format("Page %02d %s", x, self.page_loop[x] and "On" or "Off"))
  elseif self.page_mode == "rate" and RATES[x] ~= nil then
    self.rate_index = x
    self:message("Rate " .. rate_label(RATES[x]))
  end
end

function GridSequencer:set_page_mode(mode)
  self.page_mode = mode
  self:message(PAGE_MODE_LABELS[mode] or mode)
end

function GridSequencer:key(x, y, z)
  if x < 1 or x > 16 or y < 1 or y > 8 then
    return
  end

  local key_id = x .. ":" .. y
  self.pressed[key_id] = z == 1 or nil

  if x == 16 and y == 7 then
    self.page_down = z == 1
    self:redraw()
    self:request_redraw()
    return
  end

  if y == 1 then
    self:key_controls(x, z)
  elseif y == 2 then
    self:key_loop_control(x, z)
  elseif y == 8 then
    self:key_step_row(x, z)
  elseif z == 1 then
    self:key_navigation(x, y)
  end

  self:redraw()
  self:request_redraw()
end

function GridSequencer:key_controls(x, z)
  if x == 1 then
    self.fn_down = z == 1
  elseif z == 1 and x == 3 then
    self.recording = not self.recording
    self:message(self.recording and "Record On" or "Record Off")
  elseif z == 1 and x == 4 then
    if self.options.set_playing ~= nil then
      self.options.set_playing(not self.playing, false)
    end
  elseif z == 1 and x == 5 then
    if self.options.set_playing ~= nil then
      self.options.set_playing(false, true)
    end
  end
end

function GridSequencer:key_navigation(x, y)
  if not self.page_down then
    return
  end

  if x == 13 and y == 6 then
    self:set_page_mode("select")
  elseif x == 13 and y == 7 then
    self:set_page_mode("loop")
  elseif x == 12 and y == 7 then
    self:set_page_mode("rate")
  elseif x == 14 and y == 7 then
    self:set_page_mode("select")
  end
end

function GridSequencer:key_loop_control(x, z)
  if z == 1 then
    self.loop_holds[x] = true
    local start_point, end_point = self:loop_region_from_holds(self.loop_holds)
    if start_point ~= nil then
      self.manual_region = {
        start_point = start_point,
        end_point = end_point
      }
      if any_keys(self.step_holds) then
        self:lock_held_steps(start_point, end_point)
      end
      self:set_region_and_phase(start_point, end_point)
    end
  else
    self.loop_holds[x] = nil
    local start_point, end_point = self:loop_region_from_holds(self.loop_holds)
    if start_point ~= nil then
      self.manual_region = {
        start_point = start_point,
        end_point = end_point
      }
      self:set_region_and_phase(start_point, end_point)
    else
      self.manual_region = nil
      self:apply_current_region()
    end
  end
end

function GridSequencer:key_step_row(x, z)
  if self.page_down then
    if z == 1 then
      self:handle_page_step(x)
    end
    return
  end

  if z == 1 then
    self.step_holds[x] = true
    self.step_press_time[x] = util.time()
    self.step_edited[x] = false
    local lock = self:step_lock(self.selected_page, x)
    if lock ~= nil then
      self:set_region(lock.start_point, lock.end_point)
    end
  else
    local press_time = self.step_press_time[x] or util.time()
    local was_quick_press = (util.time() - press_time) < STEP_HOLD_SECONDS
    local was_edited = self.step_edited[x] == true
    self.step_holds[x] = nil
    self.step_press_time[x] = nil
    self.step_edited[x] = nil
    if was_quick_press and not was_edited and self:step_lock(self.selected_page, x) ~= nil then
      self:clear_step_lock(self.selected_page, x)
      self:message(string.format("Step %02d Clear", x))
    end
    if not any_keys(self.step_holds) and not any_keys(self.loop_holds) then
      self:apply_current_region()
    end
  end
end

function GridSequencer:pressed_level(x, y, base)
  if self.pressed[x .. ":" .. y] then
    return 15
  end
  return base
end

function GridSequencer:loop_key_for_value(value)
  return util.clamp(math.floor((value / LOOP_UNITS_PER_KEY) + 0.5) + 1, 1, 16)
end

function GridSequencer:draw_loop_lock(lock, level)
  if lock == nil then
    return
  end
  local start_key = util.clamp(math.floor(lock.start_point / LOOP_UNITS_PER_KEY) + 1, 1, 16)
  local end_key = util.clamp(math.ceil(lock.end_point / LOOP_UNITS_PER_KEY), 1, 16)
  for x = start_key, end_key do
    self.g:led(x, 2, level)
  end
end

function GridSequencer:redraw()
  if self.g == nil then
    return
  end

  self.g:all(0)

  self.g:led(1, 1, self:pressed_level(1, 1, 3))
  self.g:led(3, 1, self:pressed_level(3, 1, self.recording and 12 or 3))
  self.g:led(4, 1, self:pressed_level(4, 1, self.playing and 13 or 4))
  self.g:led(5, 1, self:pressed_level(5, 1, self.playing and 4 or 13))

  for x = 1, 16 do
    self.g:led(x, 2, 2)
  end

  local held_step = self:first_held_step()
  if held_step ~= nil then
    self:draw_loop_lock(self:step_lock(self.selected_page, held_step), 9)
  end

  self:draw_loop_lock(self.manual_region, 10)

  for x, held in pairs(self.loop_holds) do
    if held then
      self.g:led(x, 2, 15)
    end
  end

  if self.playing and self.options.phase ~= nil then
    local start_point, end_point = self:active_region()
    local phase = self.options.phase() or 0
    local position = start_point + ((end_point - start_point) * phase)
    local x = util.clamp(math.floor(position / LOOP_UNITS_PER_KEY) + 1, 1, 16)
    self.g:led(x, 2, 12)
  end

  self.g:led(11, 6, self:pressed_level(11, 6, 2))
  self.g:led(11, 7, self:pressed_level(11, 7, 2))
  self.g:led(12, 7, self:pressed_level(12, 7, self.page_mode == "rate" and 8 or 3))
  self.g:led(13, 7, self:pressed_level(13, 7, self.page_mode == "loop" and 8 or 3))
  self.g:led(14, 7, self:pressed_level(14, 7, 3))
  self.g:led(13, 6, self:pressed_level(13, 6, self.page_mode == "select" and 8 or 3))
  self.g:led(16, 7, self:pressed_level(16, 7, self.page_down and 15 or 5))

  if self.page_down then
    self:draw_page_row()
  else
    self:draw_step_row()
  end

  self.g:refresh()
end

function GridSequencer:draw_step_row()
  local flash_on = math.floor(util.time() * 8) % 2 == 0
  for x = 1, 16 do
    local lock = self:step_lock(self.selected_page, x)
    local level = lock ~= nil and 6 or 2
    if self.playing and x == self.play_step then
      level = flash_on and 15 or 5
    end
    if self.step_holds[x] then
      level = 15
    end
    self.g:led(x, 8, level)
  end
end

function GridSequencer:draw_page_row()
  local flash_on = math.floor(util.time() * 4) % 2 == 0
  for x = 1, 16 do
    local level = 2
    if self.page_mode == "select" then
      level = x == self.selected_page and 12 or 3
    elseif self.page_mode == "loop" then
      level = self.page_loop[x] and 9 or 2
    elseif self.page_mode == "rate" then
      level = RATES[x] ~= nil and 4 or 1
      if x == self.rate_index then
        level = 12
      end
    end
    if self.playing and x == self.play_page then
      level = flash_on and 15 or 5
    end
    self.g:led(x, 8, level)
  end
end

return GridSequencer
