--[[
  REAPER Vocal Autopilot — v2

  Что нового:
    * Добавлена схема сведения, основанная на анализе загруженных стемов (бит RMS -16.9 dBFS, пик -4.3 dBFS, акцент 3–6 кГц; референс вокала — сверхвоздушный, но очень тихий),
      поэтому цепочки FX сфокусированы на контроле верхней середины, подчистке низов и подчёркивании присутствия без лишней резкости.
    * Скрипт ожидает, что первый трек — бит, остальные вокальные тейки. Он переименует их, добавит обработку, создаст вокальные шины,
      параллельную компрессию, отдельные Aux для реверба и слэп-делея, а также мастер-шину с метрингом.
    * Добавлен трек Reference (без посыла на мастер) — перетащи туда эталонный микс для A/B.

  Как запускать:
    1. В проекте размести бит на первом треке (левый канал дорожки 1), вокальные тейки — на следующих треках (один тейк = один трек).
       Если есть только один вокал — оставь его вторым треком, скрипт создаст клоны для дублей/бэков.
    2. Выдели только бит и ключевые вокальные треки (по порядку) и запусти скрипт через Actions → Run. Если ничего не выделено —
       он возьмёт первый трек как бит, остальные — как вокалы.
    3. После выполнения проверь, что элементы перемещены корректно, и отрегулируй send уровни (Aux Reverb/Delay, Parallel Crush) под вкус.
       Мастер готов к рендеру 48 кГц/24 бит, лимитер прижат к -1 dBTP, целевой RMS ≈ -11…-10 dBFS.
]]

local project = 0

local function freq_to_norm(freq)
  local min_f, max_f = 10, 20000
  if freq < min_f then freq = min_f end
  if freq > max_f then freq = max_f end
  return math.log(freq / min_f) / math.log(max_f / min_f)
end

local EQ_TYPES = {
  BAND = 0.0,
  LOW_SHELF = 0.125,
  HIGH_SHELF = 0.25,
  LOW_PASS = 0.375,
  HIGH_PASS = 0.5,
  NOTCH = 0.625,
  BAND_PASS = 0.75
}

local colors = {
  beat = {184, 115, 51},
  lead = {177, 57, 73},
  doubles = {204, 102, 102},
  backs = {108, 26, 117},
  air = {133, 180, 255},
  bus = {220, 124, 17},
  verb = {44, 131, 214},
  delay = {68, 171, 116},
  parallel = {112, 112, 112},
  reference = {90, 90, 90}
}

local function color_to_native(rgb)
  if not rgb then return 0 end
  return reaper.ColorToNative(rgb[1], rgb[2], rgb[3]) | 0x1000000
end

local function set_track_color(track, rgb)
  if not track or not rgb then return end
  reaper.SetTrackColor(track, color_to_native(rgb))
end

local function set_rea_eq_band(track, fx, band_index, params)
  local base = (band_index - 1) * 4
  if params.freq then
    reaper.TrackFX_SetParamNormalized(track, fx, base, freq_to_norm(params.freq))
  end
  if params.gain then
    reaper.TrackFX_SetParam(track, fx, base + 1, params.gain)
  end
  if params.q then
    reaper.TrackFX_SetParam(track, fx, base + 2, params.q)
  end
  if params.type then
    reaper.TrackFX_SetParamNormalized(track, fx, base + 3, params.type)
  end
end

local function configure_rea_eq(track, fx, profile)
  if profile.band_count then
    reaper.TrackFX_SetNamedConfigParm(track, fx, "BANDCOUNT", tostring(profile.band_count))
  end
  for _, band in ipairs(profile) do
    set_rea_eq_band(track, fx, band.index, band)
  end
end

local function ensure_fx(track, fx_desc)
  local fx_index = reaper.TrackFX_AddByName(track, fx_desc.name, false, 1)
  if fx_desc.config then
    fx_desc.config(track, fx_index)
  end
  if fx_desc.post then
    fx_desc.post(track, fx_index)
  end
  return fx_index
end

local function rename_track(track, new_name)
  if track and new_name then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", new_name, true)
  end
end

local function assign_pan(track, pan)
  if track and pan ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan)
  end
end

