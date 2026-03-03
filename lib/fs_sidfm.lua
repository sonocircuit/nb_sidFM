--- fileselect utility
--
-- @module lib.fileselect
-- @alias fs

-- modified for sidFM preview @sonoCircuit

local fs = {}

local MIN_PREVIEW_INTERVAL = 0.1 -- seconds between preview restarts

local ratio_values = {}
for i = 1, 32 do
  local num = 33 - i
  table.insert(ratio_values, num)
end
for i = 2, 10 do
  local num = 1 / i
  table.insert(ratio_values, num)
end

function fs.enter(folder, callback, filter_string)
  fs.folders = {}
  fs.list = {}
  fs.display_list = {}
  fs.pos = 0
  fs.depth = 0
  fs.folder = folder
  fs.callback = callback
  fs.done = false
  fs.path = nil
  fs.filter = filter_string and filter_string or "all"
  fs.previewing = nil
  fs.previewing_timeout_counter = nil
  fs.preview_debounce_clock = nil
  fs.preview_kit_clock = nil

  if fs.folder:sub(-1, -1) ~= "/" then
    fs.folder = fs.folder .. "/"
  end

  fs.getlist()

  if norns.menu.status() == false then
    fs.key_restore = key
    fs.enc_restore = enc
    fs.redraw_restore = redraw
    fs.refresh_restore = refresh
    key = fs.key
    enc = fs.enc
    redraw = norns.none
    refresh = norns.none
    norns.menu.init()
  else
    fs.key_restore = norns.menu.get_key()
    fs.enc_restore = norns.menu.get_enc()
    fs.redraw_restore = norns.menu.get_redraw()
    fs.refresh_restore = norns.menu.get_refresh()
    norns.menu.set(fs.enc, fs.key, fs.redraw, fs.refresh)
  end
  fs.redraw()
end

function fs.exit()
  -- ensure any clocks created by fileselect are cancelled
  if fs.preview_debounce_clock then
    clock.cancel(fs.preview_debounce_clock)
    fs.preview_debounce_clock = nil
  end
  if fs.previewing_timeout_counter then
    clock.cancel(fs.previewing_timeout_counter)
    fs.previewing_timeout_counter = nil
  end
  if fs.preview_kit_clock then
    clock.cancel(fs.preview_kit_clock)
    fs.preview_kit_clock = nil
  end
  if norns.menu.status() == false then
    key = fs.key_restore
    enc = fs.enc_restore
    redraw = fs.redraw_restore
    refresh = fs.refresh_restore
    norns.menu.init()
  else
    norns.menu.set(fs.enc_restore, fs.key_restore, fs.redraw_restore, fs.refresh_restore)
  end
  if fs.path then
    fs.callback(fs.path)
  else
    fs.callback("cancel")
  end
end

function fs.pushd(dir)
  local subdir = dir:match(fs.folder .. '(.*)')
  for match in subdir:gmatch("([^/]*)/") do
    fs.depth = fs.depth + 1
    fs.folders[fs.depth] = match .. "/"
  end
  fs.getlist()
  fs.redraw()
end

fs.getdir = function()
  local path = fs.folder
  for _, v in pairs(fs.folders) do
    path = path .. v
  end
  return path
end

fs.getlist = function()
  local dir = fs.getdir()
  fs.list = util.scandir(dir)
  fs.display_list = {}
  fs.pos = 0
  -- Generate display list and lengths
  for _, v in ipairs(fs.list) do
    local line = util.trim_string_to_width(v, 128)
    table.insert(fs.display_list, line)
  end
end

local function timeout()
  if fs.previewing_timeout_counter == nil then
    fs.previewing_timeout_counter = clock.run(function()
      clock.sleep(0.4)
      fs.previewing_timeout_counter = nil
    end)
  end
end

local function stop()
  if fs.previewing then
    fs.previewing = nil
    -- allow a brief cleanup window before another preview can start
    if fs.preview_debounce_clock then
      clock.cancel(fs.preview_debounce_clock)
    end
    fs.preview_debounce_clock = clock.run(function()
      clock.sleep(0.05)
      fs.preview_debounce_clock = nil
    end)
    if fs.preview_kit_clock then
      clock.cancel(fs.preview_kit_clock)
      fs.preview_kit_clock = nil
    end
    fs.redraw()
  end
end

local function start()
  -- simple debouncing: skip if timeout active or we're in cleanup window
  if fs.previewing_timeout_counter ~= nil then return end
  if fs.preview_debounce_clock ~= nil then return end
  timeout()
  stop()
  -- delay start slightly to ensure stop cleanup completes
  clock.run(function()
    clock.sleep(MIN_PREVIEW_INTERVAL)
    if fs.done then return end
    -- if selection moved during delay, reflect the current position
    fs.previewing = fs.pos
    -- kit/voice preview
    local file = fs.folder .. fs.display_list[fs.pos + 1]
    local filetype = file:match("[^.]*$")
    if filetype == "svox" then
      local args = tab.load(file)
      if next(args) then
        local msg = {}
        for k, v in pairs(args) do
          if k == "mod_ratio" then
            v = ratio_values[v]
          end
          table.insert(msg, k)
          table.insert(msg, v)
        end
        table.insert(msg, 1, 1)
        osc.send({'localhost', 57120}, '/sidfm/preview', msg)
      end
    elseif filetype == "skit" then
      local kit = tab.load(file)
      if kit.vox ~= nil then
        if fs.preview_kit_clock then
          clock.cancel(fs.preview_kit_clock)
        end
        fs.preview_kit_clock = clock.run(function()
          for i = 1, #kit.vox do
            local msg = {}
            for k, v in pairs(kit.vox[i]) do
              if k == "mod_ratio" then
                v = ratio_values[v]
              end
              table.insert(msg, k)
              table.insert(msg, v)
            end
            table.insert(msg, 1, i)
            osc.send({'localhost', 57120}, '/sidfm/preview', msg)
            clock.sleep(0.4)
          end
        end)
      end
    end
    fs.redraw()
  end)
end

fs.key = function(n, z)
  if n == 2 and z == 1 then
    fs.done = true
    stop()
  elseif n == 3 and z == 1 then
    stop()
    if #fs.list > 0 then
      fs.path = fs.folder .. fs.display_list[fs.pos + 1]
      fs.done = true
    end
  elseif z == 0 and fs.done == true then
    fs.exit()
  end
end

fs.enc = function(n, d)
  if n == 2 then
    fs.pos = util.clamp(fs.pos + d, 0, #fs.display_list - 1)
    fs.redraw()
  elseif n == 3 and d > 0 then
    start()
  elseif n == 3 and d < 0 then
    stop()
  end
end

fs.redraw = function()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if #fs.list == 0 then
    screen.level(4)
    screen.move(0, 20)
    screen.text("(no files)")
  else
    for i = 1, 6 do
      if (i > 2 - fs.pos) and (i < #fs.display_list - fs.pos + 3) then
        local list_index = i + fs.pos - 2
        screen.move(0, 10 * i)
        if (i == 3) then
          screen.level(15)
        else
          screen.level(4)
        end
        local text = fs.display_list[list_index]
        if list_index - 1 == fs.previewing then
          text = util.trim_string_to_width('* ' .. text, 97)
        end
        screen.text(text)
      end
    end
  end
  screen.update()
end

fs.refresh = function() fs.redraw() end

return fs