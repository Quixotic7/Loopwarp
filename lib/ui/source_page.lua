local SOURCE_CELL_X = {1, 33, 65, 97}
local SOURCE_CELL_WIDTH = 31
local SOURCE_CELL_HEIGHT = 11
local SOURCE_TOP_Y = 11
local SOURCE_WAVEFORM_Y = 23
local SOURCE_WAVEFORM_HEIGHT = 27
local SOURCE_BOTTOM_Y = 53

local SourcePage = {}
SourcePage.__index = SourcePage

-- Renders the Source category's pages: the main 4x2 param grid + waveform,
-- and the sample-edit/trim sub-page. Pure rendering, like param_renderer.lua --
-- value lookups (param_values) and navigation state (nav) are handed in as
-- objects, and coordinator-only helpers (draw_page_header, active_waveform,
-- active_region, display_phase, visual_param_value) as callbacks, so this
-- module never touches engine/param state directly.
function SourcePage.new(opts)
  opts = opts or {}
  return setmetatable({
    elasticat = opts.elasticat,
    MachineRegistry = opts.MachineRegistry,
    ParamRenderer = opts.ParamRenderer,
    param_values = opts.param_values,
    nav = opts.nav,
    param_value_or = opts.param_value_or,
    sample_name = opts.sample_name,
    draw_page_header = opts.draw_page_header,
    active_waveform = opts.active_waveform,
    active_region = opts.active_region,
    display_phase = opts.display_phase,
    visual_param_value = opts.visual_param_value,
    id = opts.id,
    get_alt = opts.get_alt,
    get_last_trim_focus = opts.get_last_trim_focus
  }, SourcePage)
end

function SourcePage:cell_geometry(index)
  local column = (index - 1) % 4
  local row = math.floor((index - 1) / 4)
  return SOURCE_CELL_X[column + 1], row == 0 and SOURCE_TOP_Y or SOURCE_BOTTOM_Y
end

function SourcePage:draw_box(x, y, inverted)
  if inverted then
    screen.level(15)
    screen.rect(x, y, SOURCE_CELL_WIDTH, SOURCE_CELL_HEIGHT)
    screen.fill()
  end
end

function SourcePage:draw_text(text, x, y, inverted)
  screen.level(inverted and 0 or 15)
  screen.move(x + math.floor(SOURCE_CELL_WIDTH / 2), y + 8)
  screen.text_center(tostring(text or ""))
end

function SourcePage:draw_pitch_ruler(param_item, x, y, inverted)
  local pitch = self.param_values:item_raw_value(param_item) or 0
  local dot_spacing = 3
  local octave_px = dot_spacing * 5
  local center_x = x + math.floor(SOURCE_CELL_WIDTH / 2)
  local text_y = y + 7
  local dot_y = y + SOURCE_CELL_HEIGHT - 2
  local level = inverted and 0 or 15

  -- Round the pitch offset once so every dot/label spacing below is pure
  -- integer arithmetic; rounding each element separately made neighboring
  -- gaps drift between 2 and 3 blank pixels as pitch changed continuously.
  local zero_x = math.floor(center_x - (pitch / 12 * octave_px) + 0.5)

  screen.level(level)
  for octave = -4, 4 do
    local octave_x = zero_x + (octave * octave_px)
    for dot = 1, 4 do
      local dot_x = octave_x + (dot * dot_spacing)
      if dot_x > x + 1 and dot_x < x + SOURCE_CELL_WIDTH - 1 then
        screen.pixel(dot_x, dot_y)
      end
    end
  end
  screen.fill()

  screen.level(level)
  for octave = -4, 4 do
    local label = tostring(octave)
    local octave_x = zero_x + (octave * octave_px)
    local half_width = math.ceil(screen.text_extents(label) / 2)
    if octave_x - half_width >= x + 1 and octave_x + half_width <= x + SOURCE_CELL_WIDTH - 1 then
      screen.move(octave_x, text_y)
      screen.text_center(label)
    end
  end
end

function SourcePage:draw_sample_slot_tab(param_item, x, y, inverted)
  local slot = math.floor((self.param_values:item_raw_value(param_item) or 1) + 0.5)
  local text = tostring(slot)
  local fg = inverted and 0 or 15
  local bg = inverted and 15 or 0

  screen.level(fg)
  screen.rect(x, y, SOURCE_CELL_WIDTH, SOURCE_CELL_HEIGHT)
  screen.fill()

  screen.level(bg)
  screen.rect(x + 7, y + 1, 23, 9)
  screen.fill()

  screen.level(bg)
  screen.pixel(x, y)
  screen.pixel(x, y + SOURCE_CELL_HEIGHT - 1)
  screen.fill()

  screen.level(fg)
  screen.move(x + 18, y + 8)
  screen.text_center(text)
end