local function assign_volume(track, vol)
  if track and vol ~= nil then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", vol)
  end
end

local function ensure_channels(track, channels)
  if track and channels then
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", channels)
  end
end

local function disable_master_send(track)
  if track then
    reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
  end
end

local function ensure_track_at(index)
  if index >= reaper.CountTracks(project) then
    reaper.InsertTrackAtIndex(index, true)
  end
  return reaper.GetTrack(project, index)
end

local function find_or_create_named_track(name, color)
  for i = 0, reaper.CountTracks(project) - 1 do
    local track = reaper.GetTrack(project, i)
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if track_name == name then
      return track
    end
  end
  local track = ensure_track_at(reaper.CountTracks(project))
  rename_track(track, name)
  set_track_color(track, color)
  return track
end

local function add_send(src, dest, opts)
  local send_idx = reaper.CreateTrackSend(src, dest)
  if opts then
    if opts.src_chan then
      reaper.SetTrackSendInfo_Value(src, 0, send_idx, "I_SRCCHAN", opts.src_chan)
    end
    if opts.dest_chan then
      reaper.SetTrackSendInfo_Value(src, 0, send_idx, "I_DSTCHAN", opts.dest_chan)
    end
    if opts.volume then
      reaper.SetTrackSendInfo_Value(src, 0, send_idx, "D_VOL", opts.volume)
    end
    if opts.mute then
      reaper.SetTrackSendInfo_Value(src, 0, send_idx, "B_MUTE", opts.mute)
    end
    if opts.phase_invert then
      reaper.SetTrackSendInfo_Value(src, 0, send_idx, "B_PHASE", opts.phase_invert)
    end
  end
  return send_idx
end

