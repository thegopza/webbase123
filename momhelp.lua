-- Nexus (lite) — WS ↔ Backend (port 3005), ping + money reporting
-- หมายเหตุ: โค้ดนี้อาศัย WS ของสภาพแวดล้อม exploit (เช่น syn.websocket.connect / Krnl.WebSocket.connect)

-- ===== 0) เตรียมโหลดเกม =====
if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- ===== 1) Resolve WebSocket connector =====
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

-- ===== 2) Services / locals =====
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do LocalPlayer = Players.LocalPlayer task.wait() end

-- ===== 3) ยูทิลอ่านเงินรวม =====
local CURRENCY_CANDIDATES = { "Money", "Cash", "Coins", "Gold", "Gems" }

local function toNumber(s)
    if typeof(s) == "number" then return s end
    if typeof(s) == "string" then
        s = s:gsub("[%$,]", "")
        local n = tonumber(s)
        return n
    end
    return nil
end

local function readFromLeaderstats()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return nil, "no-leaderstats" end
    -- ชื่อยอดนิยมก่อน
    for _, name in ipairs(CURRENCY_CANDIDATES) do
        local v = ls:FindFirstChild(name)
        if v and typeof(v.Value) == "number" then
            return tonumber(v.Value), "leaderstats:"..name
        end
    end
    -- ถ้ามี value เดียวเป็น number ก็ใช้
    local only
    for _, ch in ipairs(ls:GetChildren()) do
        if ch:IsA("ValueBase") and typeof(ch.Value) == "number" then
            if only then only = nil break else only = ch end
        end
    end
    if only then return tonumber(only.Value), "leaderstats:"..only.Name end
    return nil, "leaderstats-not-found"
end

local function readFromAttributes()
    if LocalPlayer:GetAttribute("Money") then
        return toNumber(LocalPlayer:GetAttribute("Money")), "player-attr"
    end
    local char = LocalPlayer.Character
    if char and char:GetAttribute("Money") then
        return toNumber(char:GetAttribute("Money")), "char-attr"
    end
    return nil, "no-attr"
end

local function searchMoneyInGui()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil, "no-playergui" end
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
    if found then return found, "playergui-text" end
    return nil, "playergui-not-found"
end

local function detectMoney()
    local v, src = readFromLeaderstats()
    if v then return v, src end
    v, src = readFromAttributes()
    if v then return v, src end
    v, src = searchMoneyInGui()
    if v then return v, src end
    return nil, "not-found"
end

-- ===== 4) ตัวหลัก Nexus (lite) =====
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
    local roomName
    -- สร้าง session label พื้นฐาน (ถ้ามีชื่อแม็พ)
    local placeName
    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId)
    end)
    if ok and info and info.Name then placeName = info.Name end
    roomName = (placeName or ("Place "..tostring(game.PlaceId))).." • "..string.sub(game.JobId,1,8)
    local q = ("name=%s&id=%s&jobId=%s&roomName=%s"):format(
        HttpService:UrlEncode(LocalPlayer.Name),
        HttpService:UrlEncode(LocalPlayer.UserId),
        HttpService:UrlEncode(game.JobId),
        HttpService:UrlEncode(roomName)
    )
    return ("ws://%s%s?%s"):format(self.Host, self.Path, q)
end

function Nexus:Connect(host)
    if host then self.Host = host end
    -- ปิดของเก่าถ้ามี
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

            -- on message / close
            if sock.OnClose then
                sock.OnClose:Connect(function()
                    self.IsConnected = false
                    print("[NexusLite] WS closed")
                end)
            end
            if sock.OnMessage then
                sock.OnMessage:Connect(function(_) end) -- ไม่ใช้รับคำสั่ง
            end

            -- ส่งข้อมูลเบื้องต้น
            self:Send("SetPlaceId", { Content = tostring(game.PlaceId) })
            self:Send("SetJobId",   { Content = tostring(game.JobId)   })
            -- roomName ถูกแนบมาตั้งแต่ URL แล้ว ถ้าต้องการเปลี่ยน runtime ใช้ SetRoomName ได้
            -- self:Send("SetRoomName", { Content = "My Room Label" })

            -- วงจร heartbeat + money report
            local lastMoney
            while self.IsConnected do
                -- 1) ping
                self:Send("ping", { t = os.time() })

                -- 2) money
                local m = select(1, detectMoney())
                if m and m ~= lastMoney then
                    lastMoney = m
                    self:Send("SetMoney", { Content = tostring(m) })
                end

                task.wait(1)
            end

            -- ถ้าหลุด ให้วนไปเชื่อมใหม่
        end
    end
end

function Nexus:Stop()
    self.IsConnected = false
    if self.Socket then pcall(function() self.Socket:Close() end) end
end

-- หยุด WS ตอนเทเลพอร์ต (กันค้าง)
LocalPlayer.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started then
        Nexus:Stop()
    end
end)

-- เปิดใช้
getgenv().Nexus = Nexus
Nexus:Connect("localhost:3005")
