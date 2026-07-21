local WavReader = {}

local function read_u16_le(bytes, offset)
  local b1, b2 = bytes:byte(offset, offset + 1)
  if b2 == nil then
    return nil
  end
  return b1 + (b2 * 256)
end

local function read_u32_le(bytes, offset)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  if b4 == nil then
    return nil
  end
  return b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
end

local function read_wav_sample(bytes, offset, bits_per_sample)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  if bits_per_sample == 8 and b1 ~= nil then
    return math.abs((b1 - 128) / 128)
  elseif bits_per_sample == 16 and b2 ~= nil then
    local value = b1 + (b2 * 256)
    if value >= 32768 then
      value = value - 65536
    end
    return math.abs(value / 32768)
  elseif bits_per_sample == 24 and b3 ~= nil then
    local value = b1 + (b2 * 256) + (b3 * 65536)
    if value >= 8388608 then
      value = value - 16777216
    end
    return math.abs(value / 8388608)
  elseif bits_per_sample == 32 and b4 ~= nil then
    local value = b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
    if value >= 2147483648 then
      value = value - 4294967296
    end
    return math.abs(value / 2147483648)
  end
  return 0
end

local function read_f32_le(bytes, offset)
  local raw = read_u32_le(bytes, offset)
  if raw == nil then
    return 0
  end

  local sign = raw >= 0x80000000 and -1 or 1
  local exponent = math.floor(raw / 0x800000) % 0x100
  local mantissa = raw % 0x800000
  if exponent == 0xff then
    return 0
  elseif exponent == 0 then
    return sign * (mantissa / 0x800000) * (2 ^ -126)
  end
  return sign * (1 + (mantissa / 0x800000)) * (2 ^ (exponent - 127))
end

local function read_wav_value(bytes, offset, bits_per_sample, audio_format)
  if audio_format == 3 and bits_per_sample == 32 then
    return math.abs(util.clamp(read_f32_le(bytes, offset), -1, 1))
  end
  return read_wav_sample(bytes, offset, bits_per_sample)
end

function WavReader.fallback_waveform(path, buckets)
  local seed = 0
  path = tostring(path or "")
  for i = 1, #path do
    seed = (seed + (path:byte(i) * i)) % 9973
  end

  local peaks = {}
  for i = 1, buckets do
    local a = math.sin((i + seed) * 0.19)
    local b = math.sin((i * 0.47) + (seed * 0.01))
    peaks[i] = util.clamp(0.18 + (math.abs(a * b) * 0.82), 0.05, 1)
  end
  return peaks
end

function WavReader.read_wav_waveform(path, buckets)
  local file = io.open(path, "rb")
  if file == nil then
    return nil
  end

  local header = file:read(12)
  if header == nil or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
    file:close()
    return nil
  end

  local audio_format = nil
  local channels = nil
  local block_align = nil
  local bits_per_sample = nil
  local data_start = nil
  local data_size = nil

  while true do
    local chunk_header = file:read(8)
    if chunk_header == nil or #chunk_header < 8 then
      break
    end

    local chunk_id = chunk_header:sub(1, 4)
    local chunk_size = read_u32_le(chunk_header, 5)
    local chunk_start = file:seek()
    if chunk_size == nil then
      break
    end

    if chunk_id == "fmt " then
      local fmt = file:read(math.min(chunk_size, 64))
      if fmt ~= nil and #fmt >= 16 then
        audio_format = read_u16_le(fmt, 1)
        channels = read_u16_le(fmt, 3)
        block_align = read_u16_le(fmt, 13)
        bits_per_sample = read_u16_le(fmt, 15)
        if audio_format == 65534 and #fmt >= 40 then
          local subformat = read_u16_le(fmt, 25)
          if subformat == 1 or subformat == 3 then
            audio_format = subformat
          end
        end
      end
    elseif chunk_id == "data" then
      data_start = chunk_start
      data_size = chunk_size
      break
    end

    file:seek("set", chunk_start + chunk_size + (chunk_size % 2))
  end

  if (audio_format ~= 1 and audio_format ~= 3) or channels == nil or block_align == nil
    or bits_per_sample == nil or data_start == nil or data_size == nil then
    file:close()
    return nil
  end

  local bytes_per_sample = bits_per_sample / 8
  if bytes_per_sample < 1 or bytes_per_sample > 4 then
    file:close()
    return nil
  end

  local frame_count = math.floor(data_size / block_align)
  if frame_count <= 0 then
    file:close()
    return nil
  end

  local peaks = {}
  for bucket = 1, buckets do
    local start_frame = math.floor(((bucket - 1) / buckets) * frame_count)
    local end_frame = math.max(start_frame, math.floor((bucket / buckets) * frame_count) - 1)
    local span = math.max(1, end_frame - start_frame + 1)
    local reads = math.min(32, span)
    local stride = math.max(1, math.floor(span / reads))
    local peak = 0
    local frame = start_frame

    while frame <= end_frame do
      file:seek("set", data_start + (frame * block_align))
      local frame_bytes = file:read(block_align)
      if frame_bytes == nil or #frame_bytes < block_align then
        break
      end

      for channel = 1, math.min(channels, 2) do
        local offset = 1 + ((channel - 1) * bytes_per_sample)
        if offset + bytes_per_sample - 1 <= #frame_bytes then
          peak = math.max(peak, read_wav_value(frame_bytes, offset, bits_per_sample, audio_format))
        end
      end
      frame = frame + stride
    end

    peaks[bucket] = util.clamp(peak, 0, 1)
  end

  file:close()

  -- Normalize for display: a quiet sample with no loud transients should
  -- still show a readable waveform, not a near-flat line at true scale.
  local max_peak = 0
  for _, value in ipairs(peaks) do
    max_peak = math.max(max_peak, value)
  end
  if max_peak > 0.001 and max_peak < 1 then
    local scale = 1 / max_peak
    for i, value in ipairs(peaks) do
      peaks[i] = util.clamp(value * scale, 0, 1)
    end
  end

  return peaks
end

return WavReader
