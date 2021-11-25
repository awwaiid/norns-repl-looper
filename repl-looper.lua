-- repl-looper v0.0.1
-- Anagogical mash of code, time, sound
--
-- llllllll.co/t/repl-looper
--
-- Use in conjunction with laptop running the UI


-- Add repl-looper lib dir in to load .so files like cjson.so
if not string.find(package.cpath, "/home/we/dust/code/repl-looper/lib/", 1, true) then
  package.cpath = package.cpath .. ";/home/we/dust/code/repl-looper/lib/?.so"
  package.path = package.path .. ";/home/we/dust/code/repl-looper/lib/?.lua"
end

json = require("cjson")
-- json = require("lib/dkjson")
lattice = require("lattice")

-- Global Grid
grrr = grid.connect()

local Command = {}
Command.__index = Command
Command.last_id = 0

function Command.new(init)
  local self = init or {
    string = ""
    -- fn = function () end
  }
  setmetatable(self, Command)

  Command.last_id = Command.last_id + 1
  self.id = Command.last_id

  return self
end

-- Not sure, but what we COULD do here is cache the result of the `load` in
-- `self.fn` or something instead of re-parsing it each time
function Command:eval(from_playing_loop)
  return live_event(self.string, from_playing_loop)
end

---------------------------------------

local Event = {}
Event.__index = Event
Event.last_id = 0

function Event.new(init)
  local self = init or {
    command = Command.new(),
    relative_time = 0,
    pulse_offset = 0,
    step = 0
  }
  setmetatable(self, Event)

  Event.last_id = Event.last_id + 1
  self.id = Event.last_id

  return self
end

function Event:to_string()
  -- return "Step " .. self.step .. " @" .. self.pulse_offset .. " -- " .. self.command.string
  return "Step " .. self.step .. " (" .. self.pattern.phase .. ") -- " .. self.command.string
end

function Event:lua()
  return {
    step = self.step,
    -- pattern_phase = self.pattern.phase,
    command = self.command.string
  }
end

function Event:eval(from_playing_loop)
  return self.command:eval(from_playing_loop)
end

---------------------------------------

Loop = {}
Loop.__index = Loop
Loop.last_id = 0

function Loop.new(init)
  local self = init or {
    events = {},
    loop_length_qn = 16,
    current_step = 1,
    duration = 10212,
    lattice = lattice:new{},
    record_feedback = false,
    auto_quantize = true,
    send_feedback = false
  }

  setmetatable(self, Loop)

  Loop.last_id = Loop.last_id + 1
  self.id = Loop.last_id

  -- Register with global list of loops
  loops[self.id] = self

  -- Kinda evil shortcut!
  -- for loops 1..8 make global var 'a' .. 'h'
  if self.id < 9 then
    local loop_letter = string.char(string.byte("a") + self.id - 1)
    print("Setting loop shortcut " .. loop_letter)
    _G[loop_letter] = self
  end

  self:update_lattice()
  return self
end

function Loop:qn_per_ms()
  return clock.get_tempo() / 60 / 1000
end

function Loop:pulse_per_ms()
  return self:qn_per_ms() * self.lattice.ppqn
end

function Loop:pulse_per_measure()
  return self.lattice.ppqn * self.lattice.meter
end

function Loop:loop_length_measure()
  return self.loop_length_qn / self.lattice.meter
end

function Loop:update_event(event)
  event.pulse_offset = self:pulse_per_ms() * event.relative_time
  print("pulse offset: " .. event.pulse_offset)

  event.step = event.pulse_offset / self.lattice.ppqn + 1
  print("event step: " .. event.step)

  if self.auto_quantize then
    event.step = math.floor(event.step + 0.5)
    event.relative_time = (event.step - 1) / self:qn_per_ms()
    event.pulse_offset = self:pulse_per_ms() * event.relative_time - self.lattice.transport
  end

  action = function(t)
    print("@" .. t .. " (next @" .. (self:loop_length_measure() * self:pulse_per_measure() + t) .. ") command: " .. event.command.string)
    event:eval(not self.send_feedback) -- `true` to indicate we are a playback event
  end

  event.pattern = event.pattern or self.lattice:new_pattern{}

  event.pattern:set_action(action)
  event.pattern:set_division(self:loop_length_measure()) -- division is in measures

  -- Forcing the initial phase is what sets the actual offset
  -- TODO: can this be updated while playing? Does it need to be relative to
  -- the current lattice time or something?
  event.pattern.phase = self:loop_length_measure() * self:pulse_per_measure() - event.pulse_offset - self.lattice.transport
