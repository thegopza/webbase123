--[[
Nexus (lite) — WS <-> Backend (port 3005)
- ping 1s
- money auto-detect (leaderstats/attr/gui)
- roster 2s
- inventory 5s (Egg + Food via PlayerGui.Data.Asset attributes)
- farm status 6s (OccupyingPlayerId + ป้องกันนับซ้ำ/ฟิลเตอร์ขนาด)
- Exec (loadstring/pcall) + Log
- Gift (Eggs: GiftStart / GiftUIDs, Foods: GiftFoodStart)
- auto reconnect
- NEW: SetGiftDaily (ยอดกิฟต์/วันจาก PlayerGui.Data.UserFlag)
]]

-- ===== 0) รอเกมโหลด =====
if not game:IsLoaded() then game.Loaded:Wait() end

-- ===== 1) Resolve WebSocket function =====
local WSConnect = (syn and syn.websocket and syn.websocket.connect)
    or (Krnl and (function() repeat task.wait() until Krnl.WebSocket and Krnl.WebSocket.connect; return Krnl.WebSocket.connect end)())
    or (WebSocket and WebSocket.connect)

if not WSConnect then
    warn("[NexusLite] ไม่พบบริการ WebSocket ของสภาพแวดล้อม"); return
end

-- ===== 2) Services =====
local HttpService         = game:GetService("HttpService")
local Players             = game:GetService("Players")
local Workspace           = game:GetService("Workspace")
local MarketplaceService  = game:GetService("MarketplaceService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do LocalPlayer = Players.LocalPlayer task.wait() end

-- ===== toggle debug =====
local DEBUG = false
local function dprint(...) if DEBUG then print("[Nexus]", ...) end end

-- ===== Helpers: Character snapshot =====
local function round1(n) return n and math.floor(n*10+0.5)/10 or nil end
local function getCharacterSnapshot()
    local char = LocalPlayer.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local pos = hrp and hrp.Position
    return {
        characterName = char.Name,
        health    = hum and hum.Health or nil,
        maxHealth = hum and hum.MaxHealth or nil,
        position  = pos and { x = round1(pos.X), y = round1(pos.Y), z = round1(pos.Z) } or nil,
    }
end

-- ===== Island resolver (ยึด OccupyingPlayerId) =====
local function listIslands()
    local art = Workspace:FindFirstChild("Art")
    if not art then return {} end
    local out = {}
    for _,m in ipairs(art:GetChildren()) do
        if m:IsA("Model") and m.Name:match("^Island[_%-]?%d+$") then
            table.insert(out, m)
        end
    end
    table.sort(out, function(a,b)
        local na = tonumber(a.Name:match("(%d+)")) or 0
        local nb = tonumber(b.Name:match("(%d+)")) or 0
        return na < nb
    end)
    return out
end

local function islandOwnedByUser(island, uid)
    if not island then return false end
    local attr = island:GetAttribute("OccupyingPlayerId")
    if attr ~= nil then
        local n = (typeof(attr)=="string") and tonumber(attr) or attr
        if typeof(n)=="number" and n == uid then return true end
    end
    for _,node in ipairs(island:GetDescendants()) do
        if node.GetAttribute then
            local v = node:GetAttribute("OccupyingPlayerId")
            if v ~= nil then
                local n = (typeof(v)=="string") and tonumber(v) or v
                if typeof(n)=="number" and n == uid then return true end
            end
        end
    end
    return false
end

local function nearestIslandToCharacter()
    local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local best, bestDist = nil, math.huge
    for _,island in ipairs(listIslands()) do
        local cf = island:GetPivot()
        local dx = hrp.Position.X - cf.Position.X
        local dz = hrp.Position.Z - cf.Position.Z
        local dist = dx*dx + dz*dz
        if dist < bestDist then best, bestDist = island, dist end
    end
    return best
end

local function findIslandModel()
    local art = Workspace:FindFirstChild("Art")
    if not art then dprint("ไม่พบ Workspace.Art"); return nil end

    local want = LocalPlayer:GetAttribute("AssignedIslandName")
    if typeof(want)=="string" and #want>0 and art:FindFirstChild(want) then
        dprint("ใช้ AssignedIslandName =", want)
        return art[want]
    end

    local uid = LocalPlayer.UserId
    for _,island in ipairs(listIslands()) do
        if islandOwnedByUser(island, uid) then
            dprint("พบเกาะโดย OccupyingPlayerId →", island.Name)
            return island
        end
    end

    local near = nearestIslandToCharacter()
    if near then dprint("fallback ใกล้สุด →", near.Name) end
    return near
end

-- ===== collect farm tiles (กันนับซ้ำ + ฟิลเตอร์ 8x8x8) =====
local TILE_SIZE = Vector3.new(8,8,8)
local function collectFarmParts(isLand)
    local island = findIslandModel()
    if not island then return {} end
    local pat = isLand and "^Farm_split_%d+_%d+_%d+$" or "^WaterFarm_split_%d+_%d+_%d+$"
    local out, seen = {}, {}

    local function consider(inst)
        if inst:IsA("BasePart") and inst.Name:match(pat) and inst.Size == TILE_SIZE then
            if not seen[inst] then seen[inst]=true; out[#out+1]=inst end
        end
    end
    consider(island)
    for _,d in ipairs(island:GetDescendants()) do consider(d) end
    return out
end

-- ตรวจ “มีสัตว์/ไข่/ของวาง” บนช่อง
local function tileOccupied(part)
    if not part then return false end
    local centerCF = part.CFrame
    local size = Vector3.new(8, 14, 8)

    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.RespectCanCollide = false

    local include = {}
    local pbb  = Workspace:FindFirstChild("PlayerBuiltBlocks")
    local pets = Workspace:FindFirstChild("Pets")
    if pbb  then table.insert(include, pbb)  end
    if pets then table.insert(include, pets) end
    if #include == 0 then include = { Workspace } end
    params.FilterDescendantsInstances = include

    local parts = Workspace:GetPartBoundsInBox(centerCF, size, params)
    if #parts == 0 then return false end

    local seen = {}
    for _,p in ipairs(parts) do
        local m = p:FindFirstAncestorOfClass("Model")
        if m and not seen[m] then
            seen[m] = true
            if m:FindFirstChildOfClass("Humanoid")
            or m:FindFirstChildWhichIsA("AnimationController", true)
            or m:GetAttribute("IsPet") or m:GetAttribute("PetType") or m:GetAttribute("T")
            or (pets and m:IsDescendantOf(pets))
            or (pbb  and m:IsDescendantOf(pbb))
            then
                return true
            end
        end
    end
    return false
end

local function readFarmStatus()
    local function count(isLand)
        local tiles, filled = collectFarmParts(isLand), 0
        for _,t in ipairs(tiles) do if tileOccupied(t) then filled += 1 end end
        return filled, #tiles
    end
    local landFilled,  landTotal  = count(true)
    local waterFilled, waterTotal = count(false)
    return { Land={filled=landFilled,total=landTotal}, Water={filled=waterFilled,total=waterTotal} }
end

-- ===== 3) ยูทิลอ่าน "เงินรวม" =====
local CURRENCY_CANDIDATES = { "Money","Cash","Coins","Gold","Gems" }
local function toNumber(s)
    if typeof(s) == "number" then return s end
    if typeof(s) == "string" then s = s:gsub("[%$,]", ""); return tonumber(s) end
    return nil
end
local function readFromLeaderstats()
    local ls = LocalPlayer:FindFirstChild("leaderstats"); if not ls then return nil end
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
        if found then return end
        depth = depth or 0; if depth > 4 then return end
        for _, c in ipairs(obj:GetChildren()) do
            if c:IsA("TextLabel") or c:IsA("TextButton") then
                local n = toNumber(c.Text); if n and n >= 0 then found = n; return end
            end
            scan(c, depth + 1)
        end
    end
    scan(pg, 0); return found
end
local function detectMoney() return readFromLeaderstats() or readFromAttributes() or searchMoneyInGui() end

-- ===== 4) รายชื่อผู้เล่น (Roster) =====
local function buildRoster()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        list[#list+1] = { id = (plr.UserId ~= 0) and plr.UserId or nil, name = plr.Name }
    end
    return list
end

-- ===== 5) Egg Inventory (จาก PlayerGui.Data.Egg) =====
local function readEggs()
    local pg = LocalPlayer:FindFirstChild("PlayerGui"); if not pg then return {} end
    local data = pg:FindFirstChild("Data");            if not data then return {} end
    local eggFolder = data:FindFirstChild("Egg");      if not eggFolder then return {} end
    local list = {}
    for _, ch in ipairs(eggFolder:GetChildren()) do
        local T = ch:GetAttribute("T") or ch:GetAttribute("Type")
        local M = ch:GetAttribute("M") or ch:GetAttribute("Mutate")
        local nameAttr = ch:GetAttribute("Name") or ch.Name
        local count = ch:GetAttribute("Count") or (ch:IsA("ValueBase") and tonumber(ch.Value)) or 1
        list[#list+1] = { id = ch.Name, name = nameAttr, T = T, M = M, count = count }
    end
    return list
end

-- ===== 5.x) Foods Inventory (จาก PlayerGui.Data.Asset: Attributes) =====
-- รายชื่อมาตรฐาน (TitleCase) ใช้ตรวจ/แปลงแบบ case-insensitive
local FOOD_LIST = {
  "Apple","Banana","BloodstoneCycad","Blueberry","ColossalPinecone","Corn",
  "DeepseaPearlFruit","DragonFruit","Durian","GoldMango","Grape",
  "Orange","Pear","Pineapple","Strawberry","VoltGinkgo","Watermelon"
}
local FOOD_SET = {}; for _,n in ipairs(FOOD_LIST) do FOOD_SET[string.lower(n)] = n end
local function canonicalFoodName(input)
    if not input or input=="" then return nil end
    local k = string.lower(tostring(input)); return FOOD_SET[k]
