local ParamItem = {}

function ParamItem.item(param_id, short, opts)
  opts = opts or {}
  opts.id = param_id
  opts.short = short
  opts.lock_id = opts.lock_id or param_id
  return opts
end

function ParamItem.blank()
  return {blank = true, short = "---", lockable = false}
end

return ParamItem