end

function Loop:update_lattice()
  -- We use ceil here, so will grow loop-length to the next full quarter note
  -- self.loop_length_qn = self.loop_length_qn or math.ceil(self.duration * self:qn_per_ms())
  self.loop_length_qn = math.ceil(self.duration * self:qn_per_ms())

  print("pulse/ms = " .. self:pulse_per_ms())
  print("qn/ms = " .. self:qn_per_ms())
  print("pulse/measure = " .. self:pulse_per_measure())
  print("loop length qn = " .. self.loop_length_qn)
  print("loop length measure = " .. self:loop_length_measure())

  for _, event in ipairs(self.events) do
    self:update_event(event)
  end

  -- Basically a quarter-note metronome
  self.status_pattern = self.status_pattern or self.lattice:new_pattern{
    action = function(t)
      self.current_step = (math.floor(t / self.lattice.ppqn) % self.loop_length_qn) + 1
      self:draw_grid_row()

      messageFromServer({
        action = "playback_step",
        step = self.current_step,
        stepCount = self.loop_length_qn,
        loop_id = self.id
      })
    end,
    division = 1/4
  }

  return l
end

-- Let's get some GRID!!
function Loop:draw_grid_row()
  clear_grid_row(self.id)

  local row = self:to_grid_row()
  for n = 1, self.loop_length_qn do
    grrr:led(n, self.id, row[n] or 0)
  end

  grrr:refresh()
end

function Loop:quantize()
  for _, event in ipairs(self.events) do
    event.step = math.floor(event.step + 0.5)
    event.relative_time = (event.step - 1) / self:qn_per_ms()
    event.pulse_offset = self:pulse_per_ms() * event.relative_time - self.lattice.transport
  end

  self:update_lattice()
end

function Loop:to_string()
  local output = ""
  output = output .. "ID:" .. self.id .. "Step:" .. self.current_step .. "/" .. self.loop_length_qn .. "@" .. self.lattice.transport .. "\n"
  for _, event in ipairs(self.events) do
    output = output .. "  " .. event:to_string() .. "\n"
  end
  return output
end

function Loop:lua()
  local output = {}
  output.current_step = self.current_step
  output.loop_length_qn = self.loop_length_qn
  output.events = {}
  for _, event in ipairs(self.events) do
    table.insert(output.events, event:lua())
  end
  return output
end

function Loop:print()
  print(self:to_string())
end

function Loop:to_grid_row()
  local row = {}
  for n = 1, self.loop_length_qn do
    if n == self.current_step then
      row[n] = 10
    else
      row[n] = 2
    end
  end
  for _, event in ipairs(self.events) do
    local step = math.floor(event.step)
    if step == self.current_step then
      row[step] = 15
    else
      row[step] = 5
    end
  end

  return row
end

function Loop:play_events_at_step(step)
  for _, event in ipairs(self.events) do
    local event_step = math.floor(event.step)
    if event_step == step then
      -- print("Loop", self.id, "one-shot command:", event.command.string)
      event.command:eval()
    end
  end
end

function Loop:commands_at_step(step)
  local commands = {}
  for _, event in ipairs(self.events) do
    local event_step = math.floor(event.step)
    if event_step == step then
      table.insert(commands, event.command)
    end
  end
  return commands
end

function Loop:toggle_commands_at_step(step, commands)
  print("toggle_commands_at_step: ", step)
  local found_commands = false
  for i = #self.events, 1, -1 do
    local event = self.events[i]
    local event_step = math.floor(event.step)
    if event_step == step then
      if self.events[i].pattern then
        self.events[i].pattern:destroy()
      end
      table.remove(self.events, i)
      found_commands = true
    end
  end

  if not found_commands then
    for _, command in ipairs(commands) do
      local new_event = Event.new({
        -- absolute_time = current_time,
        relative_time = (step - 1) / self:qn_per_ms(),
        command = command,
        step = step,
        pulse_offset = step * self.lattice.ppqn
      })

      table.insert(self.events, new_event)

      self:update_event(new_event)
    end
  end