local function collect_user_tracks()
  local selected = {}
  local sel_count = reaper.CountSelectedTracks(project)
  if sel_count > 0 then
    for i = 0, sel_count - 1 do
      selected[#selected + 1] = reaper.GetSelectedTrack(project, i)
    end
  else
    for i = 0, reaper.CountTracks(project) - 1 do
      selected[#selected + 1] = reaper.GetTrack(project, i)
    end
  end
  if #selected == 0 then
    return nil, {}
  end
  local beat = selected[1]
  local vocals = {}
  for i = 2, #selected do
    vocals[#vocals + 1] = selected[i]
  end
  return beat, vocals
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local beat_track, vocal_tracks = collect_user_tracks()
if not beat_track then
  reaper.ShowMessageBox("Не найдено ни одного трека. Добавь бит и вокал в проект и повтори.", "Autopilot", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Autopilot aborted", -1)
  return
end

set_track_color(beat_track, colors.beat)
rename_track(beat_track, "Beat - Instrumental")
ensure_channels(beat_track, 2)
assign_volume(beat_track, 0.95)

local beat_fx = {
  {
    name = "ReaEQ (Cockos)",
    config = function(track, fx)
      configure_rea_eq(track, fx, {
        band_count = 4,
        { index = 1, freq = 32, gain = 0.0, q = 0.707, type = EQ_TYPES.HIGH_PASS },
        { index = 2, freq = 320, gain = -1.2, q = 1.1, type = EQ_TYPES.BAND },
        { index = 3, freq = 3600, gain = -1.0, q = 1.2, type = EQ_TYPES.BAND },
        { index = 4, freq = 11000, gain = -0.8, q = 0.7, type = EQ_TYPES.HIGH_SHELF }
      })
    end
  },
  {
    name = "ReaComp (Cockos)",
    config = function(track, fx)
      reaper.TrackFX_SetParam(track, fx, 0, -8.0)   -- Threshold
      reaper.TrackFX_SetParam(track, fx, 2, 15.0)   -- Attack (ms)
      reaper.TrackFX_SetParam(track, fx, 3, 120.0)  -- Release (ms)
      reaper.TrackFX_SetParam(track, fx, 5, 2.3)    -- Ratio
      reaper.TrackFX_SetParam(track, fx, 6, 0.0)    -- Knee hard
      reaper.TrackFX_SetParam(track, fx, 7, 0.0)    -- Auto make-up off
      reaper.TrackFX_SetParam(track, fx, 8, 0.0)    -- Pre-comp off
    end
  },
  {
    name = "JS: Saturation", -- лёгкая гармоника, чтобы подтянуть низ-середину
    config = function(track, fx)
      reaper.TrackFX_SetParam(track, fx, 0, 0.10)
    end
  }
}

for _, fx in ipairs(beat_fx) do
  ensure_fx(beat_track, fx)
end

local vocal_slots = {
  {
    name = "Lead Main", color = colors.lead, pan = 0.0, vol = 1.05,
  },
  { name = "Lead Double L", color = colors.doubles, pan = -0.55, vol = 0.88 },
  { name = "Lead Double R", color = colors.doubles, pan = 0.55, vol = 0.88 },
  { name = "Back Vox L", color = colors.backs, pan = -0.7, vol = 0.78 },
  { name = "Back Vox R", color = colors.backs, pan = 0.7, vol = 0.78 },
  { name = "Air Vox L", color = colors.air, pan = -0.8, vol = 0.65 },
  { name = "Air Vox R", color = colors.air, pan = 0.8, vol = 0.65 }
}

local function setup_vocal_fx(track)
  ensure_channels(track, 2)
  local eq_index = ensure_fx(track, {
    name = "ReaEQ (Cockos)",
    config = function(t, fx)
      configure_rea_eq(t, fx, {
        band_count = 4,
        { index = 1, freq = 80, gain = 0.0, q = 0.707, type = EQ_TYPES.HIGH_PASS },
        { index = 2, freq = 280, gain = -1.8, q = 1.1, type = EQ_TYPES.BAND },
        { index = 3, freq = 3200, gain = 2.2, q = 1.0, type = EQ_TYPES.BAND },
        { index = 4, freq = 12500, gain = 1.5, q = 0.8, type = EQ_TYPES.HIGH_SHELF }
      })
    end
  })

  ensure_fx(track, {
    name = "ReaComp (Cockos)",
    config = function(t, fx)
      reaper.TrackFX_SetParam(t, fx, 0, -16.0)  -- Threshold
      reaper.TrackFX_SetParam(t, fx, 2, 5.0)    -- Attack
      reaper.TrackFX_SetParam(t, fx, 3, 65.0)   -- Release
      reaper.TrackFX_SetParam(t, fx, 5, 3.8)    -- Ratio
      reaper.TrackFX_SetParam(t, fx, 6, 0.0)
      reaper.TrackFX_SetParam(t, fx, 7, 0.0)
      reaper.TrackFX_SetParam(t, fx, 8, 1.5)    -- Pre-comp 1.5 ms
    end
  })

  ensure_fx(track, {
    name = "ReaComp (Cockos)",
    config = function(t, fx)
      reaper.TrackFX_SetParam(t, fx, 0, -10.0)
      reaper.TrackFX_SetParam(t, fx, 2, 25.0)
      reaper.TrackFX_SetParam(t, fx, 3, 180.0)
      reaper.TrackFX_SetParam(t, fx, 5, 2.0)
      reaper.TrackFX_SetParam(t, fx, 6, 0.0)
      reaper.TrackFX_SetParam(t, fx, 7, 0.0)
    end
  })

  ensure_fx(track, {
    name = "JS: De-esser",
    config = function(t, fx)
      reaper.TrackFX_SetParam(t, fx, 0, 6200.0)
      reaper.TrackFX_SetParam(t, fx, 1, 7.5)
      reaper.TrackFX_SetParam(t, fx, 2, 0.45)
    end
  })

  ensure_fx(track, {
    name = "JS: Saturation",
    config = function(t, fx)
      reaper.TrackFX_SetParam(t, fx, 0, 0.12)
    end
  })

  ensure_fx(track, {
    name = "ReaDelay (Cockos)",
    config = function(t, fx)
      reaper.TrackFX_SetParam(t, fx, 0, -15.0)   -- Dry level off
      reaper.TrackFX_SetParam(t, fx, 1, -9.0)    -- Wet level
      reaper.TrackFX_SetParam(t, fx, 2, 0.28)    -- Feedback
      reaper.TrackFX_SetParam(t, fx, 3, 0.9)     -- Lowpass
      reaper.TrackFX_SetParam(t, fx, 4, 0.05)    -- Highpass
      reaper.TrackFX_SetParam(t, fx, 5, 2.0)     -- Delay time (beats)
      reaper.TrackFX_SetParam(t, fx, 7, 0.0)     -- Stereo offset
    end
  })
end

local created_vocals = {}

for idx, slot in ipairs(vocal_slots) do
  local track = vocal_tracks[idx] or ensure_track_at(reaper.CountTracks(project))
  created_vocals[#created_vocals + 1] = track
  rename_track(track, slot.name)
  set_track_color(track, slot.color)
  assign_pan(track, slot.pan)
  assign_volume(track, slot.vol)
  setup_vocal_fx(track)
end

local vocal_bus = find_or_create_named_track("Vocal Bus", colors.bus)
assign_pan(vocal_bus, 0.0)
assign_volume(vocal_bus, 1.0)
ensure_channels(vocal_bus, 2)
ensure_fx(vocal_bus, {
  name = "ReaEQ (Cockos)",
  config = function(track, fx)
    configure_rea_eq(track, fx, {
      band_count = 4,
      { index = 1, freq = 110, gain = -1.5, q = 1.0, type = EQ_TYPES.BAND },
      { index = 2, freq = 420, gain = -1.0, q = 1.1, type = EQ_TYPES.BAND },
      { index = 3, freq = 2800, gain = 1.2, q = 0.9, type = EQ_TYPES.BAND },
      { index = 4, freq = 9500, gain = 1.0, q = 0.7, type = EQ_TYPES.HIGH_SHELF }
    })
  end
})
ensure_fx(vocal_bus, {
  name = "ReaComp (Cockos)",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, -9.0)
    reaper.TrackFX_SetParam(track, fx, 2, 18.0)
    reaper.TrackFX_SetParam(track, fx, 3, 140.0)
    reaper.TrackFX_SetParam(track, fx, 5, 2.4)
    reaper.TrackFX_SetParam(track, fx, 6, 0.0)
    reaper.TrackFX_SetParam(track, fx, 7, 0.0)
  end
})
ensure_fx(vocal_bus, {
  name = "JS: Saturation",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, 0.08)
  end
})

local verb_aux = find_or_create_named_track("Vox Verb Aux", colors.verb)
assign_volume(verb_aux, 0.7)
ensure_fx(verb_aux, {
  name = "ReaVerbate (Cockos)",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, 0.45) -- Room size
    reaper.TrackFX_SetParam(track, fx, 1, 0.55) -- Damping
    reaper.TrackFX_SetParam(track, fx, 2, 0.32) -- Bass mult
    reaper.TrackFX_SetParam(track, fx, 3, 0.45) -- Early level
    reaper.TrackFX_SetParam(track, fx, 4, 0.35) -- Tail level
  end
})

local delay_aux = find_or_create_named_track("Vox Delay Aux", colors.delay)
assign_volume(delay_aux, 0.65)
ensure_fx(delay_aux, {
  name = "ReaDelay (Cockos)",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, -12.0)
    reaper.TrackFX_SetParam(track, fx, 1, -6.0)
    reaper.TrackFX_SetParam(track, fx, 2, 0.35)
    reaper.TrackFX_SetParam(track, fx, 5, 1.0)  -- Quarter note
    reaper.TrackFX_SetParam(track, fx, 6, 0.25) -- Offset right
  end
})

local parallel_bus = find_or_create_named_track("Parallel Crush", colors.parallel)
assign_volume(parallel_bus, 0.4)
ensure_channels(parallel_bus, 2)
disable_master_send(parallel_bus)
ensure_fx(parallel_bus, {
  name = "ReaComp (Cockos)",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, -25.0)
    reaper.TrackFX_SetParam(track, fx, 2, 3.0)
    reaper.TrackFX_SetParam(track, fx, 3, 120.0)
    reaper.TrackFX_SetParam(track, fx, 5, 6.0)
    reaper.TrackFX_SetParam(track, fx, 6, 0.0)
    reaper.TrackFX_SetParam(track, fx, 7, 0.0)
  end
})
ensure_fx(parallel_bus, {
  name = "JS: Saturation",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, 0.2)
  end
})

