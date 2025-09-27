-- Build A Zoo — Auto Gift (fixed player dropdown + TP + batch send)

-- ========== Services ==========
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer
local GiftRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("GiftRE")

-- ========== Safe WindUI loader (fallback if unavailable) ==========
local function tryLoadWindUI()
    local okHttp, src = pcall(function()
        return game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
    end)
    if not okHttp then return nil end
    local loader = (loadstring or load)
    if type(loader) ~= "function" then return nil end
    local okCompile, fn = pcall(loader, src)
    if not okCompile then return nil end
    local okRun, lib = pcall(fn)
    return okRun and lib or nil
end

local function miniUI()
    local g=Instance.new("ScreenGui",game:GetService("CoreGui")); g.Name="GiftMiniUI"; g.ResetOnSpawn=false
    local f=Instance.new("Frame",g); f.Position=UDim2.fromOffset(20,180); f.Size=UDim2.fromOffset(360,260)
    f.BackgroundColor3=Color3.fromRGB(30,30,30); f.BackgroundTransparency=.1
    local y=8
    local function label(txt)
        local t=Instance.new("TextLabel",f); t.Size=UDim2.new(1,-16,0,18); t.Position=UDim2.fromOffset(8,y)
        t.BackgroundTransparency=1; t.Font=Enum.Font.GothamBold; t.TextSize=14; t.TextColor3=Color3.new(1,1,1); t.Text=txt
        y=y+20
    end
    local API={}
    function API:CreateWindow() return self end
    function API:Section() return self end
    function API:Tab() return self end
    function API:Dropdown(o)
        label(o.Title or "Dropdown")
        local dd={_sel=nil,_vals=o.Values or {}}
        function dd:GetValue() return self._sel end
        function dd:SetValues(v) self._vals=v end
        function dd:SetList(v) self._vals=v end
        function dd:Set(v) self._sel=v if o.Callback then o.Callback(v) end end
        return dd
    end
    function API:Input(o) label(o.Title or "Input"); local b={Set=function(_,v) if o.Callback then o.Callback(v) end end}; return b end
    function API:Button(o) label("• "..(o.Title or "Button").." (use code to click)"); return {Click=function() if o.Callback then o.Callback() end end} end
    function API:Toggle(o) label("[ ] "..(o.Title or "Toggle")); return {Set=function(_,v) if o.Callback then o.Callback(v) end end} end
    function API:Paragraph(o)
        local t=Instance.new("TextLabel",f); t.BackgroundTransparency=1; t.Font=Enum.Font.Gotham; t.TextXAlignment=Enum.TextXAlignment.Left
        t.TextWrapped=true; t.TextColor3=Color3.fromRGB(235,235,235); t.TextSize=13
        t.Position=UDim2.fromOffset(8,y); t.Size=UDim2.new(1,-16,1,-y-8); t.Text=o.Desc or ""
        return { SetDesc=function(_,d) t.Text=d end }
    end
    function API:EditOpenButton() end
    function API:Notify() end
    return API
end

local WindUI = tryLoadWindUI() or miniUI()

-- ========== Window / Tab ==========
local Window = WindUI:CreateWindow({ Title="Build A Zoo", Icon="gift", IconThemed=true, Author="Zebux" })
local Sec    = Window:Section({ Title="🎁 Gift Tools", Opened=true })
local Tab    = Sec:Tab({ Title="🎁 | Gift" })

-- ========== Helpers ==========
local function getHRP(plr) local c=plr and plr.Character return c and c:FindFirstChild("HumanoidRootPart") end

local function teleportToTarget(target, offset)
    offset = offset or 1.8
    local my = getHRP(LocalPlayer); local tg = getHRP(target)
    if not (my and tg) then return false end
    local dir = (my.Position - tg.Position)
    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
    my.CFrame = CFrame.new(tg.Position + dir.Unit*offset, tg.Position)
    task.wait(0.1); return true
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
    local eg = EggFolder(); local out = {}
    if not eg then return out end
    for _,ch in ipairs(eg:GetChildren()) do
        if #ch:GetChildren()==0 then
            local T=tostring(ch:GetAttribute("T") or ch:GetAttribute("Type") or ch.Name)
            local M=normalizeMut(ch:GetAttribute("M") or ch:GetAttribute("Mutate"))
            local okT = (not typeSet) or (next(typeSet)==nil) or typeSet[T]
            local okM = (not mutSet)  or (next(mutSet)==nil)  or mutSet[tostring(M or "")]
            if okT and okM then
                table.insert(out,{uid=ch.Name,T=T,M=M})
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