end

function Loop:play()
  self.lattice:start()
end

function Loop:stop()
  if self.mode == "recording" then
    self.end_rec_time = util.time() * 1000
    self.mode = "stop_recording"
    self.duration = self.end_rec_time - self.start_rec_time
    self:update_lattice()
    self:draw_grid_row()
  else
    self.lattice:stop()
  end
end

function Loop:rec()
  self.start_rec_time = util.time() * 1000
  self.start_rec_transport = self.lattice.transport
  self.mode = "start_recording"
end

function Loop:add_event_command(cmd)
  local current_time = util.time() * 1000
  local relative_time = current_time - self.start_rec_time
  event = Event.new({
    absolute_time = current_time,
    relative_time = relative_time,
    -- relative_pulse = self:pulse_per_ms() * relative_time + self.start_rec_transport
    command = Command.new({
      string = cmd
    })
  })
  self:update_event(event)
  table.insert(self.events, event)
  return event
end

------------------------------------------------------

loops = {}

-- Pre-create 8 loops
for n = 1, 8 do
  Loop.new()
end

function clear_grid_row(row)
  for n = 1, 16 do
    grrr:led(n, row, 0)
  end
end

grid_mode = "one-shot"
grrr:led(1, 8, 15)
local grid_data = {}

grrr.key = function(col, row, state)
  if state == 0 then
    return
  end
  if row == 8 then
    if col == 1 then
      grid_mode = "one-shot"
      print("grid: one-shot mode")
      clear_grid_row(8)
      grrr:led(1, 8, 15)
    elseif col == 2 then
      grid_mode = "sequence"
      print("grid: sequence mode")
      grid_data = {}
      clear_grid_row(8)
      grrr:led(2, 8, 15)
    end
    grrr:refresh()
    redraw()
  else
    local loop_id = row
    local step = col
    if grid_mode == "one-shot" then
      loops[loop_id]:play_events_at_step(col)
    elseif grid_mode == "sequence" then
      if not grid_data.commands then
        grid_data.commands = loops[loop_id]:commands_at_step(step)
        loops[loop_id]:draw_grid_row()
      else
        loops[loop_id]:toggle_commands_at_step(step, grid_data.commands)
        loops[loop_id]:draw_grid_row()
      end
    end
  end
end

recent_command = ""
function redraw()
  screen.ping()
  screen.clear()
  screen.move(0,5)
  screen.text("REPL-LOOPER")

  screen.move(0,62)
  screen.text(grid_mode)

  screen.move(63,34)
  screen.text_center(recent_command)

  screen.update()
end

-- REPL communication
function messageToServer(json_msg)
  local msg = json.decode(json_msg)
  if msg.command == "save_loop" then
    loops[msg.loop_num] = Loop.new(msg.loop)
  else
    print "UNKNOWN COMMAND\n"
  end
end

function messageFromServer(msg)
  local msg_json = json.encode(msg)
  print("SERVER MESSAGE: " .. msg_json .. "\n")
end

function live_event(command, from_playing_loop)
  -- print("Got live_event: " .. command)


  -- This little trick tries to eval first in expression context with a
  -- `return`, and if that doesn't parse (shouldn't even get executed) then try
  -- again in regular command context. Got this method from
  -- https://github.com/hoelzro/lua-repl/blob/master/repl/plugins/autoreturn.lua
  --
  -- Either way we get a function back that we then invoke
  local live_event_command, live_event_errors = load("return " .. command, "CMD")
  if not live_event_command then
    live_event_command, live_event_errors = load(command, "CMD")
  end

  if live_event_errors then
    return live_event_errors
  else
    recent_command = command -- to display on the screen
    local live_event_result = live_event_command()

    -- crazyness. If we got a function ... invoke it. This lets us do weird things.
    if type(live_event_result) == "function" then
      live_event_result = live_event_result()
    end

    for _, loop in ipairs(loops) do
      if loop.mode == "stop_recording" then
        loop.mode = "stopped"
      end
      if loop.mode == "recording" then
        if not from_playing_loop or loop.record_feedback then
          print("Recording event")
          loop:add_event_command(command)
        end
      end
      if loop.mode == "start_recording" then
        loop.mode = "recording"
      end
    end

    redraw()

    return "RESPONSE:" .. json.encode({
      action = "live_event",
      command = recent_command,
      result = live_event_result
    })
  end
