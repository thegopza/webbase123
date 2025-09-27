--[[
Nexus (lite) — WS <-> Backend (port 3005)
- ping 1s
- money auto-detect (leaderstats/attr/gui)
- roster 2s
- egg inventory 5s (PlayerGui.Data.Egg)
- farm status 6s (นับ land/ช่อง/ของวาง/สัตว์)
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
while not LocalPlayer do LocalPlayer = Players.LocalPlayer task.wait() end

-- ===== 3) ยูทิลอ่าน "เงินรวม" =====
local CURRENCY_CANDIDATES = { "Money", "Cash", "Coins", "Gold", "Gems" }
local function toNumber(s)
    if typeof(s) == "number" then return s end
    if typeof(s) == "string" then s = s:gsub("[%$,]", "") return tonumber(s) end
    return nil
end
local function readFromLeaderstats()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return nil end
    for _, name in ipairs(CURRENCY_CANDIDATES) do
        local v = ls:FindFirstChild(name)
        if v and typeof(v.Value) == "number" then return tonumber(v.Value) end
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
    if LocalPlayer:GetAttribute("Money") then return toNumber(LocalPlayer:GetAttribute("Money")) end
    local char = LocalPlayer.Character
    if char and char:GetAttribute("Money") then return toNumber(char:GetAttribute("Money")) end
    return nil
end
local function searchMoneyInGui()
    local pg = LocalPlayer:FindFirstChild("PlayerGui"); if not pg then return nil end
    local found
    local function scan(obj, depth)
        if found then return end; depth = depth or 0; if depth > 4 then return end
        for _, c in ipairs(obj:GetChildren()) do
            if c:IsA("TextLabel") or c:IsA("TextButton") then
                local n = toNumber(c.Text); if n and n >= 0 then found = n; return end
            end; scan(c, depth + 1)
        end
    end
    scan(pg, 0); return found
end
local function detectMoney() return readFromLeaderstats() or readFromAttributes() or searchMoneyInGui() end

-- ===== 4) อ่านรายชื่อผู้เล่นในห้อง (Roster) =====
local function buildRoster()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        table.insert(list, { id = (plr.UserId ~= 0) and plr.UserId or nil, name = plr.Name })
    end
    return list
end

-- ===== 5) อ่าน Egg Inventory จาก PlayerGui.Data.Egg =====
local function readEggs()
    local pg = LocalPlayer:FindFirstChild("PlayerGui"); if not pg then return {} end
    local data = pg:FindFirstChild("Data");            if not data then return {} end
    local eggFolder = data:FindFirstChild("Egg");      if not eggFolder then return {} end
    local list = {}
    for _, ch in ipairs(eggFolder:GetChildren()) do
        local T = ch:GetAttribute("T") or ch:GetAttribute("Type")
        local M = ch:GetAttribute("M") or ch:GetAttribute("Mutate")
        local nameAttr = ch:GetAttribute("Name") or ch.Name
        local count = (ch:GetAttribute("Count")) or (ch:IsA("ValueBase") and tonumber(ch.Value)) or 1
        table.insert(list, { id = ch.Name, name = nameAttr, T = T, M = M, count = count })
    end
    return list
end

-- ===== 5.5) Farm Status Helpers =====
local function listAllIslands()
    local out = {}
    local art = workspace:FindFirstChild("Art"); if not art then return out end
    for _, ch in ipairs(art:GetChildren()) do
        if ch:IsA("Model") and ch.Name:match("^Island[_%-]?%d+$") then
            table.insert(out, ch.Name)
        end
    end
    table.sort(out, function(a,b)
        local na = tonumber(a:match("(%d+)")) or 0
        local nb = tonumber(b:match("(%d+)")) or 0
        return na < nb
    end)
    return out
end

local function playerOwnsInstance(inst)
    local cur = inst
    while cur and cur ~= workspace do
        if cur.GetAttribute then
            local uid = cur:GetAttribute("UserId")
            local n = (type(uid)=="string") and tonumber(uid) or uid
            if type(n)=="number" and n == LocalPlayer.UserId then return true end
        end
        cur = cur.Parent
    end
    return false
end

