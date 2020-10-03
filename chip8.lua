local zero16 = ("\0"):rep(16)

local ffi = require "ffi"

local bit = require "bit"

ffi.cdef [[
  typedef unsigned char byte;
]]

local function lowNib(n)
  return bit.band(n, 0x0f)
end

local function highNib(n)
  return bit.rshift(n, 4)
end

local fontLocation = 0x50

local soundData
--generate a sine wave
do
  local frequency = 441
  local amplitude = 0.5
  
  local sampleRate = 44100
  local totalSamples = sampleRate / frequency
  
  soundData = love.sound.newSoundData(totalSamples, sampleRate, 16, 1)
  
  for i=0, totalSamples - 1 do
    soundData:setSample(i, math.sin(i / totalSamples * math.pi * 2) * amplitude)
  end
end

local chip8 = {}
chip8.__index = chip8

function chip8.new()
  local obj = setmetatable({}, chip8)
  
  obj.V = ffi.new("byte[16]")

  obj.PC = 0
  obj.I = 0

  obj.memory = ffi.new("byte[4096]")

  obj.stack = ffi.new("unsigned short[16]")
  obj.SP = 0

  obj.opcode = 0

  obj.screenW, obj.screenH = 64, 32
  obj.screen = ffi.new("unsigned char[64 * 32]")
  obj.screenData = love.image.newImageData(obj.screenW, obj.screenH)
  obj.screenImg = love.graphics.newImage(obj.screenData)
  obj.screenImg:setFilter("nearest")
  obj.color0 = {0, 0, 0, 1}
  obj.color1 = {1, 1, 1, 1}
  obj.screenMap = function(x, y)
    if obj.screen[y * obj.screenW + x] == 1 then
      return unpack(obj.color1)
    else
      return unpack(obj.color0)
    end
  end
  obj.blankMap = function() return unpack(obj.color0) end

  obj.delayTimer = 0
  obj.soundTimer = 0

  obj.keys = {
    [0x1] = "1", [0x2] = "2", [0x3] = "3", [0xc] = "4",
    [0x4] = "q", [0x5] = "w", [0x6] = "e", [0xd] = "r",
    [0x7] = "a", [0x8] = "s", [0x9] = "d", [0xe] = "f",
    [0xa] = "z", [0x0] = "x", [0xb] = "c", [0xf] = "v",
  }

  obj.keysInv = {}
  obj:updateKeysInv()
  
  obj.keysDown = {}

  obj.waitingForKey = false
  obj.waitingReg = 0

  obj.sound = love.audio.newSource(soundData)
  obj.sound:setLooping(true)
  
  obj.cyclesPerFrame = 8
  
  obj.altShiftMode = false
  
  return obj
end

function chip8:updateKeysInv()
  self.keysInv = {}
  for k, v in pairs(self.keys) do
    self.keysInv[v] = k
  end
end

function chip8:resetScreen()
  for i=0, 64 * 32 - 1 do
    self.screen[i] = 0
  end
end

function chip8:updateScreen()
  self.screenData:mapPixel(self.screenMap)
  self.screenImg:replacePixels(self.screenData)
end

function chip8:opcodeError()
  error(("unknown opcode: %x"):format(self.opcode))
end

function chip8:init(rom)
  assert(type(rom) == "string", "expected string rom contents")
  
  ffi.copy(self.V, zero16, 16)
  self.PC = 0x200
  self.I = 0
  ffi.copy(self.stack, zero16, 16)
  self.SP = 0
  self.opcode = 0
  
  for i=0, 4095 do
    self.memory[i] = 0x00
  end
  
  self:resetScreen()
  
  local fontData = love.filesystem.read("font.dat")
  for i=1, #fontData do
    self.memory[fontLocation + i - 1] = fontData:byte(i)
  end
  
  for i=1, #rom do
    self.memory[0x200 + i - 1] = rom:byte(i)
  end
  
  self.waitingForKey = false
end

function chip8:printStack()
  local str = ("SP: %02X\nstack: "):format(self.SP)
  for i=0, 15 do
    str = str .. ("%02X"):format(self.stack[i]) .. (i < 15 and ", " or "")
  end
  print(str)
end

