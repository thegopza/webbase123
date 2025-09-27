--[[ =======================
       Build A Zoo — Auto Gift (with auto-approach)
     ======================= ]]

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- === Helpers: Player & movement ===
local function getHRP(plr)
    plr = plr or LocalPlayer
    local ch = plr and plr.Character
    return ch and ch:FindFirstChild("HumanoidRootPart"), ch and ch:FindFirstChildOfClass("Humanoid")
end

local function distanceBetween(a, b)
    return (a - b).Magnitude
end

-- เดินไปใกล้เป้าหมายจนเข้าเกณฑ์ maxDist (พยายามภายใน timeout วินาที)
local function approachTarget(targetPlr, maxDist, timeout)
    maxDist = maxDist or 7      -- เกณฑ์ระยะปลอดภัย
    timeout = timeout or 6      -- เวลาสูงสุดต่อความพยายาม
    local myHRP, hum = getHRP(LocalPlayer)
    local tgHRP = getHRP(targetPlr)
    if not (myHRP and hum and tgHRP) then return false, "missing HRP/Humanoid" end

    -- ถ้าใกล้อยู่แล้ว ไม่ต้องเดิน
    if distanceBetween(myHRP.Position, tgHRP.Position) <= maxDist then
        return true
    end

    local started = os.clock()
    -- ให้ไปยืนห่างหน้าเป้าหมาย ~2 stud
    local dest = tgHRP.Position + (myHRP.Position - tgHRP.Position).Unit * 2
    hum:MoveTo(dest)

    repeat
        task.wait(0.1)
        local okNear = distanceBetween((getHRP(LocalPlayer) or myHRP).Position, (getHRP(targetPlr) or tgHRP).Position) <= maxDist
        if okNear then return true end
    until (os.clock() - started) > timeout

    -- แผนสำรอง: เทเลพอร์ตไปจุดหน้าเป้าหมาย 1.5 stud (บาง executor อาจไม่อนุญาต ข้ามได้)
    local hrpNow = (getHRP(LocalPlayer) or myHRP)
    local tgNow = (getHRP(targetPlr) or tgHRP)
    if hrpNow and tgNow then
        pcall(function()
            hrpNow.CFrame = CFrame.new(tgNow.Position + (hrpNow.Position - tgNow.Position).Unit * 1.5, tgNow.Position)
        end)
        task.wait(0.1)
        if distanceBetween(hrpNow.Position, tgNow.Position) <= maxDist + 1 then
            return true
        end
    end
    return false, "cannot get close enough"
end

-- === Helpers: อ่านคลังไข่จาก PlayerGui.Data.Egg ===
local function _getEggFolder()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    return data and data:FindFirstChild("Egg") or nil
end

-- normalize mutation ให้ Dino/Jurassic เท่ากัน
local function normalizeMut(m)
    if not m then return nil end
    m = tostring(m)
    if m == "Jurassic" then return "Dino" end
    return m
end

local function listEggsFiltered(typeFilterSet, mutFilterSet, limitCount)
    local eg = _getEggFolder()
    local list = {}
    if not eg then return list end

    for _, ch in ipairs(eg:GetChildren()) do
        if #ch:GetChildren() == 0 then
            local T = ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name
            local M = normalizeMut(ch:GetAttribute("M") or ch:GetAttribute("Mutate"))
            -- (รองรับ Snow และ Dino แบบตรง ๆ อยู่แล้ว)

            local okType = (not typeFilterSet) or (next(typeFilterSet) == nil) or typeFilterSet[tostring(T)]
            local okMut  = (not mutFilterSet)  or (next(mutFilterSet)  == nil) or mutFilterSet[tostring(M or "")]
            if okType and okMut then
                table.insert(list, { uid = ch.Name, T = tostring(T), M = M })
                if limitCount and #list >= limitCount then break end
            end
        end
    end
    return list
end