local mix_bus = find_or_create_named_track("Mix Bus", colors.bus)
assign_volume(mix_bus, 1.0)
ensure_fx(mix_bus, {
  name = "ReaEQ (Cockos)",
  config = function(track, fx)
    configure_rea_eq(track, fx, {
      band_count = 4,
      { index = 1, freq = 28, gain = 0.0, q = 0.707, type = EQ_TYPES.HIGH_PASS },
      { index = 2, freq = 250, gain = -0.8, q = 0.9, type = EQ_TYPES.BAND },
      { index = 3, freq = 4200, gain = -0.6, q = 1.3, type = EQ_TYPES.BAND },
      { index = 4, freq = 9500, gain = 0.9, q = 0.7, type = EQ_TYPES.HIGH_SHELF }
    })
  end
})
ensure_fx(mix_bus, {
  name = "ReaComp (Cockos)",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, -5.5)
    reaper.TrackFX_SetParam(track, fx, 2, 30.0)
    reaper.TrackFX_SetParam(track, fx, 3, 180.0)
    reaper.TrackFX_SetParam(track, fx, 5, 2.1)
    reaper.TrackFX_SetParam(track, fx, 6, 0.0)
    reaper.TrackFX_SetParam(track, fx, 7, 0.0)
  end
})
ensure_fx(mix_bus, {
  name = "JS: Loudness Meter Peak/RMS/LUFS"
})

