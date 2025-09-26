if not game:IsLoaded() then game.Loaded:Wait() end
local WSConnect=(syn and syn.websocket and syn.websocket.connect) or (Krnl and (function() repeat task.wait() until Krnl.WebSocket and Krnl.WebSocket.connect return Krnl.WebSocket.connect end)()) or (WebSocket and WebSocket.connect)
if not WSConnect then return end
local HttpService=game:GetService("HttpService")
local Players=game:GetService("Players")
local MarketplaceService=game:GetService("MarketplaceService")
local LocalPlayer=Players.LocalPlayer
while not LocalPlayer do LocalPlayer=Players.LocalPlayer task.wait() end
local function toNum(s) if typeof(s)=="number" then return s end if typeof(s)=="string" then s=s:gsub("[%$,]",""); return tonumber(s) end end
local CANDS={"Money","Cash","Coins","Gold","Gems"}
local function readMoney()
  local ls=LocalPlayer:FindFirstChild("leaderstats")
  if ls then
    for _,n in ipairs(CANDS) do local v=ls:FindFirstChild(n); if v and typeof(v.Value)=="number" then return tonumber(v.Value) end end
    local only; for _,ch in ipairs(ls:GetChildren()) do if ch:IsA("ValueBase") and typeof(ch.Value)=="number" then if only then only=nil; break else only=ch end end end
    if only then return tonumber(only.Value) end
  end
  if LocalPlayer:GetAttribute("Money") then return toNum(LocalPlayer:GetAttribute("Money")) end
  local c=LocalPlayer.Character; if c and c:GetAttribute("Money") then return toNum(c:GetAttribute("Money")) end
  local pg=LocalPlayer:FindFirstChild("PlayerGui"); if pg then
    local found
    local function scan(o,d) if found then return end d=d or 0; if d>4 then return end
      for _,x in ipairs(o:GetChildren()) do
        if x:IsA("TextLabel") or x:IsA("TextButton") then local n=toNum(x.Text); if n and n>=0 then found=n; return end end
        scan(x,d+1)
      end
    end
    scan(pg,0); if found then return found end
  end
  return nil
end
local function buildRoster()
  local t={}; for _,p in ipairs(Players:GetPlayers()) do table.insert(t,{id=(p.UserId~=0 and p.UserId or nil),name=p.Name}) end; return t
end
local function placeName()
  local ok,info=pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
  if ok and info and info.Name then return info.Name end
  return "Place "..tostring(game.PlaceId)
end
local function makeUrl(host,path)
  local proto=string.char(119,115,58,47,47)
  local room=(placeName().." • "..string.sub(game.JobId,1,8))
  local q=("name=%s&id=%s&jobId=%s&roomName=%s"):format(
    HttpService:UrlEncode(LocalPlayer.Name),
    HttpService:UrlEncode(LocalPlayer.UserId),
    HttpService:UrlEncode(game.JobId),
    HttpService:UrlEncode(room)
  )
  return ("%s%s%s?%s"):format(proto,host,path,q)
end
local Nexus={Host="localhost:3005",Path="/Nexus",IsConnected=false,Socket=nil}
function Nexus:Send(Name,Payload)
  if not(self.Socket and self.IsConnected) then return end
  local ok,msg=pcall(function() return HttpService:JSONEncode({Name=Name,Payload=Payload}) end)
  if ok and msg then pcall(function() self.Socket:Send(msg) end) end
end
function Nexus:Connect(host)
  if host then self.Host=host end
  if self.Socket then pcall(function() self.Socket:Close() end) end
  self.IsConnected=false
  while true do
    local ok,sock=pcall(WSConnect, makeUrl(self.Host,self.Path))
    if not ok or not sock then task.wait(5)
    else
      self.Socket=sock; self.IsConnected=true
      if sock.OnClose then sock.OnClose:Connect(function() self.IsConnected=false end) end
      if sock.OnMessage then sock.OnMessage:Connect(function(_) end) end
      self:Send("SetPlaceId",{Content=tostring(game.PlaceId)})
      self:Send("SetJobId",{Content=tostring(game.JobId)})
      local lastM=nil; local tick=0
      while self.IsConnected do
        self:Send("ping",{t=os.time()})
        local m=readMoney(); if m and m~=lastM then lastM=m; self:Send("SetMoney",{Content=tostring(m)}) end
        tick=tick+1; if tick>=2 then tick=0; self:Send("SetRoster",{List=buildRoster(),JobId=tostring(game.JobId)}) end
        task.wait(1)
      end
    end
  end
end
function Nexus:Stop() self.IsConnected=false; if self.Socket then pcall(function() self.Socket:Close() end) end end
Players.PlayerAdded:Connect(function() end)
Players.PlayerRemoving:Connect(function() end)
LocalPlayer.OnTeleport:Connect(function(s) if s==Enum.TeleportState.Started then Nexus:Stop() end end)
getgenv().Nexus=Nexus
Nexus:Connect("localhost:3005")
