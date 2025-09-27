--[[
Nexus (lite) — WS <-> Backend (port 3005)
- ping 1s
- money auto-detect (leaderstats/attr/gui)
- roster 2s
- egg inventory 5s (PlayerGui.Data.Egg)
- Exec (รับคำสั่งจากเว็บ) -> loadstring/pcall + พิมพ์ลง Dev Console และส่ง Log กลับ
- auto reconnect
]]

-- ===== 0) รอเกมโหลด =====
if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- ===== 1) Resolve WebSocket function =====
local WSConnect = (syn and syn.websocket and syn.websocket.connect)
    or (Krnl and (function()
        repeat task.wait() until Krnl.WebSocket and Krnl.WebSocket.connect
        return Krnl.WebSocket.connect
    end)())
    or (WebSocket and WebSocket.connect)

if not WSConnect then
    warn("[NexusLite] ไม่พบบริการ WebSocket ของสภาพแวดล้อม")
    return
end

-- ===== 2) Services =====
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    LocalPlayer = Players.LocalPlayer
    task.wait()
end

-- ===== 3) ยูทิลอ่าน "เงินรวม" =====
local CURRENCY_CANDIDATES = { "Money", "Cash", "Coins", "Gold", "Gems" }

local function toNumber(s)
    if typeof(s) == "number" then return s end
    if typeof(s) == "string" then
        s = s:gsub("[%$,]", "")
        return tonumber(s)
    end
    return nil
end

local function readFromLeaderstats()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return nil end
    -- 3.1 หา key ยอดนิยมก่อน
    for _, name in ipairs(CURRENCY_CANDIDATES) do
        local v = ls:FindFirstChild(name)
        if v and typeof(v.Value) == "number" then
            return tonumber(v.Value)
        end
    end
    -- 3.2 ถ้าใน leaderstats มี value เดียวเป็น number ก็ใช้
    local only
    for _, ch in ipairs(ls:GetChildren()) do
        if ch:IsA("ValueBase") and typeof(ch.Value) == "number" then
            if only then only = nil break else only = ch end
        end
    end
    if only then return tonumber(only.Value) end
    return nil
end

local function readFromAttributes()
    if LocalPlayer:GetAttribute("Money") then
        return toNumber(LocalPlayer:GetAttribute("Money"))
    end
    local char = LocalPlayer.Character
    if char and char:GetAttribute("Money") then
        return toNumber(char:GetAttribute("Money"))
    end
    return nil
end

local function searchMoneyInGui()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local found
    local function scan(obj, depth)
        if found then return end
        depth = depth or 0
        if depth > 4 then return end -- กันลึกเกิน
        for _, c in ipairs(obj:GetChildren()) do
            if c:IsA("TextLabel") or c:IsA("TextButton") then
                local n = toNumber(c.Text)
                if n and n >= 0 then found = n; return end
            end
            scan(c, depth + 1)
        end
    end
    scan(pg, 0)
    return found
end

local function detectMoney()
    return readFromLeaderstats() or readFromAttributes() or searchMoneyInGui()
end

-- ===== 4) อ่านรายชื่อผู้เล่นในห้อง (Roster) =====
local function buildRoster()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        table.insert(list, {
            id = (plr.UserId ~= 0) and plr.UserId or nil,
            name = plr.Name,
        })
    end
    return list
end

-- ===== 5) อ่าน Egg Inventory จาก PlayerGui.Data.Egg =====
local function readEggs()
    -- โครงสร้าง: Players.<name>.PlayerGui.Data.Egg
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return {} end
    local data = pg:FindFirstChild("Data")
    if not data then return {} end
    local eggFolder = data:FindFirstChild("Egg")
    if not eggFolder then return {} end

    local list = {}
    for _, ch in ipairs(eggFolder:GetChildren()) do
        local T = ch:GetAttribute("T") or ch:GetAttribute("Type")
        local M = ch:GetAttribute("M") or ch:GetAttribute("Mutate")
        local nameAttr = ch:GetAttribute("Name") or ch.Name
        local count = (ch:GetAttribute("Count")) or (ch:IsA("ValueBase") and tonumber(ch.Value)) or 1

        table.insert(list, {
            id = ch.Name,
            name = nameAttr,
            T = T,
            M = M,
            count = count
        })
    end
    return list
end

-- ===== 6) สร้าง roomName (ชื่อเกม • 8 ตัวแรกของ jobId) =====
local function makeRoomName()
    local placeName
    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId)
    end)
    if ok and info and info.Name then
        placeName = info.Name
    end
    return (placeName or ("Place " .. tostring(game.PlaceId))) .. " • " .. string.sub(game.JobId, 1, 8)
end

-- ===== 7) Nexus (lite) — WS Manager =====
local Nexus = {
    Host = "localhost:3005",
    Path = "/Nexus",
    IsConnected = false,
    Socket = nil,
}

function Nexus:Send(Name, Payload)
    if not (self.Socket and self.IsConnected) then return end
    local ok, msg = pcall(function()
        return HttpService:JSONEncode({ Name = Name, Payload = Payload })
    end)
    if ok and msg then
        pcall(function() self.Socket:Send(msg) end)
    end
end

function Nexus:_wsUrl()
    local q = ("name=%s&id=%s&jobId=%s&roomName=%s"):format(
        HttpService:UrlEncode(LocalPlayer.Name),
        HttpService:UrlEncode(LocalPlayer.UserId),
        HttpService:UrlEncode(game.JobId),
        HttpService:UrlEncode(makeRoomName())
    )
    return ("ws://%s%s?%s"):format(self.Host, self.Path, q)
