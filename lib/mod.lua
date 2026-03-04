-- sidFM v1.0 @sonoCircuit - based on oilcan @zbs and @sixolet (thx zadie and naomi!)

local tx = require 'textentry'
local mu = require 'musicutil'
local md = require 'core/mods'
local fs = include 'nb_sidfm/lib/fs_sidfm'


local NUM_VOICES = 8
local NUM_PERF_SLOTS = 2

local kit_path = "/home/we/dust/data/nb_sidfm/sidfm_kits"
local vox_path = "/home/we/dust/data/nb_sidfm/sidfm_sounds"
local default_kit = "/home/we/dust/data/nb_sidfm/sidfm_kits/default.skit"
local failsafe_kit = "/home/we/dust/code/nb_sidfm/data/sidfm_kits/default.skit"

local current_kit = "default"
local current_vox = {}
for i = 1, NUM_VOICES do
  current_vox[i] = ""
end

local selected_voice = 1
local glb_level = 1
local base_note = 0
local perf_amt = 0
local perf_names = {"A", "B"}

local perfclock = nil
local perftime = 8 -- beats
local perf_slot = 1

local clipboard = {}

local ratio_options = {}
local ratio_values = {}

-- param list indexing needs to correspond to sc msg!
local param_list = {
  "pitch", "tune", "decay", "sweep_time", "sweep_depth", "mod_ratio", "mod_time", "mod_amp", "mod_fb", "mod_dest",
  "noise_amp", "noise_decay", "cutoff_lpf", "cutoff_hpf", "phase", "fold", "level", "pan", "send_a", "send_b"
}

local voice_params = {
  "pitch", "tune", "decay", "decay_mod", "sweep_time", "sweep_depth", "mod_ratio", "mod_time", "mod_amp", "mod_fb", "mod_dest",
  "noise_amp", "noise_decay", "cutoff_lpf", "cutoff_hpf", "phase", "fold", "level", "pan", "send_a", "send_b", "perf_mod"
}

local perf_params = {
  "send_a", "send_b", "sweep_time", "sweep_depth", "decay", "mod_time", "mod_amp", "mod_fb", "mod_dest", 
  "noise_amp", "noise_decay", "fold", "cutoff_lpf", "cutoff_hpf"
}

local d_prm = {}
for i = 1, NUM_VOICES do
  d_prm[i] = {}
  d_prm[i].d_mod = 0
  d_prm[i].p_mod = true
  for j = 1, #param_list do
    d_prm[i][j] = 0
  end
end

local dv = {}
dv.min = {}
dv.max = {}
dv.mod = {}
for i = 1, #param_list do
  dv.min[i] = 0
  dv.max[i] = 0
end
for i = 1, NUM_PERF_SLOTS do
  dv.mod[i] = {}
  for j = 1, #param_list do
    dv.mod[i][j] = 0
  end
end


local function round_form(param, quant, form)
  return(util.round(param, quant)..form)
end

local function pan_display(param)
  if param < -0.01 then
    return ("L < "..math.abs(util.round(param * 100, 1)))
  elseif param > 0.01 then
    return (math.abs(util.round(param * 100, 1)).." > R")
  else
    return "> <"
  end
end

local function build_menu(dest)
  if dest == "voice" then
    -- voice params
    for i = 1, NUM_VOICES do
      for _,v in ipairs(voice_params) do
        local name = "sidfm_"..v.."_"..i
        if i == selected_voice then
          params:show(name)
          if not md.is_loaded("fx") then
            params:hide("sidfm_send_a_"..i)
            params:hide("sidfm_send_b_"..i)
          end
        else
          params:hide(name)
        end
      end
    end
  elseif dest == "perf" then
    -- perf params
    for i = 1, NUM_PERF_SLOTS do
      for _,v in ipairs(perf_params) do
        local name = "sidfm_"..v.."_perf_"..i
        if i == perf_slot then
          params:show(name)
          params:show("sidfm_perf_depth"..i)
          if not md.is_loaded("fx") then
            params:hide("sidfm_send_a_perf_"..i)
            params:hide("sidfm_send_b_perf_"..i)
          end
        else
          params:hide(name)
          params:hide("sidfm_perf_depth"..i)
        end
      end
    end
  end
  _menu.rebuild_params()
end

