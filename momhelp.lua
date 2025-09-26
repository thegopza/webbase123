-- Nexus (lite) — WS ↔ Backend (port 3005), ping + money + roster reporting (with logs)

if not game:IsLoaded() then game.Loaded:Wait() end

-- 1) Resolve WebSocket
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

-- 2) Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do LocalPlayer = Players.LocalPlayer task.wait() end

-- 3) ยูทิลอ่านเงินรวม
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
    for _, name in ipairs(CURRENCY_CANDIDATES) do
        local v = ls:FindFirstChild(name)
        if v and typeof(v.Value) == "number" then
            return tonumber(v.Value)
        end
    end
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
        if depth > 4 then return end
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

-- 4) Nexus lite
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
    if ok and msg then pcall(function() self.Socket:Send(msg) end) end
end

local function makeRoomName()
    local placeName
    local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
    if ok and info and info.Name then placeName = info.Name end
    return (placeName or ("Place "..tostring(game.PlaceId))).." • "..string.sub(game.JobId,1,8)
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

-- === Roster (รายชื่อผู้เล่นทั้งหมดในห้อง) ===
local function buildRoster()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        table.insert(list, {
            id = plr.UserId ~= 0 and plr.UserId or nil, -- กันกรณี 0/undefined
            name = plr.Name,
        })
    end
    return list
end

function Nexus:Connect(host)
    if host then self.Host = host end
    if self.Socket then pcall(function() self.Socket:Close() end) end
    self.IsConnected = false

    while true do
        local ok, sock = pcall(WSConnect, self:_wsUrl())
        if not ok or not sock then
            warn("[NexusLite] เชื่อมต่อไม่สำเร็จ ลองใหม่ใน 5 วิ...")
            task.wait(5)
        else
            self.Socket = sock
            self.IsConnected = true
            print("[NexusLite] Connected → ws://"..self.Host..self.Path)

            if sock.OnClose then
                sock.OnClose:Connect(function()
                    self.IsConnected = false
                    print("[NexusLite] WS closed")
                end)
            end
            if sock.OnMessage then
                sock.OnMessage:Connect(function(_) end)
            end

            -- ส่งข้อมูลเบื้องต้น
            self:Send("SetPlaceId", { Content = tostring(game.PlaceId) })
            self:Send("SetJobId",   { Content = tostring(game.JobId)   })

            local lastMoney
            local t = 0

            while self.IsConnected do
                -- 1) ping
                self:Send("ping", { t = os.time() })

                -- 2) money (ของเรา)
                local m = detectMoney()
                if m and m ~= lastMoney then
                    lastMoney = m
                    self:Send("SetMoney", { Content = tostring(m) })
                end

                -- 3) roster ทุก 2 วิ (แนบ jobId มาด้วย)
                t += 1
                if t >= 2 then
                    t = 0
                    local roster = buildRoster()
                    print(("[NexusLite] ส่ง Roster: %d คน"):format(#roster))
                    -- note: รองรับกรณี id ว่างด้วย nameKey
                    self:Send("SetRoster", { List = roster, JobId = tostring(game.JobId) })
                end

                task.wait(1)
            end
        end
    end
end

function Nexus:Stop()
    self.IsConnected = false
    if self.Socket then pcall(function() self.Socket:Close() end) end
end

Players.PlayerAdded:Connect(function()
    -- กระตุ้นให้รอบถัดไปส่ง Roster ครบ
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

getgenv().Nexus = Nexus
Nexus:Connect("localhost:3005")

-- ==== Egg Inventory Reporter (Client) ====
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do LocalPlayer = Players.LocalPlayer task.wait() end

local function readEggs()
    -- โครงสร้างที่ให้มา: game:GetService("Players").<name>.PlayerGui.Data.Egg
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return {} end
    local data = pg:FindFirstChild("Data")
    if not data then return {} end
    local eggFolder = data:FindFirstChild("Egg")
    if not eggFolder then return {} end

    local list = {}
    for _, ch in ipairs(eggFolder:GetChildren()) do
        -- รองรับทั้ง Instance ปกติ และ ValueBase
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

local function sendInventory()
    local eggs = readEggs()
    if getgenv and getgenv().Nexus then
        getgenv().Nexus:Send("SetInventory", { Eggs = eggs })
    end
end

-- ส่งครั้งแรก แล้วส่งทุก ๆ 5 วินาที (หรือปรับตามต้องการ)
task.spawn(function()
    while true do
        pcall(sendInventory)
        task.wait(5)
    end
end)

