-- Build A Zoo — Auto Gift (Target dropdown fixed + TP + batch + progress) 2

-- ====== Services ======
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- Remote (ตามที่ sniff มา: ReplicatedStorage.Remote.GiftRE)
local GiftRE = ReplicatedStorage:WaitForChild("Remote"):WaitForChild("GiftRE")

-- ====== Load WindUI (fallback มินิ UI ถ้าโหลดไม่ได้) ======
local function loadWindUI()
    local ok, src = pcall(function()
        return game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
    end)
    if not ok then return nil end
    local loader = (loadstring or load)
    if type(loader) ~= "function" then return nil end
    local ok2, fn = pcall(loader, src); if not ok2 then return nil end
    local ok3, lib = pcall(fn); if not ok3 then return nil end
    return lib
end

local function miniUI()
    local g=Instance.new("ScreenGui", game:GetService("CoreGui")); g.Name="GiftMiniUI"; g.ResetOnSpawn=false
    local f=Instance.new("Frame", g); f.Position=UDim2.fromOffset(20,180); f.Size=UDim2.fromOffset(360,280)
    f.BackgroundColor3=Color3.fromRGB(28,28,28); f.BorderSizePixel=0
    local y=6
    local function line(txt)
        local t=Instance.new("TextLabel",f); t.BackgroundTransparency=1; t.Font=Enum.Font.GothamBold
        t.TextColor3=Color3.new(1,1,1); t.TextSize=14; t.TextXAlignment=Enum.TextXAlignment.Left
        t.Position=UDim2.fromOffset(8,y); t.Size=UDim2.new(1,-16,0,18); t.Text=txt; y=y+20
    end
    local API={}
    function API:CreateWindow() return self end
    function API:Section() return self end
    function API:Tab() return self end
    function API:Dropdown(o)
        line("• "..(o.Title or "Dropdown"))
        local d={_vals=o.Values or {}, _sel=nil}
        function d:GetValue() return self._sel end
        function d:SetValues(v) self._vals=v end
        function d:SetList(v) self._vals=v end
        function d:Set(v) self._sel=v if o.Callback then o.Callback(v) end end
        return d
    end
    function API:Input(o) line("• "..(o.Title or "Input")); return { Set=function(_,v) if o.Callback then o.Callback(v) end end } end
    function API:Button(o) line("• "..(o.Title or "Button").." (click by code)")
        return { Click=function() if o.Callback then o.Callback() end end }
    end
    function API:Paragraph(o)
        local t=Instance.new("TextLabel",f); t.BackgroundTransparency=1; t.Font=Enum.Font.Gotham; t.TextWrapped=true
        t.TextXAlignment=Enum.TextXAlignment.Left; t.TextColor3=Color3.fromRGB(230,230,230); t.TextSize=13
        t.Position=UDim2.fromOffset(8,y); t.Size=UDim2.new(1,-16,1,-y-8); t.Text=o.Desc or ""
        return { SetDesc=function(_,d) t.Text=d end, Set=function(_,d) t.Text=d end, SetText=function(_,d) t.Text=d end }
    end
    function API:EditOpenButton() end
    function API:Notify() end
    return API
end

local WindUI = loadWindUI() or miniUI()

-- ====== Window / Tab ======
local Window = WindUI:CreateWindow({ Title="Build A Zoo", Icon="gift", IconThemed=true, Author="Zebux" })
local Sec    = Window:Section({ Title="🎁 Gift Tools", Opened=true })
local Tab    = Sec:Tab({ Title="🎁 | Gift" })

-- ====== Helpers ======
local function getHRP(plr) local c=plr and plr.Character return c and c:FindFirstChild("HumanoidRootPart") end

local function nearestOtherPlayer()
    local my = getHRP(LocalPlayer); if not my then return nil end
    local best,bd = nil,1e9
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local hrp = getHRP(p)
            if hrp then
                local d = (hrp.Position - my.Position).Magnitude
                if d < bd then bd = d; best = p end
            end
        end
    end
    return best
end

local function teleportToTarget(target, offset)
    offset = offset or 1.6
    local my = getHRP(LocalPlayer); local tg = getHRP(target)
    if not (my and tg) then return false end
    -- ป้องกันยืนซ้อนตัว
    local dir = (my.Position - tg.Position)
    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
    my.CFrame = CFrame.new(tg.Position + dir.Unit*offset, tg.Position)
    task.wait(0.08)
    return true