local function countTilesForIsland(islandName)
    local art = workspace:FindFirstChild("Art")
    local total, locked = 0, 0
    if not art then return total, 0, 0 end
    local island = art:FindFirstChild(islandName); if not island then return total, 0, 0 end

    local function scan(parent)
        for _, ch in ipairs(parent:GetChildren()) do
            if ch:IsA("BasePart") and ch.Name:match("^Farm_split_%d+_%d+_%d+$") and ch.Size == Vector3.new(8,8,8) then
                total += 1
            end
            scan(ch)
        end
    end
    scan(island)

    local env = island:FindFirstChild("ENV")
    local locks = env and env:FindFirstChild("Locks")
    if locks then
        for _, model in ipairs(locks:GetChildren()) do
            local farm = model:FindFirstChild("Farm")
            if farm and farm:IsA("BasePart") and farm.Transparency == 0 then
                -- ประมาณจำนวนช่องจากพื้นที่ปิด: (X*Z) / (8*8)
                local area = math.max(1, math.floor((farm.Size.X * farm.Size.Z) / 64))
                locked += area
            end
        end
    end
    local unlocked = math.max(0, total - locked)
    return total, unlocked, locked
end

local function getSurface(posY, sizeY)
    return posY + math.max(8, sizeY/2)
end

local function countOccupiedForIsland(islandName)
    local art = workspace:FindFirstChild("Art")
    if not art then return 0, false end
    local island = art:FindFirstChild(islandName)
    if not island then return 0, false end

    -- รวบรวมตำแหน่งช่องฟาร์ม
    local tiles = {}
    local function scan(parent)
        for _, ch in ipairs(parent:GetChildren()) do
            if ch:IsA("BasePart") and ch.Name:match("^Farm_split_%d+_%d+_%d+$") and ch.Size == Vector3.new(8,8,8) then
                tiles[#tiles+1] = ch
            end
            scan(ch)
        end
    end
    scan(island)

    if #tiles == 0 then return 0, false end

    local occupied = 0
    local hasAnimals = false

    -- สแกนของผู้เล่นที่อยู่บนช่อง: ไข่ (PlayerBuiltBlocks) และสัตว์ (workspace.Pets)
    local pbb = workspace:FindFirstChild("PlayerBuiltBlocks")
    local petsFolder = workspace:FindFirstChild("Pets")

    -- ทำ spatial check อย่างง่าย: ระยะราบ<=4 และแกน Y <= 12 จากผิวบนของช่อง
    local function isOnTile(model, tile)
        local ok, cf = pcall(function() return model:GetPivot() end)
        if not ok or not cf then return false end
        local mpos = cf.Position; local tpos = tile.Position
        local surfaceY = getSurface(tpos.Y, tile.Size.Y)
        local dx = math.abs(mpos.X - tpos.X)
        local dz = math.abs(mpos.Z - tpos.Z)
        local dy = math.abs(mpos.Y - surfaceY)
        return (dx <= 4 and dz <= 4 and dy <= 12)
    end

    -- ทำแผนที่ช่อง -> ถูกครอบครองหรือยัง
    local taken = table.create(#tiles, false)

    -- 1) ไข่/โมเดลใน PlayerBuiltBlocks ที่เป็นของเรา
    if pbb then
        for _, m in ipairs(pbb:GetChildren()) do
            if m:IsA("Model") and playerOwnsInstance(m) then
                for i, tile in ipairs(tiles) do
                    if not taken[i] and isOnTile(m, tile) then
                        taken[i] = true
                        occupied += 1
                        hasAnimals = true
                    end
                end
            end
        end
    end

    -- 2) สัตว์ใน workspace.Pets ที่เป็นของเรา
    if petsFolder then
        for _, m in ipairs(petsFolder:GetChildren()) do
            if m:IsA("Model") and playerOwnsInstance(m) then
                for i, tile in ipairs(tiles) do
                    if not taken[i] and isOnTile(m, tile) then
                        taken[i] = true
                        occupied += 1
                        hasAnimals = true
                    end
                end
            end
        end
    end

    return occupied, hasAnimals
end

local function buildFarmStatusSnapshot()
    local list = {}
    -- เอาเฉพาะเกาะที่มีอยู่ในแผนที่ (ทั้งหมด) แล้วสรุปของเรา
    for _, iname in ipairs(listAllIslands()) do
        local total, unlocked, locked = countTilesForIsland(iname)
        -- ถ้า total=0 ข้าม (ไม่ใช่เกาะฟาร์มจริง)
        if total > 0 then
            local occ, has = countOccupiedForIsland(iname)
            table.insert(list, {
                IslandName = iname,
                TotalTiles = total,
                Unlocked   = unlocked,
                Locked     = locked,
                Occupied   = occ,
                HasAnimals = has
            })
        end
    end
    return list
end

-- ===== 6) สร้าง roomName (ชื่อเกม • 8 ตัวแรกของ jobId) =====
local function makeRoomName()
    local placeName
    local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
    if ok and info and info.Name then placeName = info.Name end
    return (placeName or ("Place " .. tostring(game.PlaceId))) .. " • " .. string.sub(game.JobId, 1, 8)
