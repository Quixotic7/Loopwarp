local GridSequencer = {}
GridSequencer.__index = GridSequencer

local Step = include("lib/sequencer/step")
local INTRO_CAT_HEX = include("lib/intro_cat_frames")  -- 55 frames of 16x8 grid levels
local INTRO_CAT_FPS = 10  -- must match the screen logo fps so the two stay in sync

-- Decode the hex frame table into numeric levels once (INTRO_CAT[frame][row][col]).
local INTRO_CAT = {}
for f = 1, #INTRO_CAT_HEX do
  local rows = {}
  for row = 1, 8 do
    local cols = {}
    local hex = INTRO_CAT_HEX[f][row]
    for x = 1, 16 do
      cols[x] = tonumber(string.sub(hex, x, x), 16) or 0
    end
    rows[row] = cols
  end
  INTRO_CAT[f] = rows
end

local PAGE_MODES = {"select", "loop", "rate"}
local PAGE_MODE_LABELS = {
  select = "Page Select",
  loop = "Page Loop",
  rate = "Pattern Rate"
}
local RATES = {0.125, 0.25, 0.5, 1, 2, 4, 8, 16}
local STEP_HOLD_SECONDS = 0.25
local MACHINE_LOOP = 1
local MACHINE_LOOP_TRIG = 2
local MACHINE_GRID_SLICE = 3
local MACHINE_RAZOR_SLICE = 4
local WHITE_KEYS = {[1] = 0, [2] = 2, [3] = 4, [4] = 5, [5] = 7, [6] = 9, [7] = 11, [8] = 12}
local BLACK_KEYS = {[2] = 1, [3] = 3, [5] = 6, [6] = 8, [7] = 10}
local CATEGORY_KEYS = {
  [7] = "master",
  [8] = "file",
  [9] = "pattern",
  [11] = "trig",
  [12] = "source",
  [13] = "filter",
  [14] = "amp",
  [15] = "fx",
  [16] = "mod"
}

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

local function table_count(t)
  local count = 0
  for _, value in pairs(t or {}) do
    if value then
      count = count + 1
    end
  end
  return count
end

local function rate_label(rate)
  if rate < 1 then
    return string.format("%.3gx", rate)
  end
  return string.format("%gx", rate)
end

local function format_region(start_point, end_point)
  if end_point == nil then
    return string.format("st %03.0f", start_point)
  end
  return string.format("st %03.0f end %03.0f", start_point, end_point)
end

local function is_slice_machine(machine)
  return machine == MACHINE_GRID_SLICE or machine == MACHINE_RAZOR_SLICE
end

function GridSequencer.new(options)
  local self = setmetatable({}, GridSequencer)
  self.options = options or {}
  self.g = grid.connect()
  self.page_mode = "select"
  self.selected_page = 1
  self.play_page = 1
  self.play_step = 1
  self.play_index = 1
  self.playing = false
  self.recording = false
  self.fn_down = false
  self.page_down = false
  self.keyboard_octave = 0
  self.pressed = {}
  self.loop_holds = {}
  self.loop_tap_key = nil
  self.loop_tap_kind = nil
  self.slice_holds = {}
  self.preview_active = false
  self.step_holds = {}
  self.step_press_time = {}
  self.step_edited = {}
  self.page_loop = {}
  self.page_loop[1] = true
  self.rate_index = 4
  self.steps = {}
  self.manual_region = nil
  self.seq_metro = nil
  self.next_step_time = nil
  self.seq_remaining_time = nil
  self.param_lock_holds = {}
  self.current_region_start = nil
  self.current_region_end = nil
  self.current_range_start = nil
  self.current_range_end = nil
  self.g.key = function(x, y, z) self:key(x, y, z) end
  return self
end

function GridSequencer:cleanup()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
    self.seq_metro = nil
  end
  if self.options.release_all_slices ~= nil then
    self.options.release_all_slices()
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

function GridSequencer:machine()
  if self.options.get_machine ~= nil then
    return util.clamp(math.floor((self.options.get_machine() or 1) + 0.5), 1, 4)
  end
  return MACHINE_LOOP
end

function GridSequencer:pattern_steps()
  if self.options.get_pattern_steps ~= nil then
    return util.clamp(math.floor((self.options.get_pattern_steps() or 64) + 0.5), 1, 256)
  end
  return 64
end

function GridSequencer:pattern_pages()
  return util.clamp(math.ceil(self:pattern_steps() / 16), 1, 16)
end

function GridSequencer:loop_division()
  local raw = self.options.get_loop_division ~= nil and self.options.get_loop_division() or 16
  local division = util.clamp(math.floor(((tonumber(raw) or 16) / 2) + 0.5) * 2, 2, 32)
  return division
end

function GridSequencer:loop_units_per_key()
  return 128 / self:loop_division()
end

-- Loop keys are addressed as one combined 1-32 range: 1-16 is row 2, 17-32
-- overflows onto row 3 when the division is set above 16.
function GridSequencer:loop_key_position(key_index)
  if key_index <= 16 then
    return key_index, 2
  end
  return key_index - 16, 3
end

function GridSequencer:trig_polyphony()
  if self.options.get_trig_polyphony ~= nil then
    return util.clamp(math.floor((self.options.get_trig_polyphony() or 1) + 0.5), 1, 2)
  end
  return 1
end

function GridSequencer:slice_count()
  if self.options.get_slice_count ~= nil then
    return util.clamp(math.floor((self.options.get_slice_count() or 16) + 0.5), 1, 32)
  end
  return 16
end

function GridSequencer:slice_index()
  if self.options.get_slice_index ~= nil then
    return util.clamp(math.floor((self.options.get_slice_index() or 1) + 0.5), 1, self:slice_count())
  end
  return 1
end

function GridSequencer:base_region()
  if self.options.base_region ~= nil then
    return self.options.base_region()
  end
  return 0, 128
end

function GridSequencer:base_pitch()
  if self.options.base_pitch ~= nil then
    return self.options.base_pitch() or 0
  end
  return 0
end

function GridSequencer:default_velocity()
  if self.options.get_default_velocity ~= nil then
    return self.options.get_default_velocity() or 1
  end
  return 1
end

function GridSequencer:default_length()
  if self.options.get_default_length ~= nil then
    return self.options.get_default_length() or 1
  end
  return 1
end

function GridSequencer:step_index(page, step)
  return ((page - 1) * 16) + step
end

function GridSequencer:index_to_page_step(index)
  local page = math.floor((index - 1) / 16) + 1
  local step = ((index - 1) % 16) + 1
  return page, step
end

function GridSequencer:sync_play_page_step()
  self.play_page, self.play_step = self:index_to_page_step(self.play_index)
