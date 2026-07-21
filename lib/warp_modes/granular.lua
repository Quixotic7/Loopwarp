local Mode = {id = 4, name = "granular"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "MACR", {lockable = true, min = 0, max = 1, step = 0.001, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("grain_size", "GSIZ", {lockable = true, min = 0.002, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
    Item.item("grain_density", "GDEN", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64}}),
    Item.item("grain_jitter", "GJIT", {lockable = true, min = 0, max = 0.25, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25}})
  }
end

return Mode
