--[[ =======================
       Build A Zoo — Auto Gift (TP + batch sending + progress UI)
     ======================= ]]

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- Remote
local GiftRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("GiftRE")

-- ========= Helpers =========
local function getHRP(plr)
    plr = plr or LocalPlayer
    local ch = plr and plr.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

-- เทเลพอร์ตไปยืนใกล้เป้าหมาย (off = ระยะจากเป้า)
local function teleportToTarget(targetPlr, off)
    off = off or 2
    local myHRP = getHRP(LocalPlayer)
    local tgHRP = getHRP(targetPlr)
    if not (myHRP and tgHRP) then return false, "no HRP" end
    local dir = (myHRP.Position - tgHRP.Position)
    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
    local dest = tgHRP.Position + dir.Unit * off
    local look = (tgHRP.Position - dest).Unit
    local safeY = dest.Y + 1.5
    pcall(function()
        myHRP.CFrame = CFrame.new(Vector3.new(dest.X, safeY, dest.Z), dest + look)
    end)
    task.wait(0.1)
    return true
end

-- บอกชื่อ mutation ให้เป็นมาตรฐาน (Jurassic ⇒ Dino)
local function normalizeMut(m)
    if not m then return nil end
    m = tostring(m)
    if m == "Jurassic" then return "Dino" end
    return m
end

-- อ่านคลังไข่จาก PlayerGui.Data.Egg + กรองตาม Type/Mutation
local function _getEggFolder()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    return data and data:FindFirstChild("Egg") or nil
end

local function listEggsFiltered(typeSet, mutSet, limit)
    local eg = _getEggFolder()
    local list = {}
    if not eg then return list end
    for _, ch in ipairs(eg:GetChildren()) do
        if #ch:GetChildren() == 0 then
            local T = tostring(ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name)
            local M = normalizeMut(ch:GetAttribute("M") or ch:GetAttribute("Mutate"))
            local passType = (not typeSet) or (next(typeSet)==nil) or typeSet[T]
            local passMut  = (not mutSet)  or (next(mutSet)==nil)  or mutSet[tostring(M or "")]
            if passType and passMut then
                table.insert(list, { uid = ch.Name, T = T, M = M })
                if limit and #list >= limit then break end
            end
        end
    end
    return list
end

-- ใส่ไข่เข้าช่องถือ (สลอต 2) ให้ระบบเกมถือไว้ก่อนยิง Gift
local function holdEgg(uid)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    local deploy = data and data:FindFirstChild("Deploy")
    if deploy then deploy:SetAttribute("S2", "Egg_"..uid) end
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Two, false, game)
    task.wait(0.04)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Two, false, game)
end

-- ส่งของ 1 ชิ้น (TP → hold → FireServer)
local function giftOnce(targetPlayer, egg)
    if not egg then return false, "no egg" end
    local okTP = teleportToTarget(targetPlayer, 1.5)
    if not okTP then return false, "tp fail" end

    holdEgg(egg.uid)
    task.wait(0.12)
    local ok = pcall(function()
        GiftRE:FireServer(targetPlayer)
    end)
    task.wait(0.22)
    return ok == true
end

-- ========= WindUI =========
local WindUI = rawget(getfenv(0), "WindUI")
if not WindUI then
    local ok, lib = pcall(function()
        return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
    end)
    if ok and lib then WindUI = lib end
end

local Window = WindUI:CreateWindow({
    Title = "Build A Zoo",
    Icon = "gift",
    IconThemed = true,
    Author = "MheeNahee",
    Folder = "MheeNahee",
    Size = UDim2.fromOffset(520, 360),
    Transparent = true,
    Theme = "Dark",
})
local Section = Window:Section({ Title = "🎁 Gift Tools", Opened = true })
local GiftTab = Section:Tab({ Title = "🎁 | Gift" })

-- ========= UI State =========
local function makeSet(tbl) local s={} for _,v in ipairs(tbl or {}) do s[tostring(v)]=true end return s end
local selectedTargetName
local selectedTypes = {}
local selectedMuts  = {}
local desiredCountInput = ""   -- เว้นว่าง = ส่งทั้งหมด
local autoGift = false
local autoThread

-- progress
local totalSent, totalTarget = 0, 0
local lastLine = "-"
local function fmtItemLine(egg, idx, total)
    local mut = egg.M and (" • "..egg.M) or ""
    return string.format("%s%s %d/%d", egg.T, mut, idx, total)
end

-- UI parts
local playersDropdown = GiftTab:Dropdown({
    Title = "🎯 Target Player",
    Values = {},
    Multi  = false,
    Callback = function(v) selectedTargetName = v end
})
local function refreshPlayers()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(list, p.Name) end
    end
    table.sort(list)
    if playersDropdown.SetList then playersDropdown:SetList(list) end
end
GiftTab:Button({ Title="🔄 Refresh Players", Callback=refreshPlayers })
refreshPlayers()