end

comp = require("completion")
function completions(command)
  local comps = comp.complete(command)
  return "RESPONSE:" .. json.encode({
    action = "completions",
    command = command,
    result = comps
  })
end

-- Script utilities

-- function hard_reset()
--   norns.script.reload()
-- end


-- Music utilities
-- engine.load('PolyPerc')

-- function beep(freq)
--   engine.hz(freq or 440)
-- end

-- The Other Way

Timber = include("timber/lib/timber_engine")
engine.load('Timber')
engine.name = "Timber"
Timber.add_params() -- Add the general params

-- Each sample needs params

MusicUtil = require "musicutil"
note_name_num = {}
for num=1,127 do
  local name = MusicUtil.note_num_to_name(num, true)
  note_name_num[name] = num
end

MusicUtil.note_name_to_num = function(name) return note_name_num[name] end
MusicUtil.note_name_to_freq = function(name) return MusicUtil.note_num_to_freq(MusicUtil.note_name_to_num(name)) end

function piano_freq(hz, voice)
  engine.noteOn(voice, hz, 1, 0)
end

-- Play a note or a chord
-- The note can be either a midi number OR a note-string like "C3"
-- Or you can pass a table-list of notes that are played all at once
function p(note, voice_id, sample_id)
  local voice_id = voice_id or 0
  local sample_id = sample_id or 0
  local note = note or 60
  local freq = 0

  -- If we got an array, play them all!
  if type(note) == "table" then
    for i, n in ipairs(note) do
      p(n, voice_id + i, sample_id)
    end
    return
  end

  if string.match(note, "^%a") then
    if not string.find(note, "%d") then
      note = note .. "3"
    end
    note = string.upper(note)
    freq = MusicUtil.note_name_to_freq(note)
  else
    freq = MusicUtil.note_num_to_freq(note)
  end

  engine.playMode(sample_id, 3) -- one-shot
  engine.noteOn(voice_id, freq, 1, sample_id)
end

-- p"C"
-- p"C#4"

-- engine.noteOn(0, 440, 0.75, 0) -- voice, freq, vol, sample_id
-- engine.noteOn(1, 220, 1, 0)

-- for i = 0, 9 do engine.playMode(i, 3) end -- 3 = one-shot playback instead of loop

-- engine.playMode(0, 0) -- loop (or should it be infinite-loop?)

-- percentage 55.9
-- start 0
-- end 0.75
-- loop-start 0.04
-- loop-end 0.42
-- freq mod lfo1 0.16
-- freq mod lfo2 0.11
-- filter type low-pass
-- filter cutoff 224 Hz
-- filter resonance 0.84
-- filter cutoff mod LFO1 0.27
-- filter cutoff mod LFO2 0.06
-- Filter cutoff mod Env 0.42
-- Filter cutoff mod Vel 0.18
-- Filter cutoff mod Pres 0.4
--



Sample = {}
Sample.__index = Sample
Sample.next_id = 0

function Sample.new(filename, play_mode)
  local self = {
    params = {}
  }
  setmetatable(self, Sample)

  self.id = Sample.next_id
  Sample.next_id = Sample.next_id + 1


  if filename then
    self:load_sample(filename)
  end

  if play_mode then
    if play_mode == "one-shot" then
      self:playMode(2)
    end
  end

  return self
end

-- Control a sample from Timber
function Sample:pitchBend(n) self.params.pitchBend = n; engine.pitchBendSample(self.id, n) end
function Sample:pressure(n) self.params.pressure = n; engine.pressureSample(self.id, n) end
function Sample:transpose(n) self.params.transpose = n; engine.transpose(self.id, n) end
function Sample:detuneCents(n) self.params.detuneCents = n; engine.detuneCents(self.id, n) end
function Sample:startFrame(n) self.params.startFrame = n; engine.startFrame(self.id, n) end
function Sample:endFrame(n) self.params.endFrame = n; engine.endFrame(self.id, n) end
function Sample:playMode(n) self.params.playMode = n; engine.playMode(self.id, n) end
function Sample:loopStartFrame(n) self.params.loopStartFrame = n; engine.loopStartFrame(self.id, n) end
function Sample:loopEndFrame(n) self.params.loopEndFrame = n; engine.loopEndFrame(self.id, n) end
function Sample:lfo1Fade(n) self.params.lfo1Fade = n; engine.lfo1Fade(self.id, n) end
function Sample:lfo2Fade(n) self.params.lfo2Fade = n; engine.lfo2Fade(self.id, n) end
function Sample:freqModLfo1(n) self.params.freqModLfo1 = n; engine.freqModLfo1(self.id, n) end
function Sample:freqModLfo2(n) self.params.freqModLfo2 = n; engine.freqModLfo2(self.id, n) end
function Sample:freqModEnv(n) self.params.freqModEnv = n; engine.freqModEnv(self.id, n) end
function Sample:freqMultiplier(n) self.params.freqMultiplier = n; engine.freqMultiplier(self.id, n) end
function Sample:ampAttack(n) self.params.ampAttack = n; engine.ampAttack(self.id, n) end
function Sample:ampDecay(n) self.params.ampDecay = n; engine.ampDecay(self.id, n) end
function Sample:ampSustain(n) self.params.ampSustain = n; engine.ampSustain(self.id, n) end
function Sample:ampRelease(n) self.params.ampRelease = n; engine.ampRelease(self.id, n) end
function Sample:modAttack(n) self.params.modAttack = n; engine.modAttack(self.id, n) end
function Sample:modDecay(n) self.params.modDecay = n; engine.modDecay(self.id, n) end
function Sample:modSustain(n) self.params.modSustain = n; engine.modSustain(self.id, n) end
function Sample:modRelease(n) self.params.modRelease = n; engine.modRelease(self.id, n) end
function Sample:downSampleTo(n) self.params.downSampleTo = n; engine.downSampleTo(self.id, n) end
function Sample:bitDepth(n) self.params.bitDepth = n; engine.bitDepth(self.id, n) end
function Sample:filterFreq(n) self.params.filterFreq = n; engine.filterFreq(self.id, n) end
function Sample:filterReso(n) self.params.filterReso = n; engine.filterReso(self.id, n) end
function Sample:filterType(n) self.params.filterType = n; engine.filterType(self.id, n) end
function Sample:filterTracking(n) self.params.filterTracking = n; engine.filterTracking(self.id, n) end
function Sample:filterFreqModLfo1(n) self.params.filterFreqModLfo1 = n; engine.filterFreqModLfo1(self.id, n) end
function Sample:filterFreqModLfo2(n) self.params.filterFreqModLfo2 = n; engine.filterFreqModLfo2(self.id, n) end
function Sample:filterFreqModEnv(n) self.params.filterFreqModEnv = n; engine.filterFreqModEnv(self.id, n) end
function Sample:filterFreqModVel(n) self.params.filterFreqModVel = n; engine.filterFreqModVel(self.id, n) end
function Sample:filterFreqModPressure(n) self.params.filterFreqModPressure = n; engine.filterFreqModPressure(self.id, n) end
function Sample:pan(n) self.params.pan = n; engine.pan(self.id, n) end
function Sample:panModLfo1(n) self.params.panModLfo1 = n; engine.panModLfo1(self.id, n) end
function Sample:panModLfo2(n) self.params.panModLfo2 = n; engine.panModLfo2(self.id, n) end
function Sample:panModEnv(n) self.params.panModEnv = n; engine.panModEnv(self.id, n) end
function Sample:amp(n) self.params.amp = n; engine.amp(self.id, n) end
function Sample:ampModLfo1(n) self.params.ampModLfo1 = n; engine.ampModLfo1(self.id, n) end
function Sample:ampModLfo2(n) self.params.ampModLfo2 = n; engine.ampModLfo2(self.id, n) end
function Sample:lfo1Freq(n) self.params.lfo1Freq = n; engine.lfo1Freq(self.id, n) end
function Sample:lfo1WaveShape(n) self.params.lfo1WaveShape = n; engine.lfo1WaveShape(self.id, n) end
function Sample:lfo2Freq(n) self.params.lfo2Freq = n; engine.lfo2Freq(self.id, n) end
function Sample:lfo2WaveShape(n) self.params.lfo2WaveShape = n; engine.lfo2WaveShape(self.id, n) end

function Sample:noteOn(freq, vol, voice)
  freq = freq or 200
  vol = vol or 1
  voice = voice or self.id -- TODO: voice management
  engine.noteOn(voice, freq, vol, self.id)
