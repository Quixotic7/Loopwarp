local PageModel = include("lib/pages/model")
local ParamBank = include("lib/ui/param_bank")

local CATEGORY_ORDER = {"master", "file", "pattern", "trig", "source", "filter", "amp", "fx", "mod"}

local Navigation = {}
Navigation.__index = Navigation

Navigation.CATEGORY_ORDER = CATEGORY_ORDER

-- Owns which category/page/K2-K3 pair/settings-item is currently selected, and
-- the index arithmetic for moving between them. Does not resolve *what items*
-- a page shows (that needs MachineRegistry/WarpRegistry/params, so it stays
-- with the caller-supplied page_items_for callback) -- this module is purely
-- the selection state machine, matching the GridSequencer.new() dependency
-- style already used elsewhere in this script.
function Navigation.new(opts)
  opts = opts or {}
  return setmetatable({
    page_items_for = opts.page_items_for,
    show_message = opts.show_message,
    request_redraw = opts.request_redraw,
    on_navigate = opts.on_navigate or function() end,
    category_index = 1,
    page_index_by_category = {},
    group_index_by_page = {},
    settings_layer = false,
    settings_category_index = 1,
    settings_item_index = {}
  }, Navigation)
end

function Navigation:category_position(category)
  for i, name in ipairs(CATEGORY_ORDER) do
    if name == category then
      return i
    end
  end
  return 1
end

function Navigation:category_model(category)
  return PageModel[category or CATEGORY_ORDER[self.category_index]] or PageModel.master
end

function Navigation:current_category()
  return CATEGORY_ORDER[self.category_index] or "master"
end

function Navigation:current_page()
  local category = self:current_category()
  local model = self:category_model(category)
  local pages = model.pages or {}
  local index = util.clamp(self.page_index_by_category[category] or 1, 1, math.max(1, #pages))
  self.page_index_by_category[category] = index
  return pages[index] or {title = model.title, items = {}}, index, model
end

function Navigation:current_page_items()
  local category = self:current_category()
  local page, page_index = self:current_page()
  return self.page_items_for(category, page, page_index)
end

function Navigation:current_pair_count()
  return ParamBank.new(self:current_page_items()):pair_count()
end

function Navigation:current_group_key()
  local _, page_index = self:current_page()
  return self:current_category() .. ":" .. page_index
end

-- Each page remembers its own last-selected K2/K3 parameter pair for the
-- session, so switching pages doesn't reset the pair back to the first one.
-- This is intentionally not a norns param and is not saved with the pset.
function Navigation:clamp_current_group()
  local key = self:current_group_key()
  local clamped = ParamBank.new(self:current_page_items()):clamp_group(self.group_index_by_page[key])
  self.group_index_by_page[key] = clamped
  return clamped
end

function Navigation:current_group_items()
  local group = self:clamp_current_group()
  return ParamBank.new(self:current_page_items()):group_items(group)
end

function Navigation:cycle_group(delta)
  local pair_count = self:current_pair_count()
  local key = self:current_group_key()
  local current = self.group_index_by_page[key] or 1
  self.group_index_by_page[key] = ((current - 1 + delta) % pair_count) + 1
end

function Navigation:select_category(category)
  self.on_navigate()
  if category == self:current_category() then
    local model = self:category_model(category)
    local pages = model.pages or {}
    self.page_index_by_category[category] = ((self.page_index_by_category[category] or 1) % math.max(1, #pages)) + 1
  else
    self.category_index = self:category_position(category)
  end
  local page = self:current_page()
  self.show_message(page.title or self:category_model(category).title)
  self.request_redraw()
end

function Navigation:select_page_delta(delta)
  self.on_navigate()
  local category = self:current_category()
  local model = self:category_model(category)
  local pages = model.pages or {}
  local count = math.max(1, #pages)
  self.page_index_by_category[category] = (((self.page_index_by_category[category] or 1) - 1 + delta) % count) + 1
  local page = self:current_page()
  self.show_message(page.title or model.title)
  self.request_redraw()
end

function Navigation:select_global_page_delta(delta)
  self.on_navigate()
  local category = self:current_category()
  local model = self:category_model(category)
  local pages = model.pages or {}
  local page_index = self.page_index_by_category[category] or 1

  page_index = page_index + delta
  while page_index < 1 do
    self.category_index = ((self.category_index - 2) % #CATEGORY_ORDER) + 1
    category = self:current_category()
    model = self:category_model(category)
    pages = model.pages or {}
    page_index = math.max(1, #pages)
  end
  while page_index > math.max(1, #pages) do
    self.category_index = (self.category_index % #CATEGORY_ORDER) + 1
    category = self:current_category()
    model = self:category_model(category)
    pages = model.pages or {}
    page_index = 1
  end

  self.page_index_by_category[category] = page_index
  local page = self:current_page()
  self.show_message(page.title or model.title)
  self.request_redraw()
end

function Navigation:current_settings_category()
  return CATEGORY_ORDER[self.settings_category_index] or self:current_category()
end

function Navigation:settings_items()
  local category = self:current_settings_category()
  return self:category_model(category).settings or {}
end

function Navigation:open_param_settings(category)
  self.on_navigate()
  self.settings_layer = true
  local position = self:category_position(category or self:current_category())
  self.category_index = position
  self.settings_category_index = position
  local settings_category = self:current_settings_category()
  self.settings_item_index[settings_category] = self.settings_item_index[settings_category] or 1
  self.show_message(self:category_model(settings_category).title .. " SETTINGS")
  self.request_redraw()
end

function Navigation:close_param_settings()
  self.on_navigate()
  self.settings_layer = false
  self.show_message((self:current_page()).title)
  self.request_redraw()
end

function Navigation:return_to_param_category(category)
  self.on_navigate()
  self.settings_layer = false
  self.category_index = self:category_position(category or self:current_category())
  self.settings_category_index = self.category_index
  local page = self:current_page()
  self.show_message(page.title or self:category_model(self:current_category()).title)
  self.request_redraw()
end

function Navigation:settings_select_delta(delta)
  local category = self:current_settings_category()
  local items = self:settings_items()
  local count = math.max(1, #items)
  self.settings_item_index[category] = util.clamp((self.settings_item_index[category] or 1) + delta, 1, count)
  self.request_redraw()
end

function Navigation:settings_category_delta(delta)
  self.settings_category_index = ((self.settings_category_index - 1 + delta) % #CATEGORY_ORDER) + 1
  self.category_index = self.settings_category_index
  local settings_category = self:current_settings_category()
  self.settings_item_index[settings_category] = self.settings_item_index[settings_category] or 1
  self.show_message(self:category_model(settings_category).title .. " SETTINGS")
  self.request_redraw()
end

return Navigation