function SourcePage:draw_main_cell(param_item, index, corner)
  local x, y = self:cell_geometry(index)
  local locked = self.param_values:item_locked(param_item)

  self:draw_box(x, y, locked)

  if corner ~= nil then
    self.ParamRenderer.draw_selection_corner(x, y, SOURCE_CELL_WIDTH, SOURCE_CELL_HEIGHT, corner)
  end

  if param_item == nil or param_item.blank then
    return
  elseif param_item.id == "pitch" then
    self:draw_pitch_ruler(param_item, x, y, locked)
  elseif param_item.id == "sample_slot" then
    self:draw_sample_slot_tab(param_item, x, y, locked)
  else
    local text = (self.param_values:item_value_flashing(param_item) or locked) and self.param_values:item_display_value(param_item) or (param_item.short or param_item.id)
    self:draw_text(text, x, y, locked)
  end
end

function SourcePage:draw_waveform_marker(position, x0, y0, width, height, kind)
  local x = x0 + math.floor(((width - 1) * util.clamp(position, 0, 128) / 128) + 0.5)
  self:draw_marker_at_px(x, y0, height, kind)
end

function SourcePage:draw_marker_at_px(x, y0, height, kind)
  screen.rect(x, y0, 1, height)
  screen.fill()

  if kind == "start" then
    screen.move(x, y0 + 2)
    screen.line(x + 3, y0)
    screen.move(x, y0 + 2)
    screen.line(x + 3, y0 + 4)
    screen.stroke()
  elseif kind == "end" then
    screen.move(x, y0 + 2)
    screen.line(x - 3, y0)
    screen.move(x, y0 + 2)
    screen.line(x - 3, y0 + 4)
    screen.stroke()
  end
end

function SourcePage:group_has_trim_items()
  local left, right = self.nav:current_group_items()
  return (left ~= nil and (left.id == "trim_start" or left.id == "trim_end"))
    or (right ~= nil and (right.id == "trim_start" or right.id == "trim_end"))
end