-- === ใส่ไข่เข้ามือ (สล๊อต 2) ===
local function holdEgg(uid)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    local deploy = data and data:FindFirstChild("Deploy")
    if deploy then
        deploy:SetAttribute("S2", "Egg_" .. uid)
    end
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Two, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Two, false, game)
end

-- === Core Gift ===
local GiftRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("GiftRE")

local function giftOnce(targetPlayer, eggUID)
    if not targetPlayer or not targetPlayer.Parent then
        return false, "Invalid target"
    end
    if not eggUID then
        return false, "No egg UID"
    end

    -- 1) เดินให้เข้าใกล้ก่อน (แก้ปัญหาอยู่ไกลไม่ส่ง)
    local nearOk, why = approachTarget(targetPlayer, 7, 6)
    if not nearOk then
        return false, "not near target: " .. tostring(why)
    end

    -- 2) ถือไข่ไว้ในมือ
    holdEgg(eggUID)
    task.wait(0.15)

    -- 3) ยิง Remote
    local ok, err = pcall(function()
        GiftRE:FireServer(targetPlayer)
    end)
    if not ok then
        -- ลองขยับเข้าไปอีกนิดแล้วซ้ำ 1 ครั้ง
        approachTarget(targetPlayer, 5, 2)
        ok = pcall(function() GiftRE:FireServer(targetPlayer) end)
    end

    task.wait(0.25)
    return ok == true
end

-- ========== WindUI (สร้างถ้ายังไม่มี) ==========
local WindUI = rawget(getfenv(0), "WindUI")
if not WindUI then
    local ok, lib = pcall(function()
        return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
    end)
    if ok and lib then WindUI = lib end
end

local Window, Tabs
if WindUI and WindUI.CreateWindow then
    Window = Window or WindUI:CreateWindow({
        Title = "Build A Zoo",
        Icon = "gift",
        IconThemed = true,
        Author = "Zebux",
        Folder = "Zebux",
        Size = UDim2.fromOffset(520, 360),
        Transparent = true,
        Theme = "Dark",
    })
    Tabs = Tabs or {}
    Tabs.MainSection = (Window.Section and Window:Section({ Title = "🎁 Gift Tools", Opened = true })) or nil
end

local RootSection = (Tabs and Tabs.MainSection) or (Window and Window)
local GiftTab = RootSection and RootSection.Tab and RootSection:Tab({ Title = "🎁 | Gift" }) or nil

-- ===== UI State =====
local selectedTargetName = nil
local selectedTypes = {}
local selectedMuts  = {}
local giftAmount    = 1
local autoGiftOn    = false
local autoGiftThread

-- === สร้างรายการผู้เล่น ===
local function buildPlayerList()
    local arr = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then table.insert(arr, plr.Name) end
    end
    table.sort(arr)
    return arr
end

local function makeSetFromArray(arr)
    local s = {}
    for _, v in ipairs(arr or {}) do s[tostring(v)] = true end
    return s
end