end

function GridSequencer:step_record(index, create)
  if self.steps[index] == nil and create then
    self.steps[index] = Step.new()
  end
  return self.steps[index]
end

function GridSequencer:step_record_for_page_step(page, step, create)
  return self:step_record(self:step_index(page, step), create)
end

function GridSequencer:first_held_step()
  for step = 1, 16 do
    if self.step_holds[step] then
      return step
    end
  end
  return nil
end

function GridSequencer:held_step_index()
  local step = self:first_held_step()
  if step == nil then
    return nil
  end
  return self:step_index(self.selected_page, step), step
end

function GridSequencer:loop_region_from_holds(holds)
  local keys = sorted_held_keys(holds)
  if #keys == 0 then
    return nil
  end

  local units = self:loop_units_per_key()
  local start_point = math.min((keys[1] - 1) * units, 127)
  local end_point = math.min(keys[#keys] * units, 128)
  if end_point <= start_point then
    end_point = math.min(start_point + units, 128)
  end
  return start_point, end_point, #keys
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

-- Loop start/end region locks are stored as ordinary param_locks (lock ids
-- "loop_start"/"loop_end") instead of a separate field, so grid loop-key
-- presses and K2/K3 encoder edits of STRT/END while holding a step share one
-- storage location: held_param_lock/item_raw_value already show any locked
-- param as locked when holding a step, so this is what makes STRT/END show up
-- there too, with no separate display path needed. An absent loop_end means
-- start-only (end follows the track's own base region).
function GridSequencer:step_lock(page, step)
  local record = self:step_record_for_page_step(page, step, false)
  if record == nil or record.param_locks == nil or record.param_locks.loop_start == nil then
    return nil
  end
  return {
    start_point = record.param_locks.loop_start,
    end_point = record.param_locks.loop_end
  }
end

function GridSequencer:set_step_lock(page, step, start_point, end_point, start_only)
  local record = self:step_record_for_page_step(page, step, true)
  record.trig = true
  record.param_locks = record.param_locks or {}
  record.param_locks.loop_start = start_point
  -- NB: not `start_only and nil or end_point` -- that idiom always yields
  -- end_point (true and nil -> nil, nil or end_point -> end_point), which is
  -- why a single loop-key tap used to lock both ends instead of start-only.
  if start_only then
    record.param_locks.loop_end = nil
  else
    record.param_locks.loop_end = end_point
  end
end

function GridSequencer:clear_step(page, step)
  self.steps[self:step_index(page, step)] = nil
end

-- Loop-only single-key tap cycling: tapping the same loop key repeatedly while
-- holding a step cycles start-only -> start+end -> start-only. Holding 2+ loop
-- keys at once (held_count > 1) always locks start+end from their min/max, and
-- resets the cycle so the next single-key tap starts fresh.
function GridSequencer:loop_tap_start_only(held_count)
  if held_count > 1 then
    self.loop_tap_key = nil
    self.loop_tap_kind = nil
    return false
  end

  local current_key = sorted_held_keys(self.loop_holds)[1]
  if self.loop_tap_key == current_key and self.loop_tap_kind == "start_only" then
    self.loop_tap_kind = "start_end"
    return false
  elseif self.loop_tap_key == current_key and self.loop_tap_kind == "start_end" then
    self.loop_tap_kind = "start_only"
    return true
  end

  self.loop_tap_key = current_key
  self.loop_tap_kind = "start_only"
  return true
end

function GridSequencer:lock_held_steps(start_point, end_point, held_count)
  local did_lock = false
  local machine = self:machine()
  local start_only = machine == MACHINE_LOOP and self:loop_tap_start_only(held_count)
  for step, held in pairs(self.step_holds) do
    if held then
      self:set_step_lock(self.selected_page, step, start_point, end_point, start_only)
      self.step_edited[step] = true
      did_lock = true
    end
  end
  if did_lock then
    self:message(string.format("Step %02d Lock", self:first_held_step() or 1))
  end
  return did_lock
end

-- A reset flag is active for a step when the step p-locks it on, or (no lock)
-- the track default is on. Env/LFO/Filter resets are placeholders for now.
function GridSequencer:reset_active(record, reset_id)
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil and locks[reset_id] ~= nil then
    return locks[reset_id] == 1
  end
  if self.options.reset_default ~= nil then
    return self.options.reset_default(reset_id) == true
  end
  return true
end

-- Ghost triggers are derived (not a stored flag): a trig that resets nothing --
-- no start reset (loop_start lock) and env/LFO/filter resets all off. So a step
-- becomes ghost by clearing its start lock and turning its resets off, and back
-- to normal by restoring either. Ghosts carry the current state forward instead
-- of ending the previous note.
function GridSequencer:is_ghost(record)
  if record == nil or record.trig ~= true then
    return false
  end
  local locks = record.param_locks or {}
  if locks.loop_start ~= nil then
    return false
  end
  return not (self:reset_active(record, "env_reset")
    or self:reset_active(record, "lfo_reset")
    or self:reset_active(record, "filter_reset"))
end

function GridSequencer:toggle_step(page, step)
  local index = self:step_index(page, step)
  local record = self:step_record(index, false)
  if Step.has_content(record) then
    self.steps[index] = nil
    self:message(string.format("Step %02d Clear", step))
    return
  end

  record = self:step_record(index, true)
  record.trig = true
  if is_slice_machine(self:machine()) then
    record.slices[self:slice_index()] = true
  else
    -- Loop machines: a normal trigger resets start to 0 (the non-ghost default).
    record.param_locks = record.param_locks or {}
    record.param_locks.loop_start = 0
  end
  self:message(string.format("Step %02d Trig", step))
end

-- FN + tap toggles a step between normal and ghost. Ghost = no start reset and
-- env/LFO/filter resets off; normal = start reset (0) and resets on.
function GridSequencer:toggle_ghost_step(page, step)
  local index = self:step_index(page, step)
  local record = self:step_record(index, true)
  record.trig = true
  record.param_locks = record.param_locks or {}
  if self:is_ghost(record) then
    record.param_locks.loop_start = 0
    record.param_locks.env_reset = nil
    record.param_locks.lfo_reset = nil
    record.param_locks.filter_reset = nil
    self:message(string.format("Step %02d Trig", step))
  else
    record.param_locks.loop_start = nil
    record.param_locks.loop_end = nil
    record.param_locks.env_reset = 0
    record.param_locks.lfo_reset = 0
    record.param_locks.filter_reset = 0
    self:message(string.format("Step %02d Ghost", step))
  end
end

function GridSequencer:toggle_step_slice(index, slice)
  local record = self:step_record(index, true)
  record.trig = true
  record.slices = record.slices or {}
  local was_active = record.slices[slice] == true
  if self.options.get_slice_polyphony ~= nil and self.options.get_slice_polyphony() == 2 then
    record.slices = {}
  end
  record.slices[slice] = not was_active
  if table_count(record.slices) == 0 then
    record.trig = false
  end
end

function GridSequencer:set_step_pitch(index, pitch)
  local record = self:step_record(index, true)
  record.trig = true
  record.pitch = pitch
  record.param_locks = record.param_locks or {}
  record.param_locks.pitch = pitch
end

function GridSequencer:apply_step_pitch(record)
  local pitch = record ~= nil and record.pitch or nil
  if pitch == nil and record ~= nil and record.param_locks ~= nil then
    pitch = record.param_locks.pitch
  end
  if pitch == nil and self.param_lock_holds.pitch ~= nil then
    pitch = self.param_lock_holds.pitch.value
  end
  if self.options.set_pitch ~= nil then
    self.options.set_pitch(pitch or self:base_pitch())
  end
end

function GridSequencer:set_held_param_lock(param_id, value)
  local did_lock = false
  for step, held in pairs(self.step_holds) do
    if held then
      local index = self:step_index(self.selected_page, step)
      local record = self:step_record(index, true)
      record.trig = true
      record.param_locks = record.param_locks or {}
      record.param_locks[param_id] = value
      if param_id == "pitch" then
        record.pitch = value
      elseif param_id == "velocity" then
        record.velocity = value
      elseif param_id == "length" then
        record.length = value
      end
      self.step_edited[step] = true
      did_lock = true
    end
  end
  if did_lock then
    -- If we're previewing a held step while stopped, re-apply its range/region/
    -- pitch live so edits (e.g. range start/end) are heard immediately without
    -- re-pressing the step.
    self:refresh_preview_region()
  end
  return did_lock
end

-- Re-apply the currently-previewed step's range, region and pitch so lock edits
-- take effect live during a stopped step preview.
function GridSequencer:refresh_preview_region()
  if self.playing or not self.preview_active then
    return
  end
  local index = self:held_step_index()
  if index == nil then
    return
  end
  local record = self:step_record(index, false)
  if record == nil or record.trig ~= true then
    return
  end
  local locks = record.param_locks or {}
  self:push_active_range(locks.range_start, locks.range_end)
  local start_point, end_point = self:locked_region(record)
  self:set_region(start_point, end_point)
  self:apply_step_pitch(record)
end

function GridSequencer:held_param_lock(param_id)
  local index = self:held_step_index()
  if index == nil then
    return nil
  end
  local record = self:step_record(index, false)
  if record == nil then
    return nil
  end
  if record.param_locks ~= nil and record.param_locks[param_id] ~= nil then
    return record.param_locks[param_id]
  end
  if param_id == "pitch" then
    return record.pitch
  elseif param_id == "velocity" then
    return record.velocity
  elseif param_id == "length" then
    return record.length
  end
  return nil
end

function GridSequencer:clear_held_param_lock(param_id)
  local did_clear = false
  for step, held in pairs(self.step_holds) do
    if held then
      local index = self:step_index(self.selected_page, step)
      local record = self:step_record(index, false)
      if record ~= nil then
        if record.param_locks ~= nil then
          record.param_locks[param_id] = nil
        end
        if param_id == "pitch" then
          record.pitch = nil
        elseif param_id == "velocity" then
          record.velocity = nil
        elseif param_id == "length" then
          record.length = nil
        end
        self.step_edited[step] = true
        did_clear = true
      end
    end
  end
  return did_clear
end

function GridSequencer:clear_all_param_locks(param_id)
  local did_clear = false
  for _, record in pairs(self.steps) do
    if record.param_locks ~= nil and record.param_locks[param_id] ~= nil then
      record.param_locks[param_id] = nil
      did_clear = true
    end
    if param_id == "pitch" and record.pitch ~= nil then
      record.pitch = nil
      did_clear = true
    elseif param_id == "velocity" and record.velocity ~= nil then
      record.velocity = nil
      did_clear = true
    elseif param_id == "length" and record.length ~= nil then
      record.length = nil
      did_clear = true
    end
  end
  return did_clear
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

function GridSequencer:note_seconds(record)
  if is_slice_machine(self:machine()) and self.options.get_hold_to_step ~= nil and self.options.get_hold_to_step() == false then
    if self.options.get_slice_hold ~= nil then
      return self.options.get_slice_hold()
    end
    return 0
  end
  return math.max(0.01, ((record ~= nil and record.length) or self:default_length()) * self:step_seconds())
end

function GridSequencer:clear_param_lock_holds()
  self.param_lock_holds = {}
end

function GridSequencer:expire_param_lock_holds(now)
  local changed = false
  now = now or util.time()
  for lock_id, hold in pairs(self.param_lock_holds) do
    if hold.expires_at ~= nil and now >= hold.expires_at then
      self.param_lock_holds[lock_id] = nil
      changed = true
    end
  end
  return changed
end

function GridSequencer:effective_param_locks(record)
  local now = util.time()
  self:expire_param_lock_holds(now)

  local locks = {}
  local has_locks = false
  for lock_id, hold in pairs(self.param_lock_holds) do
    locks[lock_id] = hold.value
    has_locks = true
  end

  if record ~= nil and record.param_locks ~= nil then
    local length_seconds = self:note_seconds(record)
    for lock_id, value in pairs(record.param_locks) do
      locks[lock_id] = value
      has_locks = true
      if lock_id ~= "length" and lock_id ~= "velocity" then
        self.param_lock_holds[lock_id] = {
          value = value,
          expires_at = now + length_seconds
        }
      end
    end
  end

  return has_locks and locks or nil
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

-- Resolve a single step record's region against the track base. Start and end
-- are independent: a start-only lock keeps the track end, an end-only lock keeps
-- the track start, both-locked overrides both. (Used for stopped preview; live
-- playback goes through resolve_active_region so the sequencer/loop-key/track
-- layering can take effect -- see region_layers.)
function GridSequencer:locked_region(record)
  local start_point, end_point = self:base_region()
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil then
    if locks.loop_start ~= nil then
      start_point = locks.loop_start
    end
    if locks.loop_end ~= nil then
      end_point = locks.loop_end
    end
  end
  if end_point <= start_point then
    end_point = math.min(start_point + 0.01, 128)
  end
  return start_point, end_point
end

-- The three region layers that can drive playback, each optionally supplying a
-- start and/or an end independently:
--   track  -- always present (base_region), the bottom fallback
--   keys   -- live loop-key holds (nil when no loop keys are held)
--   seq    -- the currently-triggering step's region lock, persisted with an
--             expiry window in param_lock_holds so it reverts on its own
-- resolve_active_region walks a priority order (set by live-performance mode)
-- and, for each of start and end separately, takes the highest-priority layer
-- that provides that endpoint.
function GridSequencer:region_layers()
  local track_start, track_end = self:base_region()

  self:expire_param_lock_holds(util.time())
  local seq = {}
  if self.param_lock_holds.loop_start ~= nil then
    seq.start_point = self.param_lock_holds.loop_start.value
  end
  if self.param_lock_holds.loop_end ~= nil then
    seq.end_point = self.param_lock_holds.loop_end.value
  end

  local keys = {}
  local key_start, key_end = self:loop_region_from_holds(self.loop_holds)
  if key_start ~= nil then
    keys.start_point = key_start
    keys.end_point = key_end
  end

  return track_start, track_end, seq, keys
end

function GridSequencer:resolve_active_region()
  local track_start, track_end, seq, keys = self:region_layers()
  local order
  if self:live_performance_mode() then
    order = {keys, seq}
  else
    order = {seq, keys}
  end

  local start_point, end_point = track_start, track_end
  local start_set, end_set = false, false
  for _, layer in ipairs(order) do
    if not start_set and layer.start_point ~= nil then
      start_point = layer.start_point
      start_set = true
    end
    if not end_set and layer.end_point ~= nil then
      end_point = layer.end_point
      end_set = true
    end
  end

  if end_point <= start_point then
    end_point = math.min(start_point + 0.01, 128)
  end
  return start_point, end_point
end

-- Step Range -> Active Range override. Range (0-128 window inside file trim) is
-- layered exactly like the loop region: the range_start/range_end params are the
-- Track Range (edited on the Range page, never touched by step locks), a
-- triggering step's range lock is the Step Range, and the engine plays the
-- Actual Range. We push the Step Range (nil per endpoint = fall back to Track)
-- to the coordinator, which sets it on map_trim_point. A change also invalidates
-- the region cache so the next set_region re-maps the engine points.
function GridSequencer:push_active_range(range_start, range_end)
  if self.options.set_active_range == nil then
    return
  end
  if range_start ~= self.current_range_start or range_end ~= self.current_range_end then
    self.options.set_active_range(range_start, range_end)
    self.current_range_start = range_start
    self.current_range_end = range_end
    self.current_region_start = nil
  end
end

-- During playback the Step Range lives in param_lock_holds (with the note-length
-- expiry), the same store the loop region uses -- so it reverts to Track Range
-- on its own when the step's window elapses.
function GridSequencer:apply_active_range()
  if self.options.set_active_range == nil then
    return
  end
  self:expire_param_lock_holds(util.time())
  local range_start = self.param_lock_holds.range_start and self.param_lock_holds.range_start.value or nil
  local range_end = self.param_lock_holds.range_end and self.param_lock_holds.range_end.value or nil
  self:push_active_range(range_start, range_end)
end

-- Best estimate of the current absolute playback position (0-128) within the
-- region currently loaded in the engine, used to preserve position across a
-- region change (Boomerang playhead return, sequencer revert continuity).
function GridSequencer:current_absolute_position()
  local cur_start = self.current_region_start
  local cur_end = self.current_region_end
  if cur_start == nil then
    return nil
  end
  return self:position_at_region(cur_start, cur_end, util.time())
end

-- Change the loaded region while keeping the absolute playback position steady:
-- recompute the phase so newStart + phase*width lands on the same sample point.
function GridSequencer:set_region_preserve_position(new_start, new_end)
  local pos = self:current_absolute_position()
  if pos == nil then
    self:set_region(new_start, new_end)
    return
  end
  local phase = self:phase_for_position(new_start, new_end, pos)
  self:set_region_with_phase(new_start, new_end, phase)
end

function GridSequencer:slice_range(slice)
  if self.options.get_slice_range ~= nil then
    return self.options.get_slice_range(slice)
  end
  local count = self:slice_count()
  local width = 128 / count
  return (slice - 1) * width, slice * width
end

function GridSequencer:trigger_region(record)
  if self.options.trigger_region == nil then
    return
  end
  local start_point, end_point = self:locked_region(record)
  self:set_region_with_phase(start_point, end_point, 0)
  self.options.trigger_region(start_point, end_point, {
    velocity = record.velocity or self:default_velocity(),
    length_seconds = self:note_seconds(record),
    pitch = record.pitch or self:base_pitch()
  })
end

function GridSequencer:trigger_step_slices(record)
  if self.options.trigger_slice == nil then
    return
  end
  local first_start = nil
  local first_end = nil
  local slices = record.slices or {}
  if record.trig and table_count(slices) == 0 then
    slices = {[self:slice_index()] = true}
  end
  for slice = 1, self:slice_count() do
    if slices[slice] then
      local start_point, end_point = self:slice_range(slice)
      first_start = first_start or start_point
      first_end = first_end or end_point
      self.options.trigger_slice(slice, start_point, end_point, {
        velocity = record.velocity or self:default_velocity(),
        length_seconds = self:note_seconds(record),
        pitch = record.pitch or self:base_pitch()
      })
    end
  end
  if first_start ~= nil then
    self:mark_region_current(first_start, first_end)
  end
end

function GridSequencer:enter_step(reset_sequence)
  local record = self:step_record(self.play_index, false)
  local machine = self:machine()

  if reset_sequence then
    self:clear_param_lock_holds()
  end
  -- Monophonic: a fresh non-ghost trigger ends the previous note -- clear the
  -- carried holds so unlocked params revert to base before this step's locks
  -- apply. Without this, a step's lock outlives its note-length window when the
  -- length is >= 1 and the next trigger fails to switch it (e.g. sample slot).
  -- Ghost triggers, and Poly mode, carry the previous state forward instead.
  if not reset_sequence and record ~= nil and record.trig == true
    and self:trig_polyphony() == 1 and not self:is_ghost(record) then
    self:clear_param_lock_holds()
  end
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(self:effective_param_locks(record))
  end
  self:apply_step_pitch(record)
  -- Push the Step Range before any region set, so the region maps through the
  -- correct (Actual) range in the same tick.
  self:apply_active_range()

  if machine == MACHINE_LOOP then
    -- A step that carries an explicit region lock jumps the playhead to the new
    -- active start (fresh trigger). Every other step re-resolves the layered
    -- region and applies it *without* resetting phase, so an expired step lock
    -- reverts to the track region while the playhead keeps advancing (task #21).
    local record_locks_region = record ~= nil and record.param_locks ~= nil
      and (record.param_locks.loop_start ~= nil or record.param_locks.loop_end ~= nil)
    if reset_sequence then
      local start_point, end_point = self:resolve_active_region()
      self:set_region_with_phase(start_point, end_point, 0)
    elseif record ~= nil and record.trig and record_locks_region then
      local start_point, end_point = self:resolve_active_region()
      self:set_region_with_phase(start_point, end_point, 0)
    else
      local start_point, end_point = self:resolve_active_region()
      self:set_region(start_point, end_point)
    end
  elseif machine == MACHINE_LOOP_TRIG then
    if record ~= nil and record.trig then
      self:trigger_region(record)
    else
      local start_point, end_point = self:base_region()
      self:set_region(start_point, end_point)
    end
  elseif is_slice_machine(machine) then
    if record ~= nil and table_count(record.slices) > 0 then
      self:trigger_step_slices(record)
    end
  end
end

function GridSequencer:start_sequence(reset_sequence)
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  self.playing = true
  if self.seq_remaining_time ~= nil and not reset_sequence then
    self.next_step_time = util.time() + self.seq_remaining_time
    self.seq_remaining_time = nil
  else
    self.seq_remaining_time = nil
    self.play_index = 1
    self:sync_play_page_step()
    self:enter_step(true)
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
  if self.options.release_all_slices ~= nil then
    self.options.release_all_slices()
  end
  self:request_redraw()
end

function GridSequencer:stop_sequence()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  self.next_step_time = nil
  self.seq_remaining_time = nil
  self.play_index = 1
  self:sync_play_page_step()
  self:clear_param_lock_holds()
  self:push_active_range(nil, nil)
  local start_point, end_point = self:base_region()
  self:set_region_with_phase(start_point, end_point, 0)
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(nil)
  end
  self:apply_step_pitch(nil)
  if self.options.release_all_slices ~= nil then
    self.options.release_all_slices()
  end
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

  if self:expire_param_lock_holds(now) then
    if self.options.apply_step_param_locks ~= nil then
      self.options.apply_step_param_locks(self:effective_param_locks(nil))
    end
    -- A region/range lock that just expired (note-length window elapsed) means
    -- the active region/range should revert to whatever the remaining layers
    -- resolve to, without disturbing the playhead position.
    self:apply_active_range()
    if self:machine() == MACHINE_LOOP then
      local start_point, end_point = self:resolve_active_region()
      self:set_region(start_point, end_point)
    end
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
  self.play_index = self.play_index + 1
  if self.play_index > self:pattern_steps() then
    self.play_index = 1
  end
  self:sync_play_page_step()
  self:enter_step(false)
  self:request_redraw()
end

function GridSequencer:screen_edit()
  local index, step = self:held_step_index()
  if index == nil then
    return nil
  end
  local record = self:step_record(index, false)
  return {
    page = self.selected_page,
    step = step,
    index = index,
    trig = record ~= nil and record.trig == true,
    velocity = record ~= nil and record.velocity or self:default_velocity(),
    length = record ~= nil and record.length or self:default_length(),
    pitch = record ~= nil and record.pitch or nil,
    slices = record ~= nil and table_count(record.slices) or 0,
    locks = record ~= nil and table_count(record.param_locks) or 0,
    lock = self:step_lock(self.selected_page, step)
  }
end

function GridSequencer:held_step_is_ghost()
  local index = self:held_step_index()
  if index == nil then
    return false
  end
  return self:is_ghost(self:step_record(index, false))
end

function GridSequencer:screen_status()
  if self.manual_region ~= nil then
    return "temp " .. format_region(self.manual_region.start_point, self.manual_region.end_point)
  end

  local edit = self:screen_edit()
  if edit ~= nil then
    local record = self:step_record(edit.index, false)
    if Step.has_content(record) then
      return string.format("step %02d vel %03d len %.2f", edit.step, math.floor(edit.velocity * 100 + 0.5), edit.length)
    end
    return string.format("step %02d empty", edit.step)
  end

  return nil
end

function GridSequencer:active_region()
  if self.manual_region ~= nil then
    return self.manual_region.start_point, self.manual_region.end_point
  end

  if self.current_region_start ~= nil then
    return self.current_region_start, self.current_region_end
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

  -- YES (11,6): a context key. On the File page it holds-to-preview the sample.
  -- Handled here (not in the z==1-only navigation path) so it sees key release.
  if x == 11 and y == 6 then
    self:key_yes(z)
    self:redraw()
    self:request_redraw()
    return
  end

  if y == 1 and CATEGORY_KEYS[x] ~= nil and z == 1 then
    self:key_category(CATEGORY_KEYS[x])
  elseif y == 1 then
    self:key_controls(x, z)
  elseif self.page_down and y == 8 then
    if z == 1 then
      self:handle_page_step(x)
    end
  elseif is_slice_machine(self:machine()) and (y == 2 or y == 3) then
    self:key_slice_control(x, y, z)
  elseif y == 2 then
    self:key_loop_control(x, z)
  elseif y == 3 and self:loop_division() > 16 then
    self:key_loop_control(x + 16, z)
  elseif y == 8 then
    self:key_step_row(x, z)
  elseif y == 5 and (x == 1 or x == 2) then
    self:key_octave(x, z)
  elseif self:key_pitch_control(x, y, z) then
    -- handled
  elseif z == 1 then
    self:key_navigation(x, y)
  end

  self:redraw()
  self:request_redraw()
end

function GridSequencer:current_category()
  if self.options.current_param_category ~= nil then
    return self.options.current_param_category()
  end
  return nil
end

-- YES key. Context-dependent; only the File-page hold-to-preview is wired so
-- far. Preview itself only engages while master transport is stopped.
function GridSequencer:key_yes(z)
  if self:current_category() == "file" and self.options.set_sample_preview ~= nil then
    self.options.set_sample_preview(z == 1)
  end
end

function GridSequencer:key_category(category)
  local settings_active = self.options.param_settings_active ~= nil and self.options.param_settings_active()
  if settings_active then
    if self.fn_down then
      if self.options.return_to_param_category ~= nil then
        self.options.return_to_param_category(category)
      elseif self.options.close_param_settings ~= nil then
        self.options.close_param_settings()
      end
    else
      if self.options.select_param_category ~= nil then
        self.options.select_param_category(category)
      end
      if self.options.open_param_settings ~= nil then
        self.options.open_param_settings(category)
      end
    end
  elseif self.fn_down and self.options.open_param_settings ~= nil then
    self.options.open_param_settings(category)
  elseif self.options.select_param_category ~= nil then
    self.options.select_param_category(category)
  end
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
  if self.options.param_settings_active ~= nil and self.options.param_settings_active() then
    if x == 11 and y == 7 then
      if self.options.close_param_settings ~= nil then
        self.options.close_param_settings()
      end
    elseif x == 13 and y == 6 then
      if self.options.param_settings_select_delta ~= nil then
        self.options.param_settings_select_delta(-1)
      end
    elseif x == 13 and y == 7 then
      if self.options.param_settings_select_delta ~= nil then
        self.options.param_settings_select_delta(1)
      end
    elseif x == 12 and y == 7 then
      if self.options.param_settings_value_delta ~= nil then
        self.options.param_settings_value_delta(-1)
      end
    elseif x == 14 and y == 7 then
      if self.options.param_settings_value_delta ~= nil then
        self.options.param_settings_value_delta(1)
      end
    end
    return
  end

  if not self.page_down then
    if x == 13 and y == 6 then
      if self.options.select_param_page_delta ~= nil then
        self.options.select_param_page_delta(-1)
      end
    elseif x == 13 and y == 7 then
      if self.options.select_param_page_delta ~= nil then
        self.options.select_param_page_delta(1)
      end
    end
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

function GridSequencer:key_octave(x, z)
  if z ~= 1 then
    return
  end
  if x == 1 then
    self.keyboard_octave = util.clamp(self.keyboard_octave - 1, -2, 2)
  elseif x == 2 then
    self.keyboard_octave = util.clamp(self.keyboard_octave + 1, -2, 2)
  end
  self:message(string.format("Oct %+d", self.keyboard_octave))
end

function GridSequencer:key_pitch_value(x, y)
  local semitone = nil
  if y == 7 then
    semitone = WHITE_KEYS[x]
  elseif y == 6 then
    semitone = BLACK_KEYS[x]
  end
  if semitone == nil then
    return nil
  end
  return semitone + (self.keyboard_octave * 12)
end

function GridSequencer:key_pitch_control(x, y, z)
  local pitch = self:key_pitch_value(x, y)
  if pitch == nil then
    return false
  end
  if z == 1 then
    local index, step = self:held_step_index()
    if index ~= nil then
      self:set_step_pitch(index, pitch)
      self.step_edited[step] = true
      self:message(string.format("Step %02d Pitch %+d", step, pitch))
    elseif self.options.set_pitch_param ~= nil then
      self.options.set_pitch_param(pitch)
      self:message(string.format("Pitch %+d", pitch))
    elseif self.options.set_pitch ~= nil then
      self.options.set_pitch(pitch)
      self:message(string.format("Pitch %+d", pitch))
    end
  end
  return true
end

-- A step's region lock counts as "currently triggering" while its param lock
-- (loop_start) hasn't expired yet -- see effective_param_locks/note_seconds.
-- This is only as accurate as that per-lock expiry bookkeeping (there's no
-- continuous mid-window tracking beyond it yet), but it's the same signal the
-- rest of the lock system already relies on.
function GridSequencer:step_trigger_active()
  self:expire_param_lock_holds(util.time())
  return self.param_lock_holds.loop_start ~= nil
end

function GridSequencer:live_performance_mode()
  if self.options.get_live_performance_mode ~= nil then
    return self.options.get_live_performance_mode() == true
  end
  return false
end

function GridSequencer:step_preview_enabled()
  if self.options.get_step_preview ~= nil then
    return self.options.get_step_preview() == true
  end
  return true
end

-- A held step audibly previews only when it is a real trigger (not empty, not a
-- ghost). Empty steps must stay silent even while held. (Ghost steps -- task
-- #23 -- will read record.ghost here once they exist.)
function GridSequencer:any_previewable_step_held()
  for step, held in pairs(self.step_holds) do
    if held then
      local record = self:step_record_for_page_step(self.selected_page, step, false)
      if record ~= nil and record.trig == true and not self:is_ghost(record) then
        return true
      end
    end
  end
  return false
end

-- While the sequencer is stopped, holding a loop key or a previewable step
-- should audibly preview the sample -- independent of the K3 transport, the
-- same way slice-machine hold-to-play already works. Once the sequencer is
-- running, playback belongs to the transport and this leaves it alone.
function GridSequencer:update_preview_state()
  if self.options.play == nil then
    return
  end
  if self.playing then
    self.preview_active = false
    return
  end
  local should_preview = self:step_preview_enabled()
    and (any_keys(self.loop_holds) or self:any_previewable_step_held())
  if should_preview and not self.preview_active then
    self.preview_active = true
    self.options.play(true)
  elseif not should_preview and self.preview_active then
    self.preview_active = false
    self.options.play(false)
  end
end

-- 1=Return, 2=Boomerang (default), 3=Reset. Governs where the playhead goes
-- when the last live loop key is released during playback.
function GridSequencer:playhead_return_mode()
  local raw = self.options.get_playhead_return ~= nil and self.options.get_playhead_return() or 2
  raw = math.floor((tonumber(raw) or 2) + 0.5)
  if raw == 1 then return "return" end
  if raw == 3 then return "reset" end
  return "boomerang"
end

-- Whether a loop-key *press* should jump the playhead to the new region start.
-- Only when the keys layer actually wins the start of the resolved region: in
-- performance mode keys always win; otherwise they only win when no sequenced
-- step is currently holding the region.
function GridSequencer:loop_keys_win_start()
  if not self.playing then
    return true
  end
  if self:live_performance_mode() then
    return true
  end
  return not self:step_trigger_active()
end

-- Apply the loop-key layer to the active region. On a fresh press that wins the
-- start we audition-jump to it; while stopped we drive playback directly.
function GridSequencer:apply_loop_key_region(is_press)
  local key_start = select(1, self:loop_region_from_holds(self.loop_holds))
  local start_point, end_point = self:resolve_active_region()

  if key_start ~= nil then
    self.manual_region = { start_point = start_point, end_point = end_point }
    if is_press and self:loop_keys_win_start() then
      self:set_region_with_phase(start_point, end_point, 0)
    else
      self:set_region(start_point, end_point)
    end
  else
    -- No loop keys held any more.
    self.manual_region = nil
    if self.playing then
      self:apply_loop_release_playhead(start_point, end_point)
    else
      self:set_region(start_point, end_point)
    end
  end
end

-- The last live loop key was released during playback. The playhead-return mode
-- decides where the playhead lands in the region the sequencer/track resolve to.
function GridSequencer:apply_loop_release_playhead(start_point, end_point)
  local mode = self:playhead_return_mode()
  if mode == "reset" then
    self:set_region_with_phase(start_point, end_point, 0)
  elseif mode == "return" then
    -- Snap back to where the sequence would be: reset to the current active
    -- region start. NOTE: without a shadow phase clock this rejoins at the
    -- region start rather than the exact mid-step position -- a follow-up
    -- (task #21b) can track the sequencer's own phase for a seamless return.
    self:set_region_with_phase(start_point, end_point, 0)
  else
    -- Boomerang: keep advancing from the current absolute position.
    self:set_region_preserve_position(start_point, end_point)
  end
end

function GridSequencer:key_loop_control(x, z)
  if z == 1 then
    self.loop_holds[x] = true
    if any_keys(self.step_holds) then
      local start_point, end_point, held_count = self:loop_region_from_holds(self.loop_holds)
      if start_point ~= nil then
        self:lock_held_steps(start_point, end_point, held_count)
      end
    end
    self:apply_loop_key_region(true)
  else
    self.loop_holds[x] = nil
    self:apply_loop_key_region(false)
  end
  self:update_preview_state()
end

function GridSequencer:key_slice_control(x, y, z)
  local slice = x + (y == 3 and 16 or 0)
  if slice > self:slice_count() then
    return
  end

  local index, step = self:held_step_index()
  if index ~= nil then
    if z == 1 then
      self:toggle_step_slice(index, slice)
      self.step_edited[step] = true
      self:message(string.format("Step %02d Slice %02d", step, slice))
    end
    return
  end

  if z == 1 then
    self.slice_holds[slice] = true
    if self.options.trigger_slice ~= nil then
      local start_point, end_point = self:slice_range(slice)
      local mode = self.options.get_slice_play_mode ~= nil and self.options.get_slice_play_mode() or 1
      local length_seconds = (mode >= 3) and 60 or 0
      self.options.trigger_slice(slice, start_point, end_point, {
        velocity = 1,
        length_seconds = length_seconds,
        pitch = self:base_pitch(),
        manual = true
      })
      self:mark_region_current(start_point, end_point)
    end
  else
    self.slice_holds[slice] = nil
    local mode = self.options.get_slice_play_mode ~= nil and self.options.get_slice_play_mode() or 1
    if mode ~= 1 and self.options.release_slice ~= nil then
      self.options.release_slice(slice)
    end
  end
end

function GridSequencer:key_step_row(x, z)
  if z == 1 then
    self.step_holds[x] = true
    self.step_press_time[x] = util.time()
    self.step_edited[x] = false
    self.loop_tap_key = nil
    self.loop_tap_kind = nil
    local lock = self:step_lock(self.selected_page, x)
    if lock ~= nil and lock.end_point ~= nil then
      self:set_region(lock.start_point, lock.end_point)
    end
    if not self.playing and self:step_preview_enabled() then
      local record = self:step_record(self:step_index(self.selected_page, x), false)
      -- Ghost steps reset nothing (no start, no region), so there is nothing to
      -- preview -- skip them, same as sequenced playback carries through them.
      if record ~= nil and record.trig == true and not self:is_ghost(record) then
        -- Apply the step's Step Range before setting the region so the preview
        -- plays the step's range window, not the whole trim.
        local locks = record.param_locks or {}
        self:push_active_range(locks.range_start, locks.range_end)
        local start_point, end_point = self:locked_region(record)
        self:set_region_with_phase(start_point, end_point, 0)
        self:apply_step_pitch(record)
      end
    end
  else
    local press_time = self.step_press_time[x] or util.time()
    local was_quick_press = (util.time() - press_time) < STEP_HOLD_SECONDS
    local was_edited = self.step_edited[x] == true
    self.step_holds[x] = nil
    self.step_press_time[x] = nil
    self.step_edited[x] = nil
    self.loop_tap_key = nil
    self.loop_tap_kind = nil
    if was_quick_press and not was_edited then
      if self.fn_down then
        self:toggle_ghost_step(self.selected_page, x)
      else
        self:toggle_step(self.selected_page, x)
      end
    end
    if not any_keys(self.step_holds) and not any_keys(self.loop_holds) then
      if not self.playing then
        self:push_active_range(nil, nil)
      end
      local base_start, base_end = self:base_region()
      self:set_region(base_start, base_end)
      if not self.playing then
        self:apply_step_pitch(nil)
      end
    end
  end
  self:update_preview_state()
end

function GridSequencer:adjust_held_step(field, delta)
  local index, step = self:held_step_index()
  if index == nil then
    return false
  end

  local record = self:step_record(index, true)
  record.trig = true
  if field == "velocity" then
    record.velocity = util.clamp((record.velocity or self:default_velocity()) + (delta * 0.01), 0, 1)
    record.param_locks.velocity = record.velocity
  elseif field == "length" then
    record.length = util.clamp((record.length or self:default_length()) + (delta * 0.25), 0.25, 16)
    record.param_locks.length = record.length
  else
    return false
  end
  self.step_edited[step] = true
  self:request_redraw()
  return true
end

function GridSequencer:pressed_level(x, y, base)
  if self.pressed[x .. ":" .. y] then
    return 15
  end
  return base
end

function GridSequencer:draw_loop_lock(lock, level)
  if lock == nil then
    return
  end
  local division = self:loop_division()
  local units = self:loop_units_per_key()
  local start_key = util.clamp(math.floor(lock.start_point / units) + 1, 1, division)
  local end_key = lock.end_point ~= nil and util.clamp(math.ceil(lock.end_point / units), 1, division) or start_key
  for key_index = start_key, end_key do
    local gx, gy = self:loop_key_position(key_index)
    self.g:led(gx, gy, level)
  end
end

function GridSequencer:draw_loop_row()
  local division = self:loop_division()
  for key_index = 1, division do
    local gx, gy = self:loop_key_position(key_index)
    self.g:led(gx, gy, 2)
  end

  local held_step = self:first_held_step()
  if held_step ~= nil then
    self:draw_loop_lock(self:step_lock(self.selected_page, held_step), 9)
  end

  self:draw_loop_lock(self.manual_region, 10)

  for key_index, held in pairs(self.loop_holds) do
    if held then
      local gx, gy = self:loop_key_position(key_index)
      self.g:led(gx, gy, 15)
    end
  end

  -- Playhead only while actually playing; a stopped preview would show it static.
  if self.playing and self.options.phase ~= nil then
    local start_point, end_point = self:active_region()
    local phase = self.options.phase() or 0
    local position = start_point + ((end_point - start_point) * phase)
    local units = self:loop_units_per_key()
    local key_index = util.clamp(math.floor(position / units) + 1, 1, division)
    local gx, gy = self:loop_key_position(key_index)
    self.g:led(gx, gy, 12)
  end
end

function GridSequencer:draw_slice_rows()
  local count = self:slice_count()
  local held_step = self:first_held_step()
  local held_record = held_step ~= nil and self:step_record_for_page_step(self.selected_page, held_step, false) or nil
  local play_record = self.playing and self:step_record(self.play_index, false) or nil

  for slice = 1, count do
    local row = slice <= 16 and 2 or 3
    local x = ((slice - 1) % 16) + 1
    local level = 3
    if held_record ~= nil and held_record.slices ~= nil and held_record.slices[slice] then
      level = 9
    end
    if play_record ~= nil and play_record.slices ~= nil and play_record.slices[slice] then
      level = 12
    end
    if self.slice_holds[slice] then
      level = 15
    end
    self.g:led(x, row, self:pressed_level(x, row, level))
  end
end

function GridSequencer:draw_keyboard()
  self.g:led(1, 5, self:pressed_level(1, 5, self.keyboard_octave < 0 and 9 or 3))
  self.g:led(2, 5, self:pressed_level(2, 5, self.keyboard_octave > 0 and 9 or 3))

  local current_pitch = self:base_pitch()
  local edit = self:screen_edit()
  if edit ~= nil and edit.pitch ~= nil then
    current_pitch = edit.pitch
  end

  for x, semitone in pairs(BLACK_KEYS) do
    local pitch = semitone + (self.keyboard_octave * 12)
    local level = math.abs(pitch - current_pitch) < 0.001 and 10 or 3
    self.g:led(x, 6, self:pressed_level(x, 6, level))
  end

  for x, semitone in pairs(WHITE_KEYS) do
    local pitch = semitone + (self.keyboard_octave * 12)
    local level = math.abs(pitch - current_pitch) < 0.001 and 10 or 3
    self.g:led(x, 7, self:pressed_level(x, 7, level))
  end
end

function GridSequencer:draw_category_keys()
  local current_category = self.options.current_param_category ~= nil and self.options.current_param_category() or nil
  local settings_active = self.options.param_settings_active ~= nil and self.options.param_settings_active() or false
  for x, category in pairs(CATEGORY_KEYS) do
    local level = category == current_category and 10 or 3
    if settings_active and category == current_category then
      level = 14
    end
    self.g:led(x, 1, self:pressed_level(x, 1, level))
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
  self:draw_category_keys()

  if is_slice_machine(self:machine()) then
    self:draw_slice_rows()
  else
    self:draw_loop_row()
  end

  self:draw_keyboard()

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

local INTRO_SWEEP_PERIOD = 2.0  -- seconds for one comet sweep across the grid

-- Randomize the 8 comet bars (one per grid row): each gets a random width, entry
-- delay, and speed so the sweep flies in from the left and exits within ~2s.
-- (Caller seeds the RNG once at start; we don't reseed per roll.)
function GridSequencer:roll_intro_bars()
  self.intro_bars = {}
  for row = 1, 8 do
    local length = math.random(8, 16)        -- bar width in grid columns
    local delay = math.random() * 0.5        -- staggered entry within 0.5s
    local cross = 1.0 + math.random() * 0.5  -- 1.0-1.5s to fully cross + exit
    self.intro_bars[row] = {
      length = length,
      delay = delay,
      speed = (16 + length) / cross          -- columns/sec
    }
  end
end

-- Draw the comet bars for local sweep time `t`, compositing over an optional cat
-- base frame (INTRO_CAT row/col levels). Where a bar covers a cell it overwrites
-- the base, so the base is revealed in the bars' wake. Caller does all(0)/refresh.
function GridSequencer:draw_sweep_bars(t, cat)
  for row = 1, 8 do
    local bar = self.intro_bars and self.intro_bars[row]
    local head = nil
    if bar ~= nil then
      local local_t = t - bar.delay
      if local_t > 0 then
        head = local_t * bar.speed             -- leading edge, moving right
      end
    end
    for x = 1, 16 do
      local level = 0
      if head ~= nil then
        local dist = head - x                  -- columns behind the head
        if dist >= 0 and dist < bar.length then
          level = math.floor(15 * (1 - dist / bar.length) + 0.5)
        end
      end
      if level <= 0 and cat ~= nil then
        level = cat[row][x]
      end
      if level > 0 then
        self.g:led(x, row, level)
      end
    end
  end
end

-- Launch intro: comet sweep over the cat spritesheet (10fps, synced to the
-- screen logo via the same elapsed clock). One-shot; bars exit by ~2s.
function GridSequencer:start_intro()
  math.randomseed(math.floor(util.time() * 1e6) % 2147483647)
  self:roll_intro_bars()
end

function GridSequencer:draw_intro(elapsed)
  if self.g == nil then
    return
  end
  self.g:all(0)
  local cat_frame = math.floor(elapsed * INTRO_CAT_FPS) + 1  -- 1-indexed
  if cat_frame < 1 then cat_frame = 1 elseif cat_frame > #INTRO_CAT then cat_frame = #INTRO_CAT end
  self:draw_sweep_bars(elapsed, INTRO_CAT[cat_frame])
  self.g:refresh()
end

-- Visualizer page: the comet sweep on a loop (no cat), re-randomized each pass.
-- `phase` is the tempo-scaled clock from the coordinator, so sweep speed tracks BPM.
function GridSequencer:start_sweep_loop()
  math.randomseed(math.floor(util.time() * 1e6) % 2147483647)
  self.sweep_cycle = nil
  self:roll_intro_bars()
end

function GridSequencer:draw_sweep_loop(phase)
  if self.g == nil then
    return
  end
  local cycle = math.floor(phase / INTRO_SWEEP_PERIOD)
  if cycle ~= self.sweep_cycle then
    self.sweep_cycle = cycle
    self:roll_intro_bars()
  end
  self.g:all(0)
  self:draw_sweep_bars(phase - cycle * INTRO_SWEEP_PERIOD, nil)
  self.g:refresh()
end

function GridSequencer:draw_step_row()
  local flash_on = math.floor(util.time() * 8) % 2 == 0
  local pattern_steps = self:pattern_steps()
  for x = 1, 16 do
    local index = self:step_index(self.selected_page, x)
    local record = self:step_record(index, false)
    local level = index <= pattern_steps and 2 or 1
    if Step.has_content(record) then
      level = record.trig and 7 or 5
      if record.pitch ~= nil then
        level = 9
      end
      if record.trig and self:is_ghost(record) then
        -- Ghost: dimmer than a normal trig, slowly pulsing in/out over 2s.
        local fade = (math.sin(util.time() * math.pi) + 1) / 2
        level = 2 + math.floor((fade * 3) + 0.5)
      end
    end
    if self.playing and index == self.play_index then
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
  local pattern_pages = self:pattern_pages()
  for x = 1, 16 do
    local level = x <= pattern_pages and 3 or 1
    if self.page_mode == "select" then
      level = x == self.selected_page and 12 or level
    elseif self.page_mode == "loop" then
      level = self.page_loop[x] and 9 or level
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