function chip8:cycle()
  if not self.waitingForKey then
    
    --fetch
    local opHigh = self.memory[self.PC]
    local opLow = self.memory[self.PC + 1]
    self.opcode = bit.bor(bit.lshift(opHigh, 8), opLow)
    
    --print(("executing %04X"):format(opcode))
    
    local x = lowNib(opHigh)
    local y = highNib(opLow)
    
    local incPC = 2
    
    --decode+execute
    
    if self.opcode == 0x00E0 then
      -- clear screen
      
      self:resetScreen()
      self:updateScreen()
      
    elseif self.opcode == 0x00EE then
      -- return from subroutine
      if self.SP <= 0 then error("attempt to return when stack is empty") end
      
      self.SP = self.SP - 1
      self.PC = self.stack[self.SP]
      
      --print("pop")
      --printStack()
      
    else
      
      local nib = highNib(opHigh)
      
      if nib == 0x1 then
        -- **1nnn**: jump to address nnn
        self.PC = bit.band(self.opcode, 0x0fff)
        
        incPC = 0
        
      elseif nib == 0x2 then
        -- **2nnn**: call subroutine at nnn
        if self.SP >= 16 then error("stack overflow - too many subroutines") end
        
        self.stack[self.SP] = self.PC
        self.SP = self.SP + 1
        self.PC = bit.band(self.opcode, 0x0fff)
        
        incPC = 0
        
        --print("push")
        --printStack()
        
      elseif nib == 0x3 then
        -- **3xkk**: skip next instruction if Vx == kk
        if self.V[x] == opLow then
          self.PC = self.PC + 2
        end
        
      elseif nib == 0x4 then
        -- **4xkk**: skip next instruction if Vx ~= kk
        if self.V[x] ~= opLow then
          self.PC = self.PC + 2
        end
        
      elseif nib == 0x5 and lowNib(opLow) == 0 then
        -- **5xy0**: skip next instruction if Vx == Vy
        if self.V[x] == self.V[y] then
          self.PC = self.PC + 2
        end
        
      elseif nib == 0x6 then
        -- **6xkk**: set Vx = kk
        self.V[x] = opLow
        
      elseif nib == 0x7 then
        -- **7xkk**: set Vx = Vx + kk
        self.V[x] = self.V[x] + opLow
        
      elseif nib == 0x8 then
        local kind = lowNib(opLow)
        
        if kind == 0x0 then
          -- **8xy0**: set Vx = Vy
          self.V[x] = self.V[y]
          
        elseif kind == 0x1 then
          -- **8xy1**: set Vx = Vx | Vy
          self.V[x] = bit.bor(self.V[x], self.V[y])
          
        elseif kind == 0x2 then
          -- **8xy2**: set Vx = Vx & Vy
          self.V[x] = bit.band(self.V[x], self.V[y])
          
        elseif kind == 0x3 then
          -- **8xy3**: set Vx = Vx ^ Vy
          self.V[x] = bit.bxor(self.V[x], self.V[y])
          
        elseif kind == 0x4 then
          -- **8xy4**: set Vx = Vx + Vy, set VF = carry
          if self.V[x] + self.V[y] > 255 then
            self.V[0xf] = 1
          else
            self.V[0xf] = 0
          end
          self.V[x] = self.V[x] + self.V[y]
          
        elseif kind == 0x5 then
          -- **8xy5**: set Vx = Vx - Vy, set VF = not borrow
          if self.V[x] > self.V[y] then
            self.V[0xf] = 1
          else
            self.V[0xf] = 0
          end
          self.V[x] = self.V[x] - self.V[y]
          
        elseif kind == 0x6 then
          -- **8xy6**: set Vx = Vy >> 1, set VF = LSB(Vx)
          local other = self.altShiftMode and x or y
          self.V[0xf] = bit.band(self.V[other], 0x1)
          self.V[x] = bit.rshift(self.V[other], 1)
          
        elseif kind == 0x7 then
          -- **8xy7**: set Vx = Vy - Vx, set VF = not borrow
          if self.V[y] > self.V[x] then
            self.V[0xf] = 1
          else
            self.V[0xf] = 0
          end
          self.V[x] = self.V[y] - self.V[x]
          
        elseif kind == 0xE then
          -- **8xyE**: set Vx = Vy << 1, set VF = MSB(Vx)
          local other = self.altShiftMode and x or y
          self.V[0xf] = bit.band(self.V[other], 0x80)
          self.V[x] = bit.lshift(self.V[other], 1)
          
        else
          self:opcodeError()
        end
        
      elseif nib == 0x9 and lowNib(opLow) == 0 then
        -- **9xy0**: skip next instruction if Vx ~= Vy
        if self.V[x] ~= self.V[y] then
          self.PC = self.PC + 2
        end
        
      elseif nib == 0xA then
        -- **Annn**: set I = nnn
        self.I = bit.band(self.opcode, 0x0fff)
        
      elseif nib == 0xB then
        -- **Bnnn**: jump to V0 + nnn
        self.PC = self.V[0] + bit.band(self.opcode, 0x0fff)
        
        incPC = 0
        
      elseif nib == 0xC then
        -- **Cxkk**: set Vx = random & kk
        self.V[x] = bit.band(love.math.random(0, 255), opLow)
        
      elseif nib == 0xD then
        -- **Dxyn**: draw n-byte sprite from memory[I] at position (Vx, Vy), set VF = collision
        self.V[0xf] = 0
        
        for iy = 0, lowNib(opLow) - 1 do
          local row = self.memory[self.I + iy]
          for ix = 0, 7 do
            local dx, dy = (self.V[x] + ix) % self.screenW, (self.V[y] + iy) % self.screenH
            
            local prevPixel = self.screen[dy * self.screenW + dx]
            
            local pixel = bit.band(bit.rshift(row, 7 - ix), 0x01)
            
            if prevPixel == 1 and pixel == 1 then
              self.V[0xf] = true
            end
            
            local color = pixel == prevPixel and 0 or 1
            self.screen[dy * self.screenW + dx] = color
          end
        end
        
        self:updateScreen()
        
      elseif nib == 0xE then
        
        if opLow == 0x9E then
          -- **Ex9E**: skip next instruction if key x is down
          if self.keysDown[self.V[x]] then
            self.PC = self.PC + 2
          end
          
        elseif opLow == 0xA1 then
          -- **ExA1**: skip next instruction if key x is up
          if not self.keysDown[self.V[x]] then
            self.PC = self.PC + 2
          end
          
        else
          self:opcodeError()
        end
        
      elseif nib == 0xF then
        
        if opLow == 0x07 then
          -- **Fx07**: set Vx = delayTimer
          self.V[x] = self.delayTimer
          
        elseif opLow == 0x0A then
          -- **Fx0A**: wait for key press, store pressed key in Vx
          self.waitingForKey = true
          self.waitingReg = x
          
        elseif opLow == 0x15 then
          -- **Fx15**: set delayTimer = Vx
          self.delayTimer = self.V[x]
          
        elseif opLow == 0x18 then
          -- **Fx18**: set soundTimer = Vx
          self.soundTimer = self.V[x]
          self.sound:play()
          
        elseif opLow == 0x1E then
          -- **Fx1E**: set I = I + Vx
          self.I = self.I + self.V[x]
          
        elseif opLow == 0x29 then
          -- **Fx29**: set I = sprite location for digit Vx
          self.I = fontLocation + self.V[x] * 5
          
        elseif opLow == 0x33 then
          -- **Fx33**: store BCD representation of V[x] in memory locations I, I+1, I+2
          self.memory[self.I] = math.floor(self.V[x] / 100)
          self.memory[self.I + 1] = math.floor(self.V[x] / 10) % 10
          self.memory[self.I + 2] = self.V[x] % 10
          
        elseif opLow == 0x55 then
          -- **Fx55**: store registers V0 through Vx in memory starting at location I
          for i=0, x do
            self.memory[self.I + i] = self.V[i]
          end
          
        elseif opLow == 0x65 then
          -- **Fx65**: copy memory from location I to registers V0 - Vx
          for i=0, x do
            self.V[i] = self.memory[self.I + i]
          end
          
        else
          self:opcodeError()
        end
        
      end
      
    end
    
    self.PC = self.PC + incPC
    
    if self.PC > 4095 then
      error("PC out of range")
    end
  end
