local Mode = {id = 3, name = "chopped"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "MACR", {lockable = true, min = 0, max = 1, step = 0.001, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("chop_steps", "CHOP", {lockable = true, min = 0.25, max = 16, step = 0.25, snaps = {0.25, 0.5, 1, 2, 4, 8, 16}}),
    Item.item("chop_loop_mode", "LOOP", {lockable = true, options = 3}),
    Item.item("chop_attack", "ATK", {lockable = true, min = 0.0001, max = 0.2, step = 0.0005, snaps = {0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2}}),
    Item.item("chop_hold", "HOLD", {lockable = true, min = 0, max = 0.5, step = 0.001, snaps = {0, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.5}}),
    Item.item("chop_release", "REL", {lockable = true, min = 0.0001, max = 0.2, step = 0.0005, snaps = {0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2}})
  }
end

return Mode