GiftTab:Dropdown({
    Title = "🥚 Types (multi)",
    Desc  = "ว่างไว้ = ทุกประเภท",
    Values = {"BasicEgg","RareEgg","SuperRareEgg","EpicEgg","LegendEgg","PrismaticEgg","HyperEgg","VoidEgg","BowserEgg","DemonEgg","BoneDragonEgg","UltraEgg","DinoEgg","FlyEgg","UnicornEgg","AncientEgg"},
    Multi  = true, AllowNone = true,
    Callback = function(arr) selectedTypes = makeSet(arr) end
})

-- เพิ่ม Snow + Dino (และยอมรับ Jurassic เป็น Dino)
GiftTab:Dropdown({
    Title = "🧬 Mutations (multi)",
    Desc  = "ว่างไว้ = ทุกชนิด",
    Values = {"Golden","Diamond","Electric","Fire","Snow","Dino"},
    Multi  = true, AllowNone = true,
    Callback = function(arr)
        selectedMuts = makeSet(arr)
        if selectedMuts["Dino"] then selectedMuts["Jurassic"] = true end
    end
})

GiftTab:Input({
    Title = "จำนวนที่จะ Gift (เว้นว่าง = ทั้งหมด)",
    Value = "",
    Callback = function(v)
        desiredCountInput = tostring(v or ""):match("^%s*(.-)%s*$")
    end
})

local progressPara = GiftTab:Paragraph({
    Title = "สถานะ",
    Desc  = "รอคำสั่ง...",
    Image = "activity", ImageSize = 20
})
local function setProgress(desc)
    if progressPara and progressPara.SetDesc then progressPara:SetDesc(desc) end
end

local function sendBatch(targetPlayer, amountOrNil)
    totalSent, totalTarget = 0, 0
    lastLine = "-"

    -- เตรียมรายการไข่ทั้งหมดที่ “ตรงเงื่อนไข”
    local all = listEggsFiltered(selectedTypes, selectedMuts, nil)
    if #all == 0 then
        setProgress("❌ ไม่พบไข่ตรงเงื่อนไข")
        return
    end

    -- คำนวนเป้าหมาย
    if amountOrNil and amountOrNil > 0 then
        totalTarget = math.min(amountOrNil, #all)
    else
        totalTarget = #all -- ส่งทั้งหมด
    end

    setProgress(("เตรียมส่ง %d ชิ้น"):format(totalTarget))

    -- ส่งทีละ 1 ชิ้นจนกว่าจะครบ / หรือของหมด
    local idx = 1
    while idx <= totalTarget do
        -- ดึง egg สด ๆ เผื่อเมื่อกี้เพิ่งลดไป
        local eggsNow = listEggsFiltered(selectedTypes, selectedMuts, 1)
        if #eggsNow == 0 then break end
        local egg = eggsNow[1]

        local ok = giftOnce(targetPlayer, egg)
        if ok then
            totalSent += 1
            lastLine = fmtItemLine(egg, totalSent, totalTarget)
            setProgress("✅ " .. lastLine)
        else
            setProgress("⚠️ ส่งไม่สำเร็จ ลองใหม่...")
            task.wait(0.35)
            -- ลองใหม่รอบเดียวที่ index เดิม
        end

        idx += 1
        task.wait(0.15)
    end

    if totalSent >= totalTarget then
        setProgress(("🎉 เสร็จสิ้น ส่งแล้ว %d/%d\nรายการล่าสุด: %s"):format(totalSent,totalTarget,lastLine))
    else
        setProgress(("⛔ หยุดก่อนครบ ส่งได้ %d/%d\nรายการล่าสุด: %s"):format(totalSent,totalTarget,lastLine))
    end
end

GiftTab:Button({
    Title = "🎁 Gift ตอนนี้ (ส่งต่อเนื่องจนถึงจำนวนที่ตั้ง)",
    Callback = function()
        local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
        if not target then
            setProgress("❌ ยังไม่เลือกผู้รับ"); return
        end
        -- จำนวน: เว้นว่าง ⇒ ทั้งหมด
        local num = tonumber(desiredCountInput or "")
        if num then num = math.max(1, math.floor(num)) end
        sendBatch(target, num)
    end
})

GiftTab:Toggle({
    Title = "🤖 Auto Gift (วนส่งเรื่อย ๆ)",
    Desc  = "จะเทเลพอร์ตเข้าใกล้ก่อนทุกครั้ง แล้วส่งตามตัวกรอง",
    Value = false,
    Callback = function(state)
        autoGift = state
        if state and not autoThread then
            autoThread = task.spawn(function()
                while autoGift do
                    local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
                    if not target then setProgress("❌ ยังไม่เลือกผู้รับ"); task.wait(0.6) goto CONT end

                    local num = tonumber(desiredCountInput or "")
                    if num then num = math.max(1, math.floor(num)) end
                    sendBatch(target, num)

                    task.wait(0.8)
                    ::CONT::
                end
                autoThread = nil
            end)
            setProgress("เริ่ม Auto Gift …")
        end
    end
})