end

function chip8:update(dt)
  if self.active and not self.waitingForKey then
    for i=1, self.cyclesPerFrame do
      self:cycle()
    end
  end
  
  if self.delayTimer > 0 then
    self.delayTimer = self.delayTimer - 1
  end
  
  if self.soundTimer > 0 then
    self.soundTimer = self.soundTimer - 1
    if self.soundTimer == 0 then
      self.sound:stop()
    end
  end
end

function chip8:buttonPressed(b)
  if self.waitingForKey then
    self.V[self.waitingReg] = b
    self.waitingForKey = false
  end
  
  self.keysDown[b] = true
end
function chip8:buttonReleased(b)
  self.keysDown[b] = false
end

function chip8:keypressed(k, sc)
  if self.keysInv[sc] then
    self:buttonPressed(self.keysInv[sc])
  end
end
function chip8:keyreleased(k, sc)
  if self.keysInv[sc] then
    self:buttonReleased(self.keysInv[sc])
  end
end

local screenScale = 5

function chip8:draw()
  love.graphics.draw(self.screenImg, 0, 0, 0, screenScale)
end

----------

--[[
  SERIALIZED CHIP-8 FORMAT
  
  * V registers: **16 bytes**
  * I register: **2 bytes**
  * PC register: **2 bytes**
  * RAM: **4096 bytes**
  * Stack: 2 * 16 = **32 bytes**
  * SP register: **1 byte**
  * Delay timer: **2 bytes**
  * Sound timer: **2 bytes**
  * Screen (binary): **256 bytes**
  * Waiting for key: **1 byte**
]]