function SourcePage:draw_waveform(opts)
  opts = opts or {}
  local x0 = opts.x or 3
  local y0 = opts.y or 24
  local width = opts.width or 122
  local height = opts.height or 22
  local center = y0 + math.floor(height / 2)
  local waveform = self.active_waveform()
  local slot = self.elasticat.active_pool_slot ~= nil and self.elasticat.active_pool_slot() or 1
  local meta = self.elasticat.pool_meta ~= nil and self.elasticat.pool_meta(slot) or {}
  local duration = meta.duration or 0
  local trim_start = meta.trim_start or 0
  local trim_end = meta.trim_end or duration
  local trim_lo = 0
  local trim_hi = 1
  if duration > 0 then
    trim_lo = util.clamp(trim_start / duration, 0, 1)
    trim_hi = util.clamp(trim_end / duration, trim_lo, 1)
  end
  local view_lo = opts.sample_edit and 0 or trim_lo
  local view_hi = opts.sample_edit and 1 or trim_hi

  if opts.sample_edit and self.get_alt() and duration > 0 and self:group_has_trim_items() then
    local last_trim_focus = self.get_last_trim_focus()
    local focus = last_trim_focus == "trim_end" and trim_end or trim_start
    local zoom_span = util.clamp(0.5 / duration, 0.02, 0.2)
    local focus_fraction = util.clamp(focus / duration, 0, 1)
    view_lo = util.clamp(focus_fraction - (zoom_span / 2), 0, math.max(0, 1 - zoom_span))
    view_hi = util.clamp(view_lo + zoom_span, view_lo + 0.001, 1)
  end

  screen.level(2)
  screen.rect(x0, y0, width, 1)
  screen.fill()
  screen.rect(x0, y0 + height - 1, width, 1)
  screen.fill()
  screen.rect(x0, y0, 1, height)
  screen.fill()
  screen.rect(x0 + width - 1, y0, 1, height)
  screen.fill()

  if waveform == nil then
    screen.level(5)
    screen.move(x0 + math.floor(width / 2), y0 + math.floor(height / 2) + 3)
    screen.text_center("NO SAMPLE")
    return
  end

  local gain = meta.gain or 1
  screen.level(6)
  for column = 0, width - 1 do
    local fraction = view_lo + ((view_hi - view_lo) * (column / math.max(1, width - 1)))
    local index = math.floor(fraction * (#waveform - 1)) + 1
    local peak = util.clamp((waveform[index] or 0) * gain, 0, 1)
    local amp = math.max(1, math.floor((height / 2) * peak))
    local top = util.clamp(center - amp, y0, y0 + height - 1)
    local bottom = util.clamp(center + amp, y0, y0 + height - 1)
    screen.rect(x0 + column, top, 1, bottom - top + 1)
    screen.fill()
  end

  if opts.show_slices then
    local slice_count = util.clamp(math.floor((params:get(self.id("slice_count")) or 1) + 0.5), 1, 32)
    screen.level(3)
    for slice = 1, slice_count - 1 do
      local x = x0 + math.floor((width * slice / slice_count) + 0.5)
      screen.move(x, y0 + 1)
      screen.line(x, y0 + height - 1)
    end
    screen.stroke()
  end

  local start_point, end_point = self.active_region()
  local phase = util.clamp(self.display_phase(), 0, 1)
  local position = util.clamp(start_point + ((end_point - start_point) * phase), 0, 128)
  local visual_start = self.visual_param_value("loop_start", 0)
  local visual_end = self.visual_param_value("loop_end", 128)
  local function draw_fraction_marker(fraction, kind)
    if view_hi <= view_lo or fraction < view_lo or fraction > view_hi then
      return
    end
    self:draw_waveform_marker(((fraction - view_lo) / (view_hi - view_lo)) * 128, x0, y0, width, height, kind)
  end

  if opts.sample_edit then
    screen.level(9)
    if duration > 0 and view_hi > view_lo then
      -- Anchor the end marker's rounding to the start marker's so the pixel gap
      -- between them stays constant while trim start scrubs (they move by an
      -- equal delta). Rounding each independently made the gap jitter by a pixel
      -- as the sub-pixel remainders drifted past .5 at different moments.
      local start_frac = util.clamp(trim_start / duration, 0, 1)
      local end_frac = util.clamp(trim_end / duration, 0, 1)
      local span = view_hi - view_lo
      local start_exact = (width - 1) * ((start_frac - view_lo) / span)
      local end_exact = (width - 1) * ((end_frac - view_lo) / span)
      local start_px = math.floor(start_exact + 0.5)
      local end_px = start_px + math.floor((end_exact - start_exact) + 0.5)
      if start_frac >= view_lo and start_frac <= view_hi then
        self:draw_marker_at_px(x0 + util.clamp(start_px, 0, width - 1), y0, height, "start")
      end
      if end_frac >= view_lo and end_frac <= view_hi then
        self:draw_marker_at_px(x0 + util.clamp(end_px, 0, width - 1), y0, height, "end")
      end
    else
      draw_fraction_marker(duration > 0 and (trim_start / duration) or 0, "start")
      draw_fraction_marker(duration > 0 and (trim_end / duration) or 1, "end")
    end
  else
    screen.level(9)
    self:draw_waveform_marker(visual_start, x0, y0, width, height, "start")
    self:draw_waveform_marker(visual_end, x0, y0, width, height, "end")

    screen.level(15)
    self:draw_waveform_marker(position, x0, y0, width, height, nil)
  end
end

function SourcePage:draw_sample_cell(param_item, index, corner)
  if param_item == nil then
    return
  end

  local column = (index - 1) % 4
  local row = math.floor((index - 1) / 4)
  local x = column * 32
  local y = row == 0 and 19 or 59
  local width = 30

  if corner ~= nil then
    self.ParamRenderer.draw_selection_corner(x, y - 8, width, 11, corner)
  end

  if param_item.blank then
    return
  end

  local text = (self.param_values:item_value_flashing(param_item) or self.param_values:item_locked(param_item)) and self.param_values:item_display_value(param_item) or (param_item.short or param_item.id)

  screen.level(self.param_values:item_locked(param_item) and 12 or (corner ~= nil and 15 or 9))
  screen.move(x + 2, y)
  self.ParamRenderer.draw_cell_value(text, width - 4)
end

function SourcePage:draw_main_page(items, page_number)
  local machine = self.param_value_or("machine", 1)
  self.draw_page_header("", page_number)
  self:draw_waveform({
    x = 1,
    y = SOURCE_WAVEFORM_Y,
    width = 127,
    height = SOURCE_WAVEFORM_HEIGHT,
    show_slices = self.MachineRegistry.is_slice(machine)
  })

  local selected_start = ((self.nav:clamp_current_group() - 1) * 2) + 1
  for i = 1, 8 do
    local param_item = items[i]
    local corner = nil
    if i == selected_start then
      corner = "tl"
    elseif i == selected_start + 1 then
      corner = "br"
    end
    self:draw_main_cell(param_item, i, corner)
  end
end

function SourcePage:draw_sample_page(page, items)
  local slot = self.elasticat.active_pool_slot ~= nil and self.elasticat.active_pool_slot() or self.param_value_or("sample_slot", 1)
  local page_index = self.nav.page_index_by_category.source or 1
  if page_index == 1 then
    self:draw_main_page(items, page_index)
    return
  end

  self.draw_page_header(string.format("%03d %s", slot, self.sample_name()), page_index)
  self:draw_waveform({
    show_slices = false,
    sample_edit = page_index == 3
  })

  local selected_start = ((self.nav:clamp_current_group() - 1) * 2) + 1
  for i, param_item in ipairs(items) do
    local corner = nil
    if i == selected_start then
      corner = "tl"
    elseif i == selected_start + 1 then
      corner = "br"
    end
    self:draw_sample_cell(param_item, i, corner)
  end
end

return SourcePage
