local Registry = {}

local modes = {
  [1] = include("lib/warp_modes/tape"),
  [2] = include("lib/warp_modes/tempo_varispeed"),
  [3] = include("lib/warp_modes/chopped"),
  [4] = include("lib/warp_modes/granular"),
  [5] = include("lib/warp_modes/random_ola"),
  [6] = include("lib/warp_modes/pitch_corrected")
}

function Registry.get(mode_id)
  return modes[math.floor((tonumber(mode_id) or 1) + 0.5)] or modes[1]
end

function Registry.source_items(mode_id, Item)
  local mode = Registry.get(mode_id)
  return mode.source_items ~= nil and mode.source_items(Item) or {}
end

return Registry
