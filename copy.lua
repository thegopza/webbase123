--[[ =======================
       Build A Zoo — Auto Gift
     ======================= ]]

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer

-- === Helper: อ่านคลังไข่จาก PlayerGui.Data.Egg ===
local function _getEggFolder()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    return data and data:FindFirstChild("Egg") or nil
end

local function listEggsFiltered(typeFilterSet, mutFilterSet, limitCount)
    local eg = _getEggFolder()
    local list = {}
    if not eg then return list end

    for _, ch in ipairs(eg:GetChildren()) do
        -- ใช้ได้เมื่อเป็นไข่พร้อมส่ง (ไม่มี subfolder)
        if #ch:GetChildren() == 0 then
            local T = ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name
            local M = ch:GetAttribute("M") or ch:GetAttribute("Mutate")
            if M == "Dino" then M = "Jurassic" end

            local okType = (not typeFilterSet) or (next(typeFilterSet) == nil) or typeFilterSet[tostring(T)]
            local okMut  = (not mutFilterSet)  or (next(mutFilterSet)  == nil) or mutFilterSet[tostring(M or "")]
            if okType and okMut then
                table.insert(list, { uid = ch.Name, T = tostring(T), M = M and tostring(M) or nil })
                if limitCount and #list >= limitCount then break end
            end
        end
    end
    return list
end

-- === Helper: ใส่ไข่เข้ามือ (สล๊อต 2) ===
local function holdEgg(uid)
    -- ใส่ค่า Deploy.S2 เป็น "Egg_<UID>" จากนั้นกดปุ่ม 2
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

-- === Core: ส่งของผ่าน Remote ===
local GiftRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("GiftRE")

local function giftOnce(targetPlayer, eggUID)
    if not targetPlayer or not targetPlayer.Parent then
        return false, "Invalid target"
    end
    if not eggUID then
        return false, "No egg UID"
    end

    -- Equip egg to hand
    holdEgg(eggUID)
    task.wait(0.15)

    -- พยายามยิง Remote ตรง (จาก sniff: Args = [Instance<Player>])
    local ok, err = pcall(function()
        GiftRE:FireServer(targetPlayer)
    end)
    if not ok then
        return false, ("GiftRE failed: %s"):format(tostring(err))
    end

    -- หน่วงเล็กน้อยให้เซิร์ฟเวอร์ตัดไข่ออกจากคลังก่อนสั่งชิ้นต่อไป
    task.wait(0.25)
    return true
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

-- ถ้าโปรเจ็กต์เดิมของคุณมีตัวแปร Tabs อยู่แล้ว (จากสคริปต์ใหญ่)
-- จะลอง reuse แทน
local RootSection = (Tabs and Tabs.MainSection) or (Window and Window) -- ตกลงใช้ window

local GiftTab
if RootSection and RootSection.Tab then
    GiftTab = RootSection:Tab({ Title = "🎁 | Gift" })
end

-- ===== UI State =====
local selectedTargetName = nil
local selectedTypes = {}     -- set: { ["UltraEgg"]=true, ... }
local selectedMuts  = {}     -- set: { ["Golden"]=true, ... }
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

-- === คีย์ช่วย ===
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

    -- Type & Mutation อ้างอิงจากของที่คุณมีในเกมจริง (อ่านสดจาก Data.Egg)
    GiftTab:Dropdown({
        Title = "🥚 Types (multi)",
        Desc  = "ว่างไว้ = ทุกประเภท",
        Values = {"BasicEgg","RareEgg","SuperRareEgg","EpicEgg","LegendEgg","PrismaticEgg","HyperEgg","VoidEgg","BowserEgg","DemonEgg","BoneDragonEgg","UltraEgg","DinoEgg","FlyEgg","UnicornEgg","AncientEgg"},
        Multi = true,
        AllowNone = true,
        Callback = function(arr) selectedTypes = makeSetFromArray(arr) end
    })

    GiftTab:Dropdown({
        Title = "🧬 Mutations (multi)",
        Desc  = "ว่างไว้ = ทุกชนิดกลายพันธุ์",
        Values = {"Golden","Diamond","Electric","Fire","Jurassic"},
        Multi = true,
        AllowNone = true,
        Callback = function(arr) selectedMuts = makeSetFromArray(arr) end
    })

    local amountInput = GiftTab:Input({
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
        Title = "🤖 Auto Gift (วนตามจำนวน)",
        Desc  = "จะส่งตามจำนวนที่ตั้งไว้โดยใช้ตัวกรอง",
        Value = false,
        Callback = function(state)
            autoGiftOn = state
            if state and not autoGiftThread then
                autoGiftThread = task.spawn(function()
                    while autoGiftOn do
                        local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
                        if not target then
                            task.wait(0.5); continue
                        end
                        local toSend = giftAmount
                        while autoGiftOn and toSend > 0 do
                            local eggs = listEggsFiltered(selectedTypes, selectedMuts, 1)
                            if #eggs == 0 then break end
                            local ok = giftOnce(target, eggs[1].uid)
                            if ok then
                                toSend -= 1
                            else
                                -- ถ้าส่งไม่ผ่าน รอหน่อย
                                task.wait(0.3)
                            end
                        end
                        -- ถ้าไข่หมด/ครบจำนวนแล้ว พักก่อนรอบถัดไป
                        task.wait(0.6)
                    end
                    autoGiftThread = nil
                end)
                WindUI:Notify({ Title="Auto Gift", Content="เริ่มทำงาน", Duration=2 })
            end
        end
    })
end

-- ป้องกันกรณีไม่มี WindUI: สามารถเรียกใช้ฟังก์ชัน giftOnce เองได้
getgenv().GiftUtils = {
    List = function(typeSet, mutSet, limit) return listEggsFiltered(typeSet, mutSet, limit) end,
    Gift = function(targetName, uid)
        local target = Players:FindFirstChild(targetName or "")
        if not target then return false, "No target" end
        return giftOnce(target, uid)
    end
}