local function byteToString(n)
  return string.char(n)
end
local function stringToByte(s)
  return s:byte()
end

local uint16_str = ffi.new("union{ uint16_t n; char s[2]; }")
local function uint16ToString(n)
  uint16_str.n = n
  return ffi.string(uint16_str.s, 2)
end
local function stringTouint16(s)
  ffi.copy(uint16_str.s, s, 2)
  return uint16_str.n
end

function chip8:serialize()
  local data =
    ffi.string(self.V, 16) ..
    uint16ToString(self.I) ..
    uint16ToString(self.PC) ..
    ffi.string(self.memory, 4096) ..
    ffi.string(self.stack, 32) ..
    byteToString(self.SP) ..
    uint16ToString(self.delayTimer) ..
    uint16ToString(self.soundTimer)
  
  for i=0, 2047, 8 do
    data = data .. string.char(
      self.screen[i    ] * 2^7 +
      self.screen[i + 1] * 2^6 +
      self.screen[i + 2] * 2^5 +
      self.screen[i + 3] * 2^4 +
      self.screen[i + 4] * 2^3 +
      self.screen[i + 5] * 2^2 +
      self.screen[i + 6] * 2^1 +
      self.screen[i + 7] * 2^0
    )
  end
  
  data = data .. string.char(self.waitingForKey and 1 or 0)
  
  return data
end

function chip8:deserialize(data)
  ffi.copy(self.V, data, 16)
  self.I = stringTouint16(data:sub(17, 18))
  self.PC = stringTouint16(data:sub(19, 20))
  ffi.copy(self.memory, data:sub(21), 4096)
  ffi.copy(self.stack, data:sub(4117), 32)
  self.SP = data:byte(4149)
  self.delayTimer = stringTouint16(data:sub(4150, 4151))
  self.soundTimer = stringTouint16(data:sub(4152, 4153))
  
  for i=0, 255 do
    self.screen[i * 8    ] = bit.band(bit.rshift(data:byte(4154 + i), 7), 1)
    self.screen[i * 8 + 1] = bit.band(bit.rshift(data:byte(4154 + i), 6), 1)
    self.screen[i * 8 + 2] = bit.band(bit.rshift(data:byte(4154 + i), 5), 1)
    self.screen[i * 8 + 3] = bit.band(bit.rshift(data:byte(4154 + i), 4), 1)
    self.screen[i * 8 + 4] = bit.band(bit.rshift(data:byte(4154 + i), 3), 1)
    self.screen[i * 8 + 5] = bit.band(bit.rshift(data:byte(4154 + i), 2), 1)
    self.screen[i * 8 + 6] = bit.band(bit.rshift(data:byte(4154 + i), 1), 1)
    self.screen[i * 8 + 7] = bit.band(data:byte(4154 + i), 1)
  end
  self:updateScreen()
  
  self.waitingForKey = data:byte(4410) == 1
  
  if self.soundTimer > 0 then
    self.sound:play()
  end
end

return chip8