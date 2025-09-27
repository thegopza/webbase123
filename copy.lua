--[[ Build A Zoo — Auto Gift (TP + batch send + progress UI, safe loader)
     - ไม่พึ่ง loadstring ถ้าไม่มี: จะใช้ UI จำลอง
     - เทเลพอร์ตไปหาเป้าหมายก่อนส่ง
     - ส่งทีละ 1 จนครบจำนวน (ถ้าช่องจำนวนว่าง/0 => ส่งทั้งหมดที่ตรงตัวกรอง)
     - รองรับ Mutation: Snow, Dino (รวม Jurassic)
     - Progress ตัวอย่าง: "BoneDragon • Snow 3/20"
--]]

-- ========= Services / Basics =========
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer
local GiftRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("GiftRE")

-- ========= Safe WindUI Loader (fallback if loadstring not available) =========
local function tryLoadWindUI()
    local okHttp, src = pcall(function()
        return game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
    end)
    if not okHttp or type(src) ~= "string" then return nil end
    local loader = (loadstring or load) -- some executors expose `load`
    if type(loader) ~= "function" then return nil end
    local okCompile, fn = pcall(loader, src)
    if not okCompile or type(fn) ~= "function" then return nil end
    local okRun, lib = pcall(fn)
    if okRun then return lib end
    return nil
end

-- very small fallback “UI” that mimics needed api
local function makeFallbackUI()
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "AutoGiftUI"
    ScreenGui.IgnoreGuiInset = true
    ScreenGui.ResetOnSpawn = false
    ScreenGui.Parent = game:GetService("CoreGui")

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(360, 260)
    frame.Position = UDim2.fromScale(0, 0.2)
    frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.Parent = ScreenGui

    local function title(lbl, y)
        local t = Instance.new("TextLabel")
        t.Text = lbl
        t.Font = Enum.Font.GothamBold
        t.TextSize = 14
        t.TextColor3 = Color3.fromRGB(255,255,255)
        t.BackgroundTransparency = 1
        t.Size = UDim2.new(1, -16, 0, 18)
        t.Position = UDim2.fromOffset(8, y)
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.Parent = frame
    end

    local api = {}
    function api:CreateWindow() return self end
    function api:Section() return self end
    function api:Tab() return self end

    function api:Dropdown(opts)
        title(opts.Title or "Dropdown", (opts._y or 8)); opts._y = (opts._y or 8) + 18
        local dd = { _values = opts.Values or {}, _sel = {}, Multi = opts.Multi, SetList = function(self, list) self._values=list end }
        function dd:_set(v)
            if self.Multi then
                self._sel = {}
                for _,x in ipairs(v or {}) do self._sel[x]=true end
            else
                self._sel = v
            end
            if opts.Callback then opts.Callback(v) end
        end
        -- no widget, caller uses SetList/Callback programmatically
        return dd
    end

    function api:Input(opts)
        title(opts.Title or "Input", (opts._y or 8)); opts._y = (opts._y or 8) + 18
        local box = { _val = opts.Value or "" }
        function box:Set(v) self._val = v if opts.Callback then opts.Callback(v) end end
        return box
    end

    function api:Button(opts)
        title("• " .. (opts.Title or "Button") .. " (click in code)", (opts._y or 8)); opts._y = (opts._y or 8) + 18
        return { Click = function() if opts.Callback then opts.Callback() end end }
    end

    function api:Toggle(opts)
        title("[ ] " .. (opts.Title or "Toggle"), (opts._y or 8)); opts._y = (opts._y or 8) + 18
        local t = { _on = opts.Value or false }
        function t:Set(v) self._on = v if opts.Callback then opts.Callback(v) end end
        return t
    end

    function api:Paragraph(opts)
        local lab = Instance.new("TextLabel")
        lab.Text = (opts.Desc or "")
        lab.Font = Enum.Font.Gotham
        lab.TextSize = 13
        lab.TextColor3 = Color3.fromRGB(230,230,230)
        lab.BackgroundTransparency = 1
        lab.TextWrapped = true
        lab.TextXAlignment = Enum.TextXAlignment.Left
        lab.Size = UDim2.new(1,-16,1,-(opts._y or 8)-8)
        lab.Position = UDim2.fromOffset(8, (opts._y or 8))
        lab.Parent = frame
        return { SetDesc = function(_, d) lab.Text = d end }
    end

    -- expose helpers used below
    function api:CreateWindow() return self end
    function api:EditOpenButton() end
    function api:Notify() end
    return api
end

local WindUI = rawget(getfenv(0),"WindUI") or tryLoadWindUI() or makeFallbackUI()

-- ========= Minimal “window”/tab using whichever UI we have =========
local Window = WindUI:CreateWindow({ Title = "Build A Zoo", Icon = "gift", IconThemed = true, Author = "Zebux" })
local Sec = Window:Section({ Title = "🎁 Gift Tools", Opened = true })
local Tab = Sec:Tab({ Title = "🎁 | Gift" })

-- ========= Helpers =========
local function getHRP(plr)
    local ch = plr and plr.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function teleportToTarget(targetPlr, off)
    off = off or 2
    local myHRP = getHRP(LocalPlayer)
    local tgHRP = getHRP(targetPlr)
    if not (myHRP and tgHRP) then return false end
    local dir = (myHRP.Position - tgHRP.Position)
    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
    local dest = tgHRP.Position + dir.Unit * off
    pcall(function()
        myHRP.CFrame = CFrame.new(dest, tgHRP.Position)
    end)
    task.wait(0.1)
    return true
end