local function giftOnce(target, egg)
    teleportToTarget(target, 1.6)
    holdEgg(egg.uid)
    task.wait(0.08)
    local ok = pcall(function() GiftRE:FireServer(target) end)
    task.wait(0.18)
    return ok
end

local function toSet(arr) local s={} for _,v in ipairs(arr or {}) do s[tostring(v)]=true end return s end

-- ========== UI State ==========
local selectedTargetName
local selectedTypes = {}
local selectedMuts  = {}
local amountStr     = ""
local progress

-- Build current other-player list (show values at creation!)
local function otherPlayerNames()
    local names={}
    for _,p in ipairs(Players:GetPlayers()) do if p~=LocalPlayer then table.insert(names,p.Name) end end
    table.sort(names); return names
end

-- Target dropdown (FIX: put initial Values)
local playersDD = Tab:Dropdown({
    Title  = "🎯 Target Player",
    Values = otherPlayerNames(),
    Multi  = false,
    Callback = function(v) selectedTargetName = v end
})

-- Robust refresher (supports different method names)
local function refreshPlayers()
    local names = otherPlayerNames()
    if playersDD.SetValues then
        playersDD:SetValues(names)
    elseif playersDD.SetList then
        playersDD:SetList(names)
    elseif playersDD.Set then
        playersDD:Set(names)
    end
end

-- Auto refresh when players change
Players.PlayerAdded:Connect(refreshPlayers)
Players.PlayerRemoving:Connect(refreshPlayers)

Tab:Button({ Title="🔄 Refresh Players", Callback=refreshPlayers })

Tab:Dropdown({
    Title="🥚 Types (multi) – เว้นว่าง=ทั้งหมด",
    Values={"BasicEgg","RareEgg","SuperRareEgg","EpicEgg","LegendEgg","PrismaticEgg","HyperEgg",
            "VoidEgg","BowserEgg","DemonEgg","BoneDragonEgg","UltraEgg","DinoEgg","FlyEgg","UnicornEgg","AncientEgg"},
    Multi=true, AllowNone=true,
    Callback=function(arr) selectedTypes = toSet(arr) end
})

Tab:Dropdown({
    Title="🧬 Mutations (multi) – เว้นว่าง=ทั้งหมด",
    Values={"Golden","Diamond","Electric","Fire","Snow","Dino"},
    Multi=true, AllowNone=true,
    Callback=function(arr)
        selectedMuts = toSet(arr)
        if selectedMuts["Dino"] then selectedMuts["Jurassic"]=true end -- map Jurassic
    end
})

Tab:Input({
    Title="จำนวนที่จะ Gift (เว้นว่าง/0 = ทั้งหมด)",
    Value="",
    Callback=function(v) amountStr = tostring(v or "") end
})

progress = Tab:Paragraph({ Title="สถานะ", Desc="รอคำสั่ง..." })
local function setProgress(s) if progress and progress.SetDesc then progress:SetDesc(s) end end
local function fmtLine(egg,i,total) return string.format("%s%s %d/%d", egg.T, egg.M and (" • "..egg.M) or "", i, total) end

local function sendBatch(target, amount)
    local totalSent, totalWant = 0, 0
    local pool = listEggsFiltered(selectedTypes, selectedMuts, nil)
    if #pool==0 then setProgress("❌ ไม่พบไข่ตรงตัวกรอง"); return end
    totalWant = (amount and amount>0) and math.min(amount,#pool) or #pool
    setProgress(("เตรียมส่ง %d ชิ้น"):format(totalWant))
    local i=1
    while i<=totalWant do
        local nextOne = listEggsFiltered(selectedTypes, selectedMuts, 1)[1]
        if not nextOne then break end
        if giftOnce(target, nextOne) then
            totalSent += 1
            setProgress("✅ "..fmtLine(nextOne,totalSent,totalWant))
        else
            setProgress("⚠️ ส่งไม่สำเร็จ กำลังลองใหม่…")
            task.wait(0.35)
        end
        i += 1
        task.wait(0.12)
    end
    if totalSent>=totalWant then
        setProgress(("🎉 เสร็จสิ้น %d/%d"):format(totalSent,totalWant))
    else
        setProgress(("⛔ หยุดก่อนครบ %d/%d"):format(totalSent,totalWant))
    end
end

Tab:Button({
    Title="🎁 Gift ตอนนี้",
    Callback=function()
        local target = selectedTargetName and Players:FindFirstChild(selectedTargetName)
        if not target then setProgress("❌ ยังไม่เลือกผู้รับ"); return end
        local n = tonumber((amountStr or ""):gsub("%s+","")) or 0
        if n < 0 then n = 0 end
        sendBatch(target, n)
    end
})
