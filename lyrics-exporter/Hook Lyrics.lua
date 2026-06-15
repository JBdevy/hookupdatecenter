-- Hook Lyrics Exporter - sem interface
-- Lê o Empty Item atual da track LETRAS e grava em vshook_lyrics_state.json

local TRACK_NAME = "LETRAS"
local STATE_FILE = "vshook_lyrics_state.json"
local VSHOOK_STATE_FILE = "vshook_state.json"
local WRITE_INTERVAL = 0.10

local last_write = 0
local last_signature = ""

local function trim(s)
  return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function upper(s)
  return trim(s):upper()
end

local function normalize_newlines(text)
  return tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function json_escape(value)
  local s = tostring(value or "")
  s = s:gsub('\\', '\\\\')
       :gsub('"', '\\"')
       :gsub('\b', '\\b')
       :gsub('\f', '\\f')
       :gsub('\n', '\\n')
       :gsub('\r', '\\r')
       :gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function get_scripts_dir()
  local resource = reaper.GetResourcePath and reaper.GetResourcePath() or ""
  return tostring(resource or ""):gsub("\\", "/") .. "/Scripts"
end

local function path_join(a, b)
  a = tostring(a or ""):gsub("\\", "/")
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local data = f:read("*a") or ""
  f:close()
  return data
end

local function write_file(path, data)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(data or "")
  f:close()
  return true
end

local function extract_json_bool(raw, key, default)
  local value = tostring(raw or ""):match('"' .. key .. '"%s*:%s*(true)')
  if value == "true" then return true end
  value = tostring(raw or ""):match('"' .. key .. '"%s*:%s*(false)')
  if value == "false" then return false end
  return default and true or false
end

local function extract_json_number(raw, key, default)
  local value = tostring(raw or ""):match('"' .. key .. '"%s*:%s*([%-%d%.]+)')
  return tonumber(value) or tonumber(default) or 0
end

local function find_lyrics_track()
  local count = reaper.CountTracks and reaper.CountTracks(0) or 0
  for i = 0, count - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr and reaper.GetSetMediaTrackInfo_String then
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      if upper(name) == TRACK_NAME then return tr end
    end
  end
  return nil
end

local function get_position()
  local play_state = reaper.GetPlayState and reaper.GetPlayState() or 0
  if (play_state & 1) == 1 or (play_state & 4) == 4 then
    return reaper.GetPlayPosition and reaper.GetPlayPosition() or 0
  end
  return reaper.GetCursorPosition and reaper.GetCursorPosition() or 0
end

local function get_current_item(track)
  if not track then return nil end
  local pos = get_position()
  local count = reaper.CountTrackMediaItems and reaper.CountTrackMediaItems(track) or 0
  for i = 0, count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
    if pos >= item_pos and pos < (item_pos + item_len) then
      return item, item_pos, item_len
    end
  end
  return nil
end

local function get_item_text(item)
  if not item then return "" end
  local ok_notes, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  if ok_notes and trim(notes) ~= "" then return normalize_newlines(notes) end
  local take = reaper.GetActiveTake and reaper.GetActiveTake(item) or nil
  if take and reaper.GetSetMediaItemTakeInfo_String then
    local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if trim(take_name) ~= "" then return normalize_newlines(take_name) end
  end
  return ""
end

local function build_state_json(text, item_pos, item_len)
  local scripts_dir = get_scripts_dir()
  local main_raw = read_file(path_join(scripts_dir, VSHOOK_STATE_FILE))
  local play_state = reaper.GetPlayState and reaper.GetPlayState() or 0
  local playing = (play_state & 1) == 1 or (play_state & 4) == 4
  local timer_running = extract_json_bool(main_raw, "timerRunning", false)
  local timer_started = extract_json_number(main_raw, "timerStartedAt", 0)
  local timer_accum = extract_json_number(main_raw, "timerAccumulatedSec", 0)
  local now = reaper.time_precise and reaper.time_precise() or os.time()

  local fields = {
    '"lyricsVersion":1',
    '"track":' .. json_escape(TRACK_NAME),
    '"text":' .. json_escape(text or ""),
    '"itemPos":' .. string.format("%.6f", tonumber(item_pos) or 0),
    '"itemLen":' .. string.format("%.6f", tonumber(item_len) or 0),
    '"position":' .. string.format("%.6f", get_position()),
    '"playing":' .. (playing and "true" or "false"),
    '"timerRunning":' .. (timer_running and "true" or "false"),
    '"timerStartedAt":' .. string.format("%.3f", timer_started),
    '"timerAccumulatedSec":' .. string.format("%.3f", timer_accum),
    '"updatedAt":' .. string.format("%.3f", now)
  }
  return "{" .. table.concat(fields, ",") .. "}"
end

local function loop()
  local now = reaper.time_precise and reaper.time_precise() or os.time()
  if now - last_write >= WRITE_INTERVAL then
    last_write = now
    local tr = find_lyrics_track()
    local text, item_pos, item_len = "", 0, 0
    if tr then
      local item, pos, len = get_current_item(tr)
      text = get_item_text(item)
      item_pos = pos or 0
      item_len = len or 0
    end
    local json = build_state_json(text, item_pos, item_len)
    local signature = json:gsub('"updatedAt"%s*:%s*[%d%.]+', '"updatedAt":0')
    if signature ~= last_signature or (now - last_write) < 0.02 then
      last_signature = signature
      write_file(path_join(get_scripts_dir(), STATE_FILE), json)
    else
      -- Mantém alive leve sem recalcular interface.
      write_file(path_join(get_scripts_dir(), STATE_FILE), json)
    end
  end
  reaper.defer(loop)
end

loop()
