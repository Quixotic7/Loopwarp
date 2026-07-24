local ParamItem = include("lib/ui/param_item")
local item = ParamItem.item
local blank = ParamItem.blank

local page_model = {
  master = {
    title = "MASTER",
    pages = {
      {
        title = "MASTER",
        items = {
          item("target_bpm", "BPM", {lockable = false, min = 20, max = 300, step = 1, snaps = {60, 80, 90, 100, 110, 120, 128, 136, 140, 160, 180}}),
          item("amp", "VOL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 100, 127}})
        }
      },
      {
        -- Full-screen looping sprite + grid comet sweep, tempo-scaled. The
        -- coordinator detects `animation` and renders it with no header/UI.
        title = "VISUALIZER",
        items = {},
        animation = true
      }
    },
    settings = {
      item("clock_sync", "SYNC", {binary = true, min = 0, max = 1, step = 1}),
      item("live_performance_mode", "LPRF", {binary = true, min = 0, max = 1, step = 1}),
      item("step_preview", "PREV", {binary = true, min = 0, max = 1, step = 1}),
      item("live_step_trig", "LTRG", {binary = true, min = 0, max = 1, step = 1}),
      item("debug", "DBG", {options = 4})
    }
  },
  pattern = {
    title = "PATTERN",
    pages = {
      {
        title = "PATTERN",
        items = {
          item("pattern_steps", "LEN", {lockable = false, min = 1, max = 256, step = 1, snaps = {4, 8, 16, 32, 48, 64, 96, 128, 256}}),
          item("pattern_rate", "RATE", {pseudo = "pattern_rate", lockable = false, min = 1, max = 8, step = 1, options = 8})
        }
      }
    },
    settings = {
      item("pattern_rate", "RATE", {pseudo = "pattern_rate", options = 8})
    }
  },
  trig = {
    title = "TRIG",
    pages = {
      {
        -- Page 1: trig params common to every machine.
        title = "TRIG",
        items = {
          item("pitch", "NOTE", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
          item("default_length", "LEN", {lock_id = "length", lockable = true, min = 0.25, max = 16, step = 0.25, snaps = {0.25, 0.5, 1, 2, 4, 8, 16}}),
          item("default_velocity", "VEL", {lock_id = "velocity", lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
          blank(),
          item("env_reset", "ERST", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("lfo_reset", "LRST", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("filter_reset", "FRST", {lockable = true, binary = true, min = 0, max = 1, step = 1})
        }
      },
      {
        -- Page 2: machine trig behaviour. Items are resolved dynamically in
        -- page_items_for (empty for slice machines); this is the fallback.
        title = "MACHINE TRIG",
        items = {
          item("trig_jump", "JUMP", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("trig_release", "RLSE", {lockable = true, options = 3})
        }
      }
    },
    settings = {}
  },
  source = {
    title = "SOURCE",
    pages = {
      {
        title = "SOURCE",
        items = {
          item("sample_slot", "SLOT", {lockable = true, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
          item("loop_start", "STRT", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
          item("loop_end", "END", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
          item("loop_reverse", "LREV", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("slice_reverse", "SREV", {lockable = true, binary = true, min = 0, max = 1, step = 1})
        }
      },
      {
        title = "MACHINE",
        items = {}
      },
      {
        title = "WARP",
        items = {
          item("mode_macro", "MACR", {lockable = true, min = 0, max = 1, step = 0.001, snaps = {0, 0.25, 0.5, 0.75, 1}}),
          item("chop_steps", "CHOP", {lockable = true, min = 0.25, max = 16, step = 0.25, snaps = {0.25, 0.5, 1, 2, 4, 8, 16}}),
          item("chop_loop_mode", "LOOP", {lockable = true, options = 3}),
          item("grain_size", "GSIZ", {lockable = true, min = 0.002, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
          item("grain_density", "GDEN", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64}}),
          item("grain_jitter", "GJIT", {lockable = true, min = 0, max = 0.25, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25}}),
          item("wsola_window", "OWIN", {lockable = true, min = 0.005, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
          item("wsola_search", "OWAN", {lockable = true, min = 0, max = 0.1, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1}})
        }
      },
      {
        title = "RANGE",
        items = {
          item("range_start", "R-ST", {lockable = true, fn_snap_multiple = 8, min = 0, max = 128, step = 1}),
          item("range_end", "R-EN", {lockable = true, fn_snap_multiple = 8, min = 0, max = 128, step = 1}),
          item("range_end_sync", "E-SNC", {lockable = false, binary = true, min = 0, max = 1, step = 1})
        }
      }
    },
    settings = {
      item("machine", "MACH", {options = 4}),
      item("loop_division", "LDIV", {lockable = false, min = 2, max = 32, step = 2, snaps = {2, 4, 8, 16, 32}}),
      item("trig_polyphony", "POLY", {options = 2}),
      item("playhead_return", "PHED", {options = 3})
    }
  },
  file = {
    title = "FILE",
    pages = {
      {
        title = "SAMPLE",
        items = {
          item("sample_bpm", "BPM", {lockable = false, always_value = true, min = 20, max = 300, step = 1, snaps = {60, 80, 90, 100, 110, 120, 128, 136, 140, 160, 180}}),
          item("sample_steps", "STEP", {lockable = false, always_value = true, min = 1, max = 512, step = 1, snaps = {4, 8, 16, 32, 48, 64, 96, 128, 256, 512}}),
          item("sample", "FILE", {file = true, lockable = false}),
          item("file_slot", "SLOT", {lockable = false, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
          item("trim_start", "T-ST", {lockable = false, trim_scan = true, min = 0, max = 3600, step = 0.01, fine_step = 0.001}),
          item("trim_end", "T-EN", {lockable = false, trim_scan = true, min = 0, max = 3600, step = 0.01, fine_step = 0.001}),
          item("gain", "GAIN", {lockable = false, min = 0, max = 4, step = 0.01, snaps = {0, 0.5, 1, 1.5, 2, 3, 4}}),
          item("sample_preview", "PREV", {lockable = false, binary = true, min = 0, max = 1, step = 1})
        }
      }
    },
    settings = {
      item("bpm_step_mode", "BPM/STEP MODE", {options = 4}),
      item("recalc_bpm_steps", "RECALC BPM/STEP", {options = 2})
    }
  },
  filter = {
    title = "FILTER",
    pages = {
      {title = "FILTER", items = {}}
    },
    settings = {}
  },
  amp = {
    title = "AMP",
    pages = {
      {
        -- Items are resolved dynamically per envelope mode in page_items_for
        -- (ADSR vs AHR); this static list is the AHR-default fallback.
        title = "AMP",
        items = {
          item("env_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1}),
          item("env_hold", "HOLD", {lockable = true, min = 0, max = 128, step = 1}),
          item("env_release", "REL", {lockable = true, min = 0, max = 128, step = 1}),
          blank(),
          blank(),
          blank(),
          item("pan", "PAN", {lockable = true, min = 0, max = 128, step = 1}),
          item("amp", "VOL", {lockable = true, min = 0, max = 127, step = 1})
        }
      }
    },
    settings = {
      item("env_mode", "ENVELOPE MODE", {options = 2}),
      item("env_range", "ENVELOPE RANGE", {options = 10}),
      item("portamento", "PORTAMENTO", {binary = true, min = 0, max = 1, step = 1}),
      item("slice_hold_to_step", "SLICE HOLD", {binary = true, min = 0, max = 1, step = 1}),
      item("slice_polyphony", "SLICE POLY", {options = 2})
    }
  },
  fx = {
    title = "FX",
    pages = {
      {title = "FX", items = {}}
    },
    settings = {}
  },
  mod = {
    title = "MOD",
    pages = {
      {title = "MOD", items = {}}
    },
    settings = {}
  }
}

return page_model