end

local function foodsAssetFolder()
    local pg   = Players.LocalPlayer:FindFirstChild("PlayerGui"); if not pg then return nil end
    local data = pg:FindFirstChild("Data");                       if not data then return nil end
    return data:FindFirstChild("Asset")
end

local function readFoods()
    -- path: PlayerGui.Data.Asset (attributes: Apple, Banana, ... -> จำนวน)
    local asset = foodsAssetFolder(); if not asset then return {} end
    local attrs = asset:GetAttributes()
    local out = {}
    for name, val in pairs(attrs) do
        local canonical = canonicalFoodName(name) or tostring(name)
        local n = tonumber(val) or 0
        if n > 0 then
            out[#out+1] = { name = canonical, count = n }
        end
    end
    table.sort(out, function(a,b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    return out
end

-- [Gift Food] helper: โฟลเดอร์/ยอดคงเหลืออาหาร (จาก Data.Asset)
local function getFoodCount(name)
    local asset = foodsAssetFolder(); if not asset then return 0 end
    local canonical = canonicalFoodName(name) or tostring(name)
    local v = asset:GetAttribute(canonical)
    return tonumber(v) or 0
end

-- ===== NEW: Gift daily counter (จาก PlayerGui.Data.UserFlag) =====
local function readGiftDaily()
    -- path: Players.LocalPlayer.PlayerGui.Data.UserFlag (Configuration)
    local pg   = Players.LocalPlayer:FindFirstChild("PlayerGui"); if not pg then return nil end
    local data = pg:FindFirstChild("Data");                       if not data then return nil end
    local uf   = data:FindFirstChild("UserFlag");                 if not uf then return nil end

    local usedAttr = uf:GetAttribute("TodaySendGiftCount")
    local dateAttr = uf:GetAttribute("TodaySendGiftTimer") -- คาดว่า YYYYMMDD ตามภาพ
    local used = tonumber(usedAttr) or 0
    local date = (dateAttr ~= nil) and tostring(dateAttr) or ""

    return { used = used, limit = 500, date = date }
end
-- ===== /NEW =====

-- ===== 5.5) Gift helpers (Build A Zoo) =====
local GiftRE = (function()
    local ok, remote = pcall(function()
        return ReplicatedStorage:WaitForChild("Remote",5):FindFirstChild("GiftRE")
    end)
    return ok and remote or nil
end)()

-- ✅ CharacterRE สำหรับเลือก/โฟกัส UIDs/Item โดยตรง
local CharacterRE = (function()
    local ok, remote = pcall(function()
        return ReplicatedStorage:WaitForChild("Remote",5):FindFirstChild("CharacterRE")
    end)
    return ok and remote or nil
end)()

local function getHRP(plr)
    plr = plr or LocalPlayer
    local ch = plr and plr.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function teleportNear(targetPlr, offset)
    offset = offset or 1.6
    local myHRP, tgHRP = getHRP(LocalPlayer), getHRP(targetPlr)
    if not (myHRP and tgHRP) then return false, "missing HRP" end
    local dir = (myHRP.Position - tgHRP.Position)
    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
    pcall(function()
        myHRP.CFrame = CFrame.new(tgHRP.Position + dir.Unit * offset, tgHRP.Position)
    end)
    task.wait(0.08)
    return true
end

-- ===== Confirm utilities (Eggs) =====
local function _eggFolder()
    local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    return data and data:FindFirstChild("Egg") or nil
end

local function getEggInfo(uid)
    local eg = _eggFolder(); if not eg then return nil end
    local ch = eg:FindFirstChild(tostring(uid))
    if not ch then return nil end
    local T = ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name
    local M = normalizeMut(ch:GetAttribute("M") or ch:GetAttribute("Mutate"))
    return { uid=tostring(uid), T=tostring(T), M=M }
end

local function hasEggUID(uid)
    local eg = _eggFolder(); if not eg then return false end
    return eg:FindFirstChild(tostring(uid)) ~= nil
end

local function countEggTM(T, M)
    local eg = _eggFolder(); if not eg then return 0 end
    local n = 0
    for _, ch in ipairs(eg:GetChildren()) do
        if #ch:GetChildren() == 0 then
            local t = ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name
            local m = normalizeMut(ch:GetAttribute("M") or ch:GetAttribute("Mutate"))
            if tostring(t) == tostring(T) and tostring(m or "") == tostring(M or "") then
                n += 1 -- นับเป็นชิ้นๆ (ตาม UID)
            end
        end
    end
    return n
end

-- รอคอนเฟิร์มว่า “ลดจริง 1 ชิ้น” (UID หายหรือยอด T|M ลด)
local function waitConfirmEgg(uid, T, M, prevCount, timeoutSec)
    local t0 = os.clock()
    timeoutSec = timeoutSec or 3.0
    while (os.clock() - t0) <= timeoutSec do
        if not hasEggUID(uid) then return true end
        if prevCount and prevCount > 0 then
            local now = countEggTM(T, M)
            if now == (prevCount - 1) then return true end
        end
        task.wait(0.08)
    end
    return false
end

-- ===== Confirm utilities (Foods) =====
local function waitConfirmFood(name, prevCount, timeoutSec)
    local t0 = os.clock()
    timeoutSec = timeoutSec or 2.5
    while (os.clock() - t0) <= timeoutSec do
        local now = getFoodCount(name)
        if now == (prevCount - 1) then return true end
        task.wait(0.06)
    end
    return false
end

-- ===== Gift (Egg) — ใช้ของเดิมที่ทำงานดี =====
local function giftOnce(targetPlr, eggUID)
    if not targetPlr or not targetPlr.Parent then return false, "no target" end
    if not eggUID then return false, "no egg uid" end

    local meta = getEggInfo(eggUID)
    if not meta then return false, "uid missing" end
    local prevCount = countEggTM(meta.T, meta.M)

    teleportNear(targetPlr, 1.6)
    holdEgg(eggUID)
    task.wait(0.35)

    local ok = false
    local delay = 0.10
    for attempt = 1, 4 do
        ok = GiftRE and pcall(function() GiftRE:FireServer(targetPlr) end) or false
        local confirmed = waitConfirmEgg(eggUID, meta.T, meta.M, prevCount, 2.0 + attempt*0.4)
        if ok and confirmed then
            task.wait(0.10)
            return true
        end
        holdEgg(eggUID)
        task.wait(delay + attempt*0.15)
    end

    return false, "no confirm"
end

local function giftBatchFiltered(sendFn, payload)
    if not GiftRE then sendFn("GiftDone",{ok=false,reason="GiftRE not found",sent=0,total=0}); return end
    local target = resolveTarget(payload and payload.Target)
    if not target then sendFn("GiftDone",{ok=false,reason="target not found",sent=0,total=0}); return end

    local typeSet = payload.T and {[tostring(payload.T)]=true} or {}
    local mutSet  = payload.M and {[tostring(normalizeMut(payload.M))]=true} or {}
    if mutSet["Dino"] then mutSet["Jurassic"] = true end

    local pool = listEggsFiltered(typeSet, mutSet, nil)
    local want = tonumber(payload.Amount or 0) or 0
    if want<=0 then want = #pool end
    want = math.min(want, #pool)

    local sent=0; giftCancelFlag=false
    sendFn("GiftProgress", { sent=0, total=want, label="start" })

    while sent < want and not giftCancelFlag do
        local egg = listEggsFiltered(typeSet, mutSet, 1)[1]
        if not egg then break end
        local ok = giftOnce(target, egg.uid)
        if ok then
            sent += 1
        end
        sendFn("GiftProgress", { sent=sent, total=want, label=(egg.T .. (egg.M and (" • "..egg.M) or "")) })
        task.wait(0.10)
    end

    sendFn("GiftDone",{ok=(sent>=want),sent=sent,total=want})
end

local function giftBatchUIDs(sendFn, payload)
    if not GiftRE then sendFn("GiftDone",{ok=false,reason="GiftRE not found",sent=0,total=0}); return end
    local target = resolveTarget(payload and payload.Target)
    if not target then sendFn("GiftDone",{ok=false,reason="target not found",sent=0,total=0}); return end

    local uids = payload.UIDs
    if type(uids)~="table" or #uids==0 then sendFn("GiftDone",{ok=false,reason="no UIDs",sent=0,total=0}); return end

    local total=#uids; local sent=0; giftCancelFlag=false
    sendFn("GiftProgress", { sent=0, total=total, label="start" })

    for _,uid in ipairs(uids) do
        if giftCancelFlag then break end
        local ok = giftOnce(target, uid)
        if ok then sent += 1 end
        sendFn("GiftProgress", { sent=sent, total=total, label=tostring(uid) })
        task.wait(0.10)
    end

    sendFn("GiftDone",{ok=(sent>=total),sent=sent,total=total})
end

-- ===== Gift (Food) — ของเดิม =====
local function giveFoodOnce(targetPlr, foodName)
    if not targetPlr or not targetPlr.Parent then return false, "no target" end
    if not foodName or foodName=="" then return false, "no food name" end

    local have0 = getFoodCount(foodName)
    if have0 <= 0 then return false, "no stock" end

    teleportNear(targetPlr, 1.6)
    local focused = focusFood(foodName)
    if not focused then return false, "focus failed" end
    task.wait(0.08)

    local ok = false
    for attempt = 1, 4 do
        ok = GiftRE and pcall(function() GiftRE:FireServer(targetPlr) end) or false
        local confirmed = waitConfirmFood(foodName, have0, 1.6 + attempt*0.3)
        if ok and confirmed then
            task.wait(0.06)
            return true
        end
        focusFood(foodName)
        task.wait(0.08 + attempt*0.12)
    end
    return false, "no confirm"
end

local function giftBatchFood(sendFn, payload)
    local target = resolveTarget(payload and payload.Target)
    if not target then sendFn("GiftDone",{ok=false,reason="target not found",sent=0,total=0}); return end
    local foodName = tostring(payload and payload.Food or "")
    if foodName=="" then sendFn("GiftDone",{ok=false,reason="no food",sent=0,total=0}); return end

    local have = getFoodCount(foodName)
    if have<=0 then sendFn("GiftDone",{ok=false,reason="no stock",sent=0,total=0}); return end

    local want = tonumber(payload.Amount or 0) or 0
    if want<=0 then want = have end
    want = math.min(want, have)

    local sent=0; giftCancelFlag=false
    sendFn("GiftProgress", { sent=0, total=want, label=foodName })

    while sent < want and not giftCancelFlag do
        if getFoodCount(foodName) <= 0 then break end
        local ok = giveFoodOnce(target, foodName)
        if ok then sent += 1 end
        sendFn("GiftProgress", { sent=sent, total=want, label=foodName })
        task.wait(0.06)
    end

    sendFn("GiftDone",{ok=(sent>=want),sent=sent,total=want})
end

-- ===== 6) ชื่อห้อง =====
local function makeRoomName()
    local placeName
    local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
    if ok and info and info.Name then placeName = info.Name end
    return (placeName or ("Place " .. tostring(game.PlaceId))) .. " • " .. string.sub(game.JobId, 1, 8)
end

-- ===== 7) WS Manager =====
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

-- ===== 8) onMessage (Exec/Echo/Gift) =====
local function onSocketMessage(self, raw)
    if type(raw) ~= "string" then local okc, s = pcall(tostring, raw); raw = okc and s or "" end
    if raw == "ping" then return end
    local ok, obj = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(obj) ~= "table" then return end
    local name, payload = obj.Name, obj.Payload

    local function slog(msg) self:Send("Log",{Content=tostring(msg)}) end

    if name == "Echo" then
        local content = payload and payload.Content
        if content then print("[Echo]", content); self:Send("Log", { Content = "[Echo] " .. tostring(content) }) end
        return
    end

    if name == "Exec" then
        local code = payload and payload.Code
        if type(code) ~= "string" or code == "" then self:Send("Log", { Content = "[Exec] empty code" }); return end
        local loader = (loadstring or load); if type(loader) ~= "function" then self:Send("Log",{Content="[Exec] no loadstring/load available on this executor"}); return end
        local fn, err = loader(code); if not fn then self:Send("Log",{Content="[Exec] load error: "..tostring(err)}); return end
        pcall(function()
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

    -- === GIFT: Filter-based (T/M/Amount) ===
    if name == "GiftStart" then
        slog("[GiftStart] to "..tostring(payload and payload.Target or "?"))
        task.spawn(function() giftBatchFiltered(function(n,p) self:Send(n,p) end, payload or {}) end)
        return
    end

    -- === GIFT: UID list ===
    if name == "GiftUIDs" then
        slog("[GiftUIDs] to "..tostring(payload and payload.Target or "?"))
        task.spawn(function() giftBatchUIDs(function(n,p) self:Send(n,p) end, payload or {}) end)
        return
    end

    -- === [Gift Food] Focus ตามชื่อ + GiftRE ===
    if name == "GiftFoodStart" then
        slog("[GiftFoodStart] to "..tostring(payload and payload.Target or "?").." food="..tostring(payload and payload.Food))
        task.spawn(function() giftBatchFood(function(n,p) self:Send(n,p) end, payload or {}) end)
        return
    end

    if name == "GiftStop" then giftCancelFlag = true; slog("[Gift] cancel requested"); return end
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

            if sock.OnClose   then sock.OnClose  :Connect(function() self.IsConnected = false; print("[NexusLite] WS closed") end) end
            if sock.OnMessage then sock.OnMessage:Connect(function(msg) onSocketMessage(self, msg) end) end

            -- ส่งค่าพื้นฐาน
            self:Send("SetPlaceId", { Content = tostring(game.PlaceId) })
            self:Send("SetJobId",   { Content = tostring(game.JobId)   })

            local lastMoney, lastFarmsJson, lastCharJson
            local lastGiftJson -- NEW: diff GiftDaily
            local tRoster, tInv, tChar, tFarm, tGift = 0, 0, 0, 0, 0

            while self.IsConnected do
                self:Send("ping", { t = os.time() })

                local m = detectMoney()
                if m and m ~= lastMoney then lastMoney = m; self:Send("SetMoney", { Content = tostring(m) }) end

                tRoster += 1
                if tRoster >= 2 then tRoster = 0; self:Send("SetRoster", { List = buildRoster(), JobId = tostring(game.JobId) }) end

                tInv += 1
                if tInv >= 5 then
                    tInv = 0
                    self:Send("SetInventory", {
                        Eggs  = readEggs(),
                        Foods = readFoods(), -- << ส่ง Foods จาก Data.Asset (attributes)
                    })
                end

                tChar += 1
                if tChar >= 1 then
                    tChar = 0
                    local snap = getCharacterSnapshot()
                    if snap then
                        local js = HttpService:JSONEncode(snap)
                        if js ~= lastCharJson then lastCharJson = js; self:Send("SetCharacter", { Character = snap }) end
                    end
                end

                tFarm += 1
                if tFarm >= 6 then
                    tFarm = 0
                    local farms = readFarmStatus()
                    local js = HttpService:JSONEncode(farms)
                    if js ~= lastFarmsJson then lastFarmsJson = js; self:Send("SetFarms", farms) end
                end

                -- NEW: อัปเดตยอดกิฟต์/วันจาก UserFlag
                tGift += 1
                if tGift >= 2 then -- ทุก ~2 วิ
                    tGift = 0
                    local g = readGiftDaily()
                    if g then
                        local js = HttpService:JSONEncode(g)
                        if js ~= lastGiftJson then
                            lastGiftJson = js
                            self:Send("SetGiftDaily", g)
                        end
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

-- ===== 10) Hooks =====
Players.PlayerAdded:Connect(function() task.wait(0.5) end)
Players.PlayerRemoving:Connect(function() task.wait(0.5) end)
LocalPlayer.OnTeleport:Connect(function(state) if state == Enum.TeleportState.Started then Nexus:Stop() end end)

-- ===== 11) Expose & Start =====
getgenv().Nexus = Nexus
Nexus:Connect("localhost:3005")
