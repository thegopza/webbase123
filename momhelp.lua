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