local function build_tables()
  for i = 1, 32 do
    local num = 33 - i
    local str = tostring(num)..":1"
    table.insert(ratio_options, str)
  end
  for i = 2, 10 do
    local str = "1:"..tostring(i)
    table.insert(ratio_options, str)
  end
  for i = 1, 32 do
    local num = 33 - i
    table.insert(ratio_values, num)
  end
  for i = 2, 10 do
    local num = 1 / i
    table.insert(ratio_values, num)
  end
end

local function populate_minmax_values()
  for k, v in ipairs(param_list) do
    local p = params:lookup_param("sidfm_"..v.."_1")
    if p.t == 1 then -- number
      dv.min[k] = p.min
      dv.max[k] = p.max
    elseif p.t == 2 then -- option
      dv.min[k] = 1
      dv.max[k] = p.count
    elseif p.t == 3 then -- controlspec
      dv.min[k] = p.controlspec.minval
      dv.max[k] = p.controlspec.maxval
    end
  end
end

local function scale_perf_val(i, k, mult)
  if (param_list[k] == "cutoff_lpf" or param_list[k] == "cutoff_hpf") then
    dv.mod[i][k] = util.linexp(0, 1, dv.min[k], dv.max[k], math.abs(mult)) * (mult < 0 and -1 or 1)
  else
    dv.mod[i][k] = (dv.max[k] - dv.min[k]) * mult
  end
end

local function save_sidfm_kit(txt)
  if txt then
    local kit = {}
    kit.vox = {}
    for n = 1, NUM_VOICES do
      kit.vox[n] = {}
      for _, v in ipairs(voice_params) do
        kit.vox[n][v] = params:get("sidfm_"..v.."_"..n)
      end
    end
    kit.mod = {}
    for n = 1, NUM_PERF_SLOTS do
      kit.mod[n] = {}
      for _, v in ipairs(perf_params) do
        kit.mod[n][v] = params:get("sidfm_"..v.."_perf_"..n)
      end
    end
    tab.save(kit, kit_path.."/"..txt..".skit")
    current_kit = txt
    print("saved sidfm kit: "..txt)
  end
end

local function load_kit(path)
  if path ~= "cancel" and path ~= "" and path ~= kit_path then
    if path:match("^.+(%..+)$") == ".skit" then
      local kit = tab.load(path)
      if kit ~= nil then
        for n = 1, NUM_VOICES do
          for _, v in ipairs(voice_params) do
            params:set("sidfm_"..v.."_"..n, kit.vox[n][v])
          end
        end
        for n = 1, NUM_PERF_SLOTS do
          for i, v in ipairs(perf_params) do
            params:set("sidfm_"..v.."_perf_"..n, kit.mod[n][v])
          end
        end
        current_kit = path:match("[^/]*$"):gsub(".skit", "")
        print("loaded sidFM kit: "..current_kit)
      else
        if util.file_exists(failsafe_kit) then
          load_synth_patch(failsafe_kit)
        end
        print("error: could not find sidFM kit", path)
      end
    else
      print("error: not a sidFM kit file")
    end
  end
end

local function save_voice(txt)
  if txt then
    local vox = {}
    for _, v in ipairs(voice_params) do
      vox[v] = params:get("sidfm_"..v.."_"..selected_voice)
    end
    tab.save(vox, vox_path.."/"..txt..".svox")
    print("saved sidFM sound: "..txt)
  end
end

local function load_voice(path)
  if path ~= "cancel" and path ~= "" then
    if path:match("^.+(%..+)$") == ".svox" then
      local t = tab.load(path)
      if t ~= nil then
        for _, v in ipairs(voice_params) do
          if t[v] ~= nil then
            params:set("sidfm_"..v.."_"..selected_voice, t[v])
          end
        end
        current_vox[selected_voice] = path:match("[^/]*$"):gsub(".svox", "")
        print("loaded sidFM sound: "..current_vox[selected_voice])
      else
        print("error: could not find sidFM sound", path)
      end
    else
      print("error: not a sidFM sound file")
    end
  end
end

local function trig_perf_ramp()
  if perfclock ~= nil then
    params:set("sidfm_perf_amt", 0)
    clock.cancel(perfclock)
    perfclock = nil
  else
    perfclock = clock.run(function()
      local counter = 0
      local d = 100 / (perftime * 4)
      clock.sync(1)
      while counter < perftime do
        params:delta("sidfm_perf_amt", d)
        counter = counter + 1/4
        if counter == perftime then
          params:set("sidfm_perf_amt", 0)
          perfclock = nil
        end
        clock.sync(1/4)
      end 
    end)
  end