-- === UI ===
if GiftTab then
    GiftTab:Section({ Title = "🎁 Auto Gift", Icon = "gift" })

    local targetDropdown = GiftTab:Dropdown({
        Title = "🎯 Target Player",
        Desc  = "เลือกผู้รับของ",
        Values = buildPlayerList(),
        Value  = nil,
        Multi  = false,
        Callback = function(v) selectedTargetName = v end
    })

    GiftTab:Button({
        Title = "🔄 Refresh Player List",
        Callback = function()
            if targetDropdown and targetDropdown.SetList then
                targetDropdown:SetList(buildPlayerList())
            end
        end
    })

    GiftTab:Dropdown({
        Title = "🥚 Types (multi)",
        Desc  = "ว่างไว้ = ทุกประเภท",
        Values = {"BasicEgg","RareEgg","SuperRareEgg","EpicEgg","LegendEgg","PrismaticEgg","HyperEgg","VoidEgg","BowserEgg","DemonEgg","BoneDragonEgg","UltraEgg","DinoEgg","FlyEgg","UnicornEgg","AncientEgg"},
        Multi = true,
        AllowNone = true,
        Callback = function(arr) selectedTypes = makeSetFromArray(arr) end
    })

    -- เพิ่ม Snow และ Dino (และรองรับ Jurassic เป็น alias ของ Dino)
    GiftTab:Dropdown({
        Title = "🧬 Mutations (multi)",
        Desc  = "ว่างไว้ = ทุกชนิด",
        Values = {"Golden","Diamond","Electric","Fire","Snow","Dino"},
        Multi = true,
        AllowNone = true,
        Callback = function(arr)
            selectedMuts = makeSetFromArray(arr)
            -- เผื่อ UI อื่นยังใช้ Jurassic อยู่ ให้ map เข้า Dino ด้วย
            if selectedMuts["Dino"] then selectedMuts["Jurassic"] = true end
        end
    })

    GiftTab:Input({
        Title = "จำนวนที่จะ Gift",
        Desc  = "เช่น 1, 5, 10",
        Value = "1",
        Callback = function(v)
            giftAmount = math.max(1, tonumber(v) or 1)
        end
    })

    GiftTab:Button({
        Title = "🎁 Gift หนึ่งครั้ง (ตามตัวกรอง)",
        Callback = function()
            local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
            if not target then
                WindUI:Notify({ Title="Gift", Content="ยังไม่เลือกผู้รับ", Duration=2 }); return
            end
            local eggs = listEggsFiltered(selectedTypes, selectedMuts, 1)
            if #eggs == 0 then
                WindUI:Notify({ Title="Gift", Content="ไม่พบไข่ตรงเงื่อนไข", Duration=2 }); return
            end
            local ok, err = giftOnce(target, eggs[1].uid)
            WindUI:Notify({
                Title="Gift",
                Content = ok and ("ส่งแล้ว: "..eggs[1].T..(eggs[1].M and (" • "..eggs[1].M) or "")) or ("ล้มเหลว: "..tostring(err)),
                Duration=3
            })
        end
    })

    GiftTab:Toggle({
        Title = "🤖 Auto Gift (เข้าใกล้ + ส่งซ้ำ)",
        Desc  = "จะเดินเข้าไปใกล้ก่อน แล้วส่งตามจำนวนที่ตั้งไว้",
        Value = false,
        Callback = function(state)
            autoGiftOn = state
            if state and not autoGiftThread then
                autoGiftThread = task.spawn(function()
                    while autoGiftOn do
                        local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
                        if not target then task.wait(0.5) continue end

                        local toSend = giftAmount
                        while autoGiftOn and toSend > 0 do
                            local eggs = listEggsFiltered(selectedTypes, selectedMuts, 1)
                            if #eggs == 0 then break end
                            local ok = giftOnce(target, eggs[1].uid)
                            if ok then
                                toSend -= 1
                            else
                                -- ส่งไม่ผ่าน อาจเพราะระยะ/ยกของไม่ทัน รอสักนิดแล้วลองใหม่
                                task.wait(0.4)
                            end
                        end
                        task.wait(0.6)
                    end
                    autoGiftThread = nil
                end)
                WindUI:Notify({ Title="Auto Gift", Content="เริ่มทำงาน (จะเข้าใกล้เป้าหมายอัตโนมัติ)", Duration=3 })
            end
        end
    })
end

-- ใช้แบบสคริปต์ล้วนก็ได้ (หากไม่เปิด UI)
getgenv().GiftUtils = {
    List = function(typeSet, mutSet, limit) return listEggsFiltered(typeSet, mutSet, limit) end,
    Gift = function(targetName, uid)
        local target = Players:FindFirstChild(targetName or "")
        if not target then return false, "No target" end
        return giftOnce(target, uid)
    end
}