end

local function EggFolder()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local data = pg and pg:FindFirstChild("Data")
    return data and data:FindFirstChild("Egg") or nil
end

local function normalizeMut(m)
    if not m then return nil end
    m = tostring(m)
    if m == "Jurassic" then return "Dino" end
    return m
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
    task.wait(0.06)
    local ok, err = pcall(function() GiftRE:FireServer(target) end)
    if not ok then warn("[Gift] FireServer error: ", err) end
    task.wait(0.16) -- เว้นจังหวะเครือข่าย/แอนิเมชัน
    return ok
end

local function toSet(arr) local s={} for _,v in ipairs(arr or {}) do s[tostring(v)]=true end return s end

-- ====== UI State ======
local selectedTargetName = nil   -- หรือ "[Nearest]"
local selectedTypes = {}
local selectedMuts  = {}
local amountStr     = ""

-- รายชื่อผู้เล่น (มีค่าเริ่ม รวม [Nearest])
local function playerNameList()
    local list = {"[Nearest]"}
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(list, p.Name) end
    end
    table.sort(list, function(a,b)
        if a=="[Nearest]" then return true end
        if b=="[Nearest]" then return false end
        return a<b
    end)
    return list
end

-- Target dropdown (สร้างพร้อมค่าเริ่มเลย)
local targetDD = Tab:Dropdown({
    Title  = "🎯 Target Player",
    Values = playerNameList(),
    Multi  = false,
    Callback = function(v) selectedTargetName = v end
})

local function refreshPlayers()
    local names = playerNameList()
    if targetDD.SetValues then targetDD:SetValues(names)
    elseif targetDD.SetList then targetDD:SetList(names)
    elseif targetDD.Set then targetDD:Set(names) end
end
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
        if selectedMuts["Dino"] then selectedMuts["Jurassic"]=true end
    end
})

Tab:Input({
    Title="จำนวนที่จะ Gift (เว้นว่าง/0 = ทั้งหมด)",
    Value="",
    Callback=function(v) amountStr = tostring(v or "") end
})

local progress = Tab:Paragraph({ Title="สถานะ", Desc="รอคำสั่ง..." })
local function setProgress(txt)
    print("[Gift]", txt)
    if progress.SetDesc then progress:SetDesc(txt)
    elseif progress.Set then progress:Set(txt)
    elseif progress.SetText then progress:SetText(txt)
    end
end

local function fmtLine(egg,i,total) return string.format("%s%s %d/%d", egg.T, egg.M and (" • "..egg.M) or "", i, total) end

local function pickTarget()
    if selectedTargetName == "[Nearest]" or not selectedTargetName or selectedTargetName=="" then
        return nearestOtherPlayer()
    end
    return Players:FindFirstChild(selectedTargetName)
end

local function sendBatch(target, amount)
    local pool = listEggsFiltered(selectedTypes, selectedMuts, nil)
    if #pool==0 then setProgress("❌ ไม่พบไข่ตรงตัวกรอง"); return end
    local want = (amount and amount>0) and math.min(amount,#pool) or #pool
    setProgress(("เตรียมส่ง %d ชิ้น…"):format(want))
    local sent = 0
    for i=1,want do
        local nextOne = listEggsFiltered(selectedTypes, selectedMuts, 1)[1]
        if not nextOne then break end
        if giftOnce(target, nextOne) then
            sent += 1
            setProgress("✅ "..fmtLine(nextOne, sent, want))
        else
            setProgress("⚠️ ส่งไม่สำเร็จ กำลังลองใหม่…")
            task.wait(0.35)
        end
        task.wait(0.12)
    end
    if sent>=want then
        setProgress(("🎉 เสร็จสิ้น %d/%d"):format(sent, want))
    else
        setProgress(("⛔ หยุดก่อนครบ %d/%d"):format(sent, want))
    end
end

Tab:Button({
    Title="🎁 Gift ตอนนี้",
    Callback=function()
        local target = pickTarget()
        if not target then setProgress("❌ ยังไม่พบผู้รับ (ลองกด Refresh Players หรือเลือก [Nearest])"); return end
        local n = tonumber((amountStr or ""):gsub("%s+","")) or 0
        if n < 0 then n = 0 end
        setProgress("เริ่มส่งให้ "..target.Name.."...")
        sendBatch(target, n)
    end
})