end

local function trig_sidfm(voice, vel)
  local msg = {}
  for k, v in ipairs(d_prm[voice]) do
    msg[k] = v
    if param_list[k] == "decay" then
      msg[k] = msg[k] + math.random() * d_prm[voice].d_mod
    elseif param_list[k] == "level" then
      msg[k] = msg[k] * glb_level * vel
    end
    if d_prm[voice].p_mod then
      msg[k] = util.clamp(msg[k] + (dv.mod[perf_slot][k] * perf_amt), dv.min[k], dv.max[k])
    end
  end
  local slot = (voice - 1) -- sc is zero-indexed!
  table.insert(msg, 1, slot)
  osc.send({'localhost', 57120}, '/sidfm/trig', msg)
end

local function add_params()
  -- populate tables
  build_tables()
  -- sidfm params
  params:add_group("sidfm_group", "sidFM", ((NUM_VOICES * 22) + (NUM_PERF_SLOTS * 15) + 17))
  params:hide("sidfm_group")

  params:add_separator("sidfm_kits", "sidFM kit")

  params:add_trigger("sidfm_load_kit", ">> load")
  params:set_action("sidfm_load_kit", function() fs.enter(kit_path, load_kit) end)

  params:add_trigger("sidfm_save_kit", "<< save")
  params:set_action("sidfm_save_kit", function() tx.enter(save_sidfm_kit, current_kit)  end)
   
  params:add_separator("sidfm_settings", "sidFM settings")

  params:add_control("sidfm_global_level", "main level", controlspec.new(0, 1, "lin", 0, 1), function(param) return round_form(param:get() * 100, 1, "%") end)
  params:set_action("sidfm_global_level", function(val) glb_level = val end)

  params:add_number("sidfm_base_note", "base note", 0, 11, 0, function(param) return mu.note_num_to_name(param:get(), false) end)
  params:set_action("sidfm_base_note", function(val) base_note = val end)

  params:add_separator("sidfm_voice", "voice")

  params:add_number("sidfm_selected_voice", "selected voice", 1, NUM_VOICES, 1)
  params:set_action("sidfm_selected_voice", function(t) selected_voice = t build_menu("voice") end)
  
  params:add_binary("sidfm_trig", "trig voice >>")
  params:set_action("sidfm_trig", function() trig_sidfm(selected_voice, 1) end)

  params:add_trigger("sidfm_load_voice", "> load voice")
  params:set_action("sidfm_load_voice", function() fs.enter(vox_path, load_voice) end)

  params:add_trigger("sidfm_save_voice", "< save voice")
  params:set_action("sidfm_save_voice", function() tx.enter(save_voice, current_vox[selected_voice]) end)

  params:add_separator("sidfm_sound", "sound")
  
  for i = 1, NUM_VOICES do
    params:add_control("sidfm_level_"..i, "level", controlspec.new(0, 2, "lin", 0, 1), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_level_"..i, function(val) d_prm[i][tab.key(param_list, "level")] = val end)

    params:add_control("sidfm_pan_"..i, "pan", controlspec.new(-1, 1, "lin", 0, 0), function(param) return pan_display(param:get()) end)
    params:set_action("sidfm_pan_"..i, function(val) d_prm[i][tab.key(param_list, "pan")] = val end)

    params:add_control("sidfm_send_a_"..i, "send a", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_send_a_"..i, function(val) d_prm[i][tab.key(param_list, "send_a")] = val end)

    params:add_control("sidfm_send_b_"..i, "send b", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_send_b_"..i, function(val) d_prm[i][tab.key(param_list, "send_b")] = val end)
    
    params:add_number("sidfm_pitch_"..i, "pitch", 12, 119, 24, function(param) return mu.note_num_to_name(param:get(), true) end)
    params:set_action("sidfm_pitch_"..i, function(val) d_prm[i][tab.key(param_list, "pitch")] = val end)

    params:add_control("sidfm_tune_"..i, "tune", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "ct") end)
    params:set_action("sidfm_tune_"..i, function(val) d_prm[i][tab.key(param_list, "tune")] = val end)
    
    params:add_control("sidfm_sweep_time_"..i, "sweep time", controlspec.new(0, 1, "lin", 0, 0.1), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_sweep_time_"..i, function(val) d_prm[i][tab.key(param_list, "sweep_time")] = val end)
  
    params:add_control("sidfm_sweep_depth_"..i, "sweep depth", controlspec.new(-1, 1, "lin", 0, 0.02), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_sweep_depth_"..i, function(val) d_prm[i][tab.key(param_list, "sweep_depth")] = val end)

    params:add_control("sidfm_decay_"..i, "decay", controlspec.new(0.01, 4, "lin", 0, 0.2), function(param) return round_form(param:get(), 0.01, "s") end)
    params:set_action("sidfm_decay_"..i, function(val) d_prm[i][tab.key(param_list, "decay")] = val end)

    params:add_control("sidfm_decay_mod_"..i, "decay drift", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_decay_mod_"..i, function(val) d_prm[i].d_mod = val end)
  
    params:add_control("sidfm_mod_time_"..i, "mod time", controlspec.new(0, 2, "lin", 0, 0.1), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_time_"..i, function(val) d_prm[i][tab.key(param_list, "mod_time")] = val end)
  
    params:add_control("sidfm_mod_amp_"..i, "mod amp", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_amp_"..i, function(val) d_prm[i][tab.key(param_list, "mod_amp")] = val end)
  
    params:add_option("sidfm_mod_ratio_"..i, "mod ratio", ratio_options, 32)
    params:set_action("sidfm_mod_ratio_"..i, function(idx) d_prm[i][tab.key(param_list, "mod_ratio")] = ratio_values[idx] end)
  
    params:add_control("sidfm_mod_fb_"..i, "mod feedback", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_fb_"..i, function(val) d_prm[i][tab.key(param_list, "mod_fb")] = val end)
  
    params:add_control("sidfm_mod_dest_"..i, "mod dest [mix/car]", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(100 - (param:get() * 100), 1, "/")..round_form(param:get() * 100, 1, "") end)
    params:set_action("sidfm_mod_dest_"..i, function(val) d_prm[i][tab.key(param_list, "mod_dest")] = val end)
  
    params:add_control("sidfm_noise_amp_"..i, "noise level", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_noise_amp_"..i, function(val) d_prm[i][tab.key(param_list, "noise_amp")] = val end)
  
    params:add_control("sidfm_noise_decay_"..i, "noise decay", controlspec.new(0.01, 4, "lin", 0, 0.2), function(param) return round_form(param:get(), 0.01, "s") end)
    params:set_action("sidfm_noise_decay_"..i, function(val) d_prm[i][tab.key(param_list, "noise_decay")] = val end)

    params:add_option("sidfm_phase_"..i, "phase", {"0°", "90°"}, 1)
    params:set_action("sidfm_phase_"..i, function(mode) d_prm[i][tab.key(param_list, "phase")] = mode end)
  
    params:add_control("sidfm_fold_"..i, "wavefold", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_fold_"..i, function(val) d_prm[i][tab.key(param_list, "fold")] = val end)
  
    params:add_control("sidfm_cutoff_lpf_"..i, "cutoff lpf", controlspec.new(20, 18000, "exp", 0, 18000), function(param) return round_form(param:get(), 1, "hz") end)
    params:set_action("sidfm_cutoff_lpf_"..i, function(val) d_prm[i][tab.key(param_list, "cutoff_lpf")] = val end)
  
    params:add_control("sidfm_cutoff_hpf_"..i, "cutoff hpf", controlspec.new(20, 18000, "exp", 0, 20), function(param) return round_form(param:get(), 1, "hz") end)
    params:set_action("sidfm_cutoff_hpf_"..i, function(val) d_prm[i][tab.key(param_list, "cutoff_hpf")] = val end)

    params:add_option("sidfm_perf_mod_"..i, "macros", {"ignore", "follow"}, 2)
    params:set_action("sidfm_perf_mod_"..i, function(mode) d_prm[i].p_mod = mode == 2 and true or false end)
  end
  
  populate_minmax_values()

  params:add_separator("sidfm_performace_marco", "macro settings")

  params:add_control("sidfm_perf_amt", "amount [map me]", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
  params:set_action("sidfm_perf_amt", function(val) perf_amt = val end)

  params:add_option("sidfm_perf_slot", "macro", perf_names, 1)
  params:set_action("sidfm_perf_slot", function(t) perf_slot = t build_menu("perf") end)

  params:add_number("sidfm_perf_time", "ramp time", 2, 32, 8, function(param) return param:get().." beats" end)
  params:set_action("sidfm_perf_time", function(val) perftime = val end)

  params:add_binary("sidfm_perf_trig", "trig ramp [map me]", "trigger")
  params:set_action("sidfm_perf_trig", function() trig_perf_ramp() end)

  for i = 1, NUM_PERF_SLOTS do
    params:add_separator("sidfm_perf_depth"..i, "macro "..perf_names[i])

    params:add_control("sidfm_send_a_perf_"..i, "send a", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_send_a_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "send_a"), val) end)

    params:add_control("sidfm_send_b_perf_"..i, "send b", controlspec.new(0, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_send_b_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "send_b"), val) end)
      
    params:add_control("sidfm_sweep_time_perf_"..i, "sweep time", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_sweep_time_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "sweep_time"), val) end)

    params:add_control("sidfm_sweep_depth_perf_"..i, "sweep depth", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_sweep_depth_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "sweep_depth"), val) end)

    params:add_control("sidfm_decay_perf_"..i, "decay", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_decay_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "decay"), val) end)

    params:add_control("sidfm_mod_time_perf_"..i, "mod time", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_time_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "mod_time"), val) end)

    params:add_control("sidfm_mod_amp_perf_"..i, "mod amp", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_amp_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "mod_amp"), val) end)

    params:add_control("sidfm_mod_fb_perf_"..i, "mod feedback", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_fb_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "mod_fb"), val) end)

    params:add_control("sidfm_mod_dest_perf_"..i, "mod dest [mix/car]", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_mod_dest_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "mod_dest"), val) end)

    params:add_control("sidfm_noise_amp_perf_"..i, "noise level", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_noise_amp_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "noise_amp"), val)end)

    params:add_control("sidfm_noise_decay_perf_"..i, "noise decay", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_noise_decay_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "noise_decay"), val) end)

    params:add_control("sidfm_fold_perf_"..i, "wavefold", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_fold_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "fold"), val) end)

    params:add_control("sidfm_cutoff_lpf_perf_"..i, "cutoff lpf", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_cutoff_lpf_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "cutoff_lpf"), val) end)

    params:add_control("sidfm_cutoff_hpf_perf_"..i, "cutoff hpf", controlspec.new(-1, 1, "lin", 0, 0), function(param) return round_form(param:get() * 100, 1, "%") end)
    params:set_action("sidfm_cutoff_hpf_perf_"..i, function(val) scale_perf_val(i, tab.key(param_list, "cutoff_hpf"), val) end)
  end

  clock.run(function()
    clock.sleep(0.1)
    load_kit(default_kit)
  end)
