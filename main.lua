love.graphics.setBackgroundColor(0.7, 0.7, 0.7)

local chip8 = require "chip8".new()

require "imgui"

local screenScale = 7

local keypadRows = {
  {0x1, 0x2, 0x3, 0xC},
  {0x4, 0x5, 0x6, 0xD},
  {0x7, 0x8, 0x9, 0xE},
  {0xA, 0x0, 0xB, 0xF},
}

local maxSaveSlots = 5
local currentSlot = 0

local saveStates = {}
for i=1, maxSaveSlots do
  local filename = ("save_%d"):format(i)
  local info = love.filesystem.getInfo(filename)
  if info then
    saveStates[i] = {
      image = love.graphics.newImage(("screenshot_%d.png"):format(i)),
      date = os.date("%c", info.modtime)
    }
  end
end

local activeOnInit = true

local currentRomData

local windows = {
  {
    name = "Screen",
    draw = function()
      imgui.Image(chip8.screenImg, chip8.screenW * screenScale, chip8.screenH * screenScale)
    end,
    show = true
  },
  {
    name = "Keypad",
    draw = function(self)
      for _, row in ipairs(keypadRows) do
        for _, btn in ipairs(row) do
          imgui.Button(("%X"):format(btn), 32, 32)
          if imgui.IsItemActive() then
            if not chip8.keysDown[btn] then
              chip8:buttonPressed(btn)
            end
          elseif chip8.keysDown[btn] and not love.keyboard.isScancodeDown(chip8.keys[btn]) then
            chip8:buttonReleased(btn)
          end
          imgui.SameLine()
        end
        imgui.NewLine()
      end
    end,
    show = true
  },
  {
    name = "Save States",
    draw = function()
      for i=1, maxSaveSlots do
        --currentSlot = imgui.RadioButton(("Slot %d"):format(i), currentSlot, i - 1)
        imgui.Text(("Slot %d"):format(i))
        local save = saveStates[i]
        if save then
          imgui.Image(save.image, save.image:getDimensions())
        else
          imgui.Dummy(chip8.screenW, chip8.screenH)
        end
        imgui.SameLine()
        if imgui.Button(("Save##%d"):format(i)) then
          love.filesystem.write(("save_%d"):format(i), chip8:serialize())
          chip8.screenData:encode("png", ("screenshot_%d.png"):format(i))
          if not save then
            save = {}
            saveStates[i] = save
          end
          save.image = love.graphics.newImage(chip8.screenData)
          save.date = os.date()
        end
        if save then
          imgui.SameLine()
          if imgui.Button(("Load##%d"):format(i)) then
            chip8:deserialize(love.filesystem.read(("save_%d"):format(i)))
          end
          imgui.Text(save.date)
        end
        if i < maxSaveSlots then imgui.Separator() end
      end
    end,
    show = false
  },
  {
    name = "Emulation Settings",
    draw = function()
      chip8.active = imgui.Checkbox("Active", chip8.active)
      imgui.SameLine()
      activeOnInit = imgui.Checkbox("Active on init", activeOnInit)
      chip8.cyclesPerFrame = imgui.DragInt("Cycles Per Frame", chip8.cyclesPerFrame, 0.2, 1, 50)
      if imgui.Button("Cycle") then
        chip8:cycle()
      end
    end,
    show = false
  },
  {
    name = "Screen Settings",
    draw = function()
      screenScale = imgui.SliderInt("Screen Scale", screenScale, 1, 10)
      local update0
      chip8.color0[1], chip8.color0[2], chip8.color0[3], update0 = imgui.ColorEdit3("Color 0", chip8.color0[1], chip8.color0[2], chip8.color0[3])
      local update1
      chip8.color1[1], chip8.color1[2], chip8.color1[3], update1 = imgui.ColorEdit3("Color 1", chip8.color1[1], chip8.color1[2], chip8.color1[3])
      if update0 or update1 then
        chip8:updateScreen()
      end
    end,
    show = false
  },
  {
    name = "CHIP-8 Status",
    draw = function()
      for i=0, 15 do
        if i > 0 then imgui.SameLine(0, 15) end
        imgui.Text(("V%X\n%d"):format(i, chip8.V[i]))
      end
      
      imgui.Separator()
      imgui.Text(("PC\n%.3x"):format(chip8.PC))
      imgui.SameLine(0, 25)
      imgui.Text(("I\n%.3x"):format(chip8.I))
      
      imgui.Separator()
      imgui.Text(("Delay timer\n%d"):format(chip8.delayTimer))
      imgui.SameLine(0, 15)
      imgui.Text(("Sound timer\n%d"):format(chip8.soundTimer))
      
    end,
    show = false
  },
  {
    name = "Debug",
    viewRange = 16,
    draw = function(self)
      local str_arrow, str_location, str_value = "", "", ""
      for i = chip8.PC - self.viewRange, chip8.PC + self.viewRange, 2 do
        if i >= 0 and i < 4096 then
          if i == chip8.PC then
            str_arrow = str_arrow .. ">>>>"
          end
          
          str_location = str_location .. ("%.3x"):format(i)
          
          str_value = str_value .. ("%.2x%.2x"):format(chip8.memory[i], chip8.memory[i + 1])
        end
        
        str_arrow = str_arrow .. "\n"
        str_location = str_location .. "\n"
        str_value = str_value .. "\n"
      end
      imgui.Text(str_arrow)
      imgui.SameLine()
      imgui.Text(str_location)
      imgui.SameLine(0, 25)
      imgui.Text(str_value)
    end,
    show = true
  }
}