end

function Sample:noteOff() engine.noteOff(self.id) end
function Sample:noteKill() engine.noteKill(self.id) end


function Sample:load_sample(filename)
  Timber.add_sample_params(self.id)
  Timber.load_sample(self.id, filename)
  self.sample_filename = filename
end

s = Sample.new("/home/we/dust/code/timber/audio/piano-c.wav")

s808 = {}

s808.BD = Sample.new("/home/we/dust/audio/common/808/808-BD.wav", "one-shot")
s808.CH = Sample.new("/home/we/dust/audio/common/808/808-CH.wav", "one-shot")
s808.CY = Sample.new("/home/we/dust/audio/common/808/808-CY.wav", "one-shot")
s808.LC = Sample.new("/home/we/dust/audio/common/808/808-LC.wav", "one-shot")
s808.MC = Sample.new("/home/we/dust/audio/common/808/808-MC.wav", "one-shot")
s808.RS = Sample.new("/home/we/dust/audio/common/808/808-RS.wav", "one-shot")
s808.BS = Sample.new("/home/we/dust/audio/common/808/808-BS.wav", "one-shot")
s808.CL = Sample.new("/home/we/dust/audio/common/808/808-CL.wav", "one-shot")
s808.HC = Sample.new("/home/we/dust/audio/common/808/808-HC.wav", "one-shot")
s808.LT = Sample.new("/home/we/dust/audio/common/808/808-LT.wav", "one-shot")
s808.MT = Sample.new("/home/we/dust/audio/common/808/808-MT.wav", "one-shot")
s808.SD = Sample.new("/home/we/dust/audio/common/808/808-SD.wav", "one-shot")
s808.CB = Sample.new("/home/we/dust/audio/common/808/808-CB.wav", "one-shot")
s808.CP = Sample.new("/home/we/dust/audio/common/808/808-CP.wav", "one-shot")
s808.HT = Sample.new("/home/we/dust/audio/common/808/808-HT.wav", "one-shot")
s808.MA = Sample.new("/home/we/dust/audio/common/808/808-MA.wav", "one-shot")
s808.OH = Sample.new("/home/we/dust/audio/common/808/808-OH.wav", "one-shot")

function BD() s808.BD:noteOn() end
function BD() s808.BD:noteOn() end
function CH() s808.CH:noteOn() end
function CY() s808.CY:noteOn() end
function LC() s808.LC:noteOn() end
function MC() s808.MC:noteOn() end
function RS() s808.RS:noteOn() end
function BS() s808.BS:noteOn() end
function CL() s808.CL:noteOn() end
function HC() s808.HC:noteOn() end
function LT() s808.LT:noteOn() end
function MT() s808.MT:noteOn() end
function SD() s808.SD:noteOn() end
function CB() s808.CB:noteOn() end
function CP() s808.CP:noteOn() end
function HT() s808.HT:noteOn() end
function MA() s808.MA:noteOn() end
function OH() s808.OH:noteOn() end

-- s3:timber_setup("/home/we/dust/code/repl-looper/audio/excerpts/The-Call-of-the-Polar-Star_fma-115766_001_00-00-01.ogg")
s3 = Sample.new("/home/we/dust/code/repl-looper/audio/one_shots/The-Call-of-the-Polar-Star_fma-115766_001_00-00-01.ogg")

function tabkeys(tab)
  local keyset={}
  local n=0

  for k,v in pairs(tab) do
    n=n+1
    keyset[n]=k
  end
  return keyset
end

function ls(o)
  return tabkeys(getmetatable(o))
end

		-- this.addCommand(\generateWaveform, "i", {
		-- this.addCommand(\noteOffAll, "", {
		-- this.addCommand(\noteKillAll, "", {
		-- this.addCommand(\pitchBendVoice, "if", {
		-- this.addCommand(\pitchBendAll, "f", {
		-- this.addCommand(\pressureVoice, "if", {
		-- this.addCommand(\pressureAll, "f", {
    --
		-- this.addCommand(\loadSample, "is", {
		-- this.addCommand(\clearSamples, "ii", {
		-- this.addCommand(\moveSample, "ii", {
		-- this.addCommand(\copySample, "iii", {
		-- this.addCommand(\copyParams, "iii", {