end

---------------- nb player ----------------

function sidfm_add_player()
  local player = {}

  function player:describe()
    return {
      name = "sidFM",
      supports_bend = false,
      supports_slew = false
    }
  end
  
  function player:active()
    if self.name ~= nil then
      params:show("sidfm_group")
      build_menu("voice")
      build_menu("perf")
    end
  end

  function player:inactive()
    if self.name ~= nil then
      params:hide("sidfm_group")
      _menu.rebuild_params()
    end
  end

  function player:stop_all()
  end

  function player:modulate(val)
    params:set("sidfm_perf_amt", val)
  end

  function player:set_slew(s)
  end

  function player:pitch_bend(note, val)
  end

  function player:modulate_note(note, key, value)
  end

  function player:note_on(note, vel)
    local vox = ((note % 12) - base_note) % NUM_VOICES + 1
    trig_sidfm(vox, vel)
  end

  function player:note_off(note)
  end

  function player:add_params()
    add_params()
  end

  if note_players == nil then
    note_players = {}
  end

  note_players["sidFM"] = player
end

---------------- mod zone ----------------

local function post_system()
  if util.file_exists(kit_path) == false then
    util.make_dir(kit_path)
    util.make_dir(vox_path)
    os.execute('cp '..'/home/we/dust/code/sidfm/data/sidfm_kits/*.skit '..kit_path)
    os.execute('cp '..'/home/we/dust/code/sidfm/data/sidfm_sounds/*.svox '..vox_path)
  end
end

local function pre_init()
  osc.send({'localhost', 57120}, '/sidfm/init')
  sidfm_add_player()
end

md.hook.register("system_post_startup", "sidfm post startup", post_system)
md.hook.register("script_pre_init", "sidfm pre init", pre_init)