function love.load(arg)
  if #arg > 0 then
    currentRomData = love.filesystem.read(arg[1])
  end
  if currentRomData then
    chip8:init(currentRomData)
  end
end

function love.update(dt)
  chip8:update(dt)
end

function love.keypressed(k, sc)
  imgui.KeyPressed(k)
  if not imgui.GetWantCaptureKeyboard() then
    chip8:keypressed(k, sc)
  end
end
function love.keyreleased(key, sc)
  imgui.KeyReleased(key)
  if not imgui.GetWantCaptureKeyboard() then
    chip8:keyreleased(key, sc)
  end
end

function love.draw()
  --chip8:draw()
  imgui.NewFrame()
  
  if imgui.BeginMainMenuBar() then
    if imgui.BeginMenu("CHIP-8") then
      if imgui.MenuItem("Reset") and currentRomData then
        chip8:init(currentRomData)
        chip8.active = activeOnInit
      end
      imgui.EndMenu()
    end
    if imgui.BeginMenu("Windows") then
      for i, item in ipairs(windows) do
        if imgui.MenuItem(item.name) then
          item.show = true
          item.focus = true
        end
      end
      imgui.EndMenu()
    end
    imgui.EndMainMenuBar()
  end
  
  for i, w in ipairs(windows) do
    if w.show then
      imgui.SetNextWindowPos(i * 25 + 25, i * 20 + 25, "ImGuiCond_FirstUseEver")
      if w.focus then
        imgui.SetNextWindowFocus()
        w.focus = false
      end
      
      w.show = imgui.Begin(w.name, true, "ImGuiWindowFlags_AlwaysAutoResize")
      w:draw()
      imgui.End()
    end
  end
  
  imgui.Render()
end

function love.filedropped(file)
  file:open("r")
  currentRomData = file:read()
  chip8:init(currentRomData)
  chip8.active = activeOnInit
end

--
-- User inputs
--
function love.textinput(t)
    imgui.TextInput(t)
    if not imgui.GetWantCaptureKeyboard() then
        -- Pass event to the game
    end
end

function love.mousemoved(x, y)
    imgui.MouseMoved(x, y)
    if not imgui.GetWantCaptureMouse() then
        -- Pass event to the game
    end
end

function love.mousepressed(x, y, button)
    imgui.MousePressed(button)
    if not imgui.GetWantCaptureMouse() then
        -- Pass event to the game
    end
end

function love.mousereleased(x, y, button)
    imgui.MouseReleased(button)
    if not imgui.GetWantCaptureMouse() then
        -- Pass event to the game
    end
end

function love.wheelmoved(x, y)
    imgui.WheelMoved(y)
    if not imgui.GetWantCaptureMouse() then
        -- Pass event to the game
    end
end


function love.quit()
    imgui.ShutDown();
end