local function normalizeMut(m)
    if not m then return nil end
    m = tostring(m)
    if m == "Jurassic" then return "Dino" end
    return m
end

local function EggFolder()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    return data and data:FindFirstChild("Egg") or nil
end

local function listEggsFiltered(typeSet, mutSet, limit)
    local eg = EggFolder()
    local out = {}
    if not eg then return out end
    for _, ch in ipairs(eg:GetChildren()) do
        if #ch:GetChildren() == 0 then
            local T = tostring(ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name)
            local M = normalizeMut(ch:GetAttribute("M") or ch:GetAttribute("Mutate"))
            local okT = (not typeSet) or (next(typeSet)==nil) or typeSet[T]
            local okM = (not mutSet)  or (next(mutSet)==nil)  or mutSet[tostring(M or "")]
            if okT and okM then
                table.insert(out, { uid = ch.Name, T=T, M=M })
                if limit and #out>=limit then break end
            end
        end
    end
    return out
end

local function holdEgg(uid)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    local deploy = data and data:FindFirstChild("Deploy")
    if deploy then deploy:SetAttribute("S2","Egg_"..uid) end
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Two, false, game)
    task.wait(0.04)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Two, false, game)
end

local function giftOnce(targetPlayer, egg)
    if not egg then return false end
    teleportToTarget(targetPlayer, 1.5)
    holdEgg(egg.uid)
    task.wait(0.1)
    local ok = pcall(function()
        GiftRE:FireServer(targetPlayer)
    end)
    task.wait(0.2)
    return ok
end

-- ========= UI State =========
local function makeSet(tbl) local s={} for _,v in ipairs(tbl or {}) do s[tostring(v)]=true end return s end

local selectedTargetName
local selectedTypes = {}
local selectedMuts  = {}
local countStr = ""
local totalSent,totalTarget,lastLine = 0,0,"-"

-- ========= UI =========
local playersDD = Tab:Dropdown({
    Title = "🎯 Target Player",
    Values = {},
    Multi  = false,
    Callback = function(v) selectedTargetName = v end
})
local function refreshPlayers()
    local names = {}
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(names, p.Name) end
    end
    table.sort(names)
    if playersDD.SetList then playersDD:SetList(names) end
end
refreshPlayers()

Tab:Button({ Title="🔄 Refresh Players", Callback=refreshPlayers })

Tab:Dropdown({
    Title = "🥚 Types (multi) – ว่าง = ทุกชนิด",
    Values = {"BasicEgg","RareEgg","SuperRareEgg","EpicEgg","LegendEgg","PrismaticEgg","HyperEgg","VoidEgg",
              "BowserEgg","DemonEgg","BoneDragonEgg","UltraEgg","DinoEgg","FlyEgg","UnicornEgg","AncientEgg"},
    Multi  = true, AllowNone = true,
    Callback = function(arr) selectedTypes = makeSet(arr) end
})

Tab:Dropdown({
    Title = "🧬 Mutations (multi) – ว่าง = ทุกมิว",
    Values = {"Golden","Diamond","Electric","Fire","Snow","Dino"},
    Multi  = true, AllowNone = true,
    Callback = function(arr)
        selectedMuts = makeSet(arr)
        if selectedMuts["Dino"] then selectedMuts["Jurassic"] = true end
    end
})

Tab:Input({
    Title = "จำนวนที่จะ Gift (เว้นว่าง/0 = ทั้งหมด)",
    Value = "",
    Callback = function(v) countStr = tostring(v or "") end
})

local progress = Tab:Paragraph({ Title = "สถานะ", Desc = "รอคำสั่ง..." })
local function setProgress(s) if progress and progress.SetDesc then progress:SetDesc(s) end end
local function fmtLine(egg, idx, total) local mut = egg.M and (" • "..egg.M) or "" return string.format("%s%s %d/%d", egg.T, mut, idx, total) end

local function sendBatch(targetPlayer, amountOrNil)
    totalSent,totalTarget,lastLine = 0,0,"-"
    local all = listEggsFiltered(selectedTypes, selectedMuts, nil)
    if #all==0 then setProgress("❌ ไม่พบไข่ตรงตัวกรอง"); return end
    totalTarget = (amountOrNil and amountOrNil>0) and math.min(amountOrNil,#all) or #all
    setProgress(("เตรียมส่ง %d ชิ้น"):format(totalTarget))
    local idx = 1
    while idx <= totalTarget do
        local eggsNow = listEggsFiltered(selectedTypes, selectedMuts, 1)
        if #eggsNow==0 then break end
        local egg = eggsNow[1]
        if giftOnce(targetPlayer, egg) then
            totalSent += 1
            lastLine = fmtLine(egg,totalSent,totalTarget)
            setProgress("✅ "..lastLine)
        else
            setProgress("⚠️ ส่งไม่สำเร็จ กำลังลองใหม่...")
            task.wait(0.35)
        end
        idx += 1
        task.wait(0.15)
    end
    if totalSent>=totalTarget then
        setProgress(("🎉 เสร็จสิ้น %d/%d\nล่าสุด: %s"):format(totalSent,totalTarget,lastLine))
    else
        setProgress(("⛔ หยุดก่อนครบ %d/%d\nล่าสุด: %s"):format(totalSent,totalTarget,lastLine))
    end
end

Tab:Button({
    Title = "🎁 Gift ตอนนี้",
    Callback = function()
        local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
        if not target then setProgress("❌ ยังไม่เลือกผู้รับ"); return end
        local n = tonumber((countStr or ""):gsub("%s+","")) or 0
        if n < 0 then n = 0 end
        sendBatch(target, n)
    end
})