local print_bus = find_or_create_named_track("Master Print", {200, 200, 200})
assign_volume(print_bus, 1.0)
ensure_fx(print_bus, {
  name = "JS: Master Limiter",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, -1.0) -- Ceiling
    reaper.TrackFX_SetParam(track, fx, 1, 0.3)  -- Release
  end
})
ensure_fx(print_bus, {
  name = "JS: Saturation",
  config = function(track, fx)
    reaper.TrackFX_SetParam(track, fx, 0, 0.05)
  end
})

local reference_track = find_or_create_named_track("Reference (mute to compare)", colors.reference)
disable_master_send(reference_track)
ensure_fx(reference_track, {
  name = "JS: Loudness Meter Peak/RMS/LUFS"
})

-- Routing
add_send(beat_track, mix_bus, { volume = 1.0 })
for _, track in ipairs(created_vocals) do
  add_send(track, vocal_bus, { volume = 1.0 })
  if track ~= created_vocals[1] then
    add_send(track, verb_aux, { volume = 0.35 })
  end
  if track == created_vocals[1] then
    add_send(track, delay_aux, { volume = 0.25 })
  else
    add_send(track, delay_aux, { volume = 0.18 })
  end
end

add_send(vocal_bus, mix_bus, { volume = 1.0 })
add_send(vocal_bus, parallel_bus, { volume = 0.5 })
add_send(parallel_bus, mix_bus, { volume = 0.45 })
add_send(verb_aux, mix_bus, { volume = 0.6 })
add_send(delay_aux, mix_bus, { volume = 0.55 })
add_send(mix_bus, print_bus, { volume = 1.0 })

reaper.SetOnlyTrackSelected(mix_bus)
reaper.Main_OnCommand(40296, 0) -- Select all items on selected tracks

reaper.GetSet_LoopTimeRange(true, true, 0, 45, false)
reaper.GetSetProjectInfo(project, "RENDER_BOUNDSFLAG", 2, true)
reaper.GetSetProjectInfo(project, "RENDER_CHANNELS", 2, true)
reaper.GetSetProjectInfo(project, "RENDER_SRATE", 48000, true)
reaper.GetSetProjectInfo(project, "RENDER_DITHER", 0, true)
reaper.GetSetProjectInfo_String(project, "RENDER_FORMAT", "wav 24 1", true)

reaper.UpdateArrange()
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Autopilot vocal mix/master setup", -1)

reaper.ShowMessageBox(
  "Сессия подготовлена:\n" ..
  "• Beat → Mix Bus, вокал → Vocal Bus + Parallel Crush, Master готов под -1 dBTP.\n" ..
  "• Reference-трек не посылается на мастер — включай/выключай для A/B.\n" ..
  "• Проверь уровни сендов (Verb/Delay/Parallel) и подстрой компрессию по вкусу.",
  "Autopilot v2",
  0
)