end

-- ===== 8) ตัวจัดการข้อความเข้า (รองรับ Exec/Echo) =====
local function onSocketMessage(self, raw)
    if type(raw) ~= "string" then
        local okc, s = pcall(tostring, raw)
        raw = okc and s or ""
    end

    -- โหมดข้อความดิบ "ping"
    if raw == "ping" then
        return
    end

    local ok, obj = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not ok or type(obj) ~= "table" then
        return
    end

    local name = obj.Name
    local payload = obj.Payload

    if name == "Echo" then
        local content = payload and payload.Content
        if content then
            print("[Echo]", content)
            self:Send("Log", { Content = "[Echo] " .. tostring(content) })
        end
        return
    end

    if name == "Exec" then
        local code = payload and payload.Code
        if type(code) ~= "string" or code == "" then
            self:Send("Log", { Content = "[Exec] empty code" })
            return
        end

        -- เลือกฟังก์ชันโหลดให้เหมาะกับ executor
        local loader = (loadstring or load)
        if type(loader) ~= "function" then
            self:Send("Log", { Content = "[Exec] no loadstring/load available on this executor" })
            return
        end

        local fn, err = loader(code)
        if not fn then
            self:Send("Log", { Content = "[Exec] load error: " .. tostring(err) })
            return
        end

        -- ทำให้ print/warn ออกทั้ง 2 ทาง: Dev Console + ส่ง Log กลับ
        local okEnv, envOrErr = pcall(function()
            -- บาง executor ไม่มี getfenv/setfenv
            local env = (_G and type(_G)=="table") and _G or {}
            env.Player = LocalPlayer

            local original_print = print
            local original_warn  = warn

            local function toLine(...)
                local parts = {}
                local a = {...}
                for i = 1, #a do parts[i] = tostring(a[i]) end
                return table.concat(parts, " ")
            end

            env.print = function(...)
                pcall(original_print, ...)
                self:Send("Log", { Content = toLine(...) })
            end
            env.warn = function(...)
                pcall(original_warn, ...)
                self:Send("Log", { Content = "[WARN] " .. toLine(...) })
            end

            -- inject env ถ้ามี setfenv
            if setfenv then pcall(setfenv, fn, env) end
            return env
        end)

        -- run
        local okRun, errRun = pcall(fn)
        if not okRun then
            warn("[Exec] runtime error:", errRun)
            self:Send("Log", { Content = "[Exec] runtime error: " .. tostring(errRun) })
        end
        return
    end
end

-- ===== 9) Connect / Loop =====
function Nexus:Connect(host)
    if host then self.Host = host end

    -- ปิดอันเดิม ถ้ามี
    if self.Socket then pcall(function() self.Socket:Close() end) end
    self.IsConnected = false

    while true do
        local ok, sock = pcall(WSConnect, self:_wsUrl())
        if not ok or not sock then
            warn("[NexusLite] เชื่อมต่อไม่สำเร็จ จะลองใหม่ใน 5 วิ...")
            task.wait(5)
        else
            self.Socket = sock
            self.IsConnected = true
            print("[NexusLite] Connected → ws://" .. self.Host .. self.Path)

            -- on close
            if sock.OnClose then
                sock.OnClose:Connect(function()
                    self.IsConnected = false
                    print("[NexusLite] WS closed")
                end)
            end
            -- on message (เพิ่มรองรับ Exec/Echo)
            if sock.OnMessage then
                sock.OnMessage:Connect(function(msg)
                    onSocketMessage(self, msg)
                end)
            end

            -- ส่งข้อมูลพื้นฐาน
            self:Send("SetPlaceId", { Content = tostring(game.PlaceId) })
            self:Send("SetJobId",   { Content = tostring(game.JobId)   })

            local lastMoney
            local tRoster = 0
            local tInv = 0

            -- วงจร heartbeat
            while self.IsConnected do
                -- 1) ping ทุก 1 วิ
                self:Send("ping", { t = os.time() })

                -- 2) money (ถ้ามีการเปลี่ยนค่อยส่ง)
                local m = detectMoney()
                if m and m ~= lastMoney then
                    lastMoney = m
                    self:Send("SetMoney", { Content = tostring(m) })
                end

                -- 3) roster ทุก 2 วิ
                tRoster += 1
                if tRoster >= 2 then
                    tRoster = 0
                    local roster = buildRoster()
                    self:Send("SetRoster", { List = roster, JobId = tostring(game.JobId) })
                end

                -- 4) inventory (eggs) ทุก 5 วิ
                tInv += 1
                if tInv >= 5 then
                    tInv = 0
                    local eggs = readEggs()
                    self:Send("SetInventory", { Eggs = eggs })
                end

                task.wait(1)
            end
        end
    end
end

function Nexus:Stop()
    self.IsConnected = false
    if self.Socket then
        pcall(function() self.Socket:Close() end)
    end
end

-- ===== 10) Hooks เล็กน้อย =====
Players.PlayerAdded:Connect(function()
    task.wait(0.5)
end)
Players.PlayerRemoving:Connect(function()
    task.wait(0.5)
end)

LocalPlayer.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started then
        Nexus:Stop()
    end
end)

-- ===== 11) Expose & Start =====
getgenv().Nexus = Nexus
Nexus:Connect("localhost:3005")