end

-- ===== 7) Nexus (lite) — WS Manager =====
local Nexus = { Host = "localhost:3005", Path = "/Nexus", IsConnected = false, Socket = nil }
function Nexus:Send(Name, Payload)
    if not (self.Socket and self.IsConnected) then return end
    local ok, msg = pcall(function() return HttpService:JSONEncode({ Name = Name, Payload = Payload }) end)
    if ok and msg then pcall(function() self.Socket:Send(msg) end) end
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
    if type(raw) ~= "string" then local okc, s = pcall(tostring, raw); raw = okc and s or "" end
    if raw == "ping" then return end
    local ok, obj = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(obj) ~= "table" then return end
    local name, payload = obj.Name, obj.Payload

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
            self:Send("Log", { Content = "[Exec] empty code" }); return
        end
        local loader = (loadstring or load)
        if type(loader) ~= "function" then
            self:Send("Log", { Content = "[Exec] no loadstring/load available on this executor" }); return
        end
        local fn, err = loader(code)
        if not fn then
            self:Send("Log", { Content = "[Exec] load error: " .. tostring(err) }); return
        end
        local okEnv = pcall(function()
            local env = (_G and type(_G)=="table") and _G or {}
            env.Player = LocalPlayer
            local original_print, original_warn = print, warn
            local function toLine(...) local a={...}; for i=1,#a do a[i]=tostring(a[i]) end; return table.concat(a," ") end
            env.print = function(...) pcall(original_print, ...); self:Send("Log", { Content = toLine(...) }) end
            env.warn  = function(...) pcall(original_warn , ...); self:Send("Log", { Content = "[WARN] " .. toLine(...) }) end
            if setfenv then pcall(setfenv, fn, env) end
        end)
        local okRun, errRun = pcall(fn)
        if not okRun then warn("[Exec] runtime error:", errRun); self:Send("Log", { Content = "[Exec] runtime error: " .. tostring(errRun) }) end
        return
    end
end

-- ===== 9) Connect / Loop =====
function Nexus:Connect(host)
    if host then self.Host = host end
    if self.Socket then pcall(function() self.Socket:Close() end) end
    self.IsConnected = false

    while true do
        local ok, sock = pcall(WSConnect, self:_wsUrl())
        if not ok or not sock then
            warn("[NexusLite] เชื่อมต่อไม่สำเร็จ จะลองใหม่ใน 5 วิ..."); task.wait(5)
        else
            self.Socket = sock; self.IsConnected = true
            print("[NexusLite] Connected → ws://" .. self.Host .. self.Path)

            if sock.OnClose then sock.OnClose:Connect(function() self.IsConnected = false; print("[NexusLite] WS closed") end) end
            if sock.OnMessage then sock.OnMessage:Connect(function(msg) onSocketMessage(self, msg) end) end

            -- Initial info
            self:Send("SetPlaceId", { Content = tostring(game.PlaceId) })
            self:Send("SetJobId",   { Content = tostring(game.JobId)   })

            local lastMoney
            local tRoster, tInv, tFarm = 0, 0, 0

            while self.IsConnected do
                -- 1) ping 1s
                self:Send("ping", { t = os.time() })

                -- 2) money (on change)
                local m = detectMoney()
                if m and m ~= lastMoney then lastMoney = m; self:Send("SetMoney", { Content = tostring(m) }) end

                -- 3) roster 2s
                tRoster += 1
                if tRoster >= 2 then
                    tRoster = 0
                    self:Send("SetRoster", { List = buildRoster(), JobId = tostring(game.JobId) })
                end

                -- 4) egg inventory 5s
                tInv += 1
                if tInv >= 5 then
                    tInv = 0
                    self:Send("SetInventory", { Eggs = readEggs() })
                end

                -- 5) farm status 6s
                tFarm += 1
                if tFarm >= 6 then
                    tFarm = 0
                    local okFS, snapshot = pcall(buildFarmStatusSnapshot)
                    if okFS and type(snapshot)=="table" then
                        self:Send("SetFarmStatus", { List = snapshot })
                    end
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

-- ===== 10) Hooks เล็กน้อย =====
Players.PlayerAdded:Connect(function() task.wait(0.5) end)
Players.PlayerRemoving:Connect(function() task.wait(0.5) end)
LocalPlayer.OnTeleport:Connect(function(state) if state == Enum.TeleportState.Started then Nexus:Stop() end end)

-- ===== 11) Expose & Start =====
getgenv().Nexus = Nexus
Nexus:Connect("localhost:3005")
