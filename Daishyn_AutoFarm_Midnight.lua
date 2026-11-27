-- Daishyn Auto Farm | standalone
-- Core de Auto Farm preservado do DaishynV8.lua
local env = (type(getgenv)=="function" and getgenv()) or _G
if type(env.DaishynFarmStop)=="function" then pcall(env.DaishynFarmStop) end

            local Players = game:GetService("Players")
            local ReplicatedStorage = game:GetService("ReplicatedStorage")
            local RunService = game:GetService("RunService")
            local Workspace = game:GetService("Workspace")
            local LocalPlayer = Players.LocalPlayer
            local Camera = Workspace.CurrentCamera

            local function getRF(name)
                local ok1, rf = pcall(function()
                    return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                        .knit.Services.BallService.RF[name]
                end)
                if ok1 and rf then return rf end
                local ok2, rf2 = pcall(function()
                    local Index = ReplicatedStorage.Packages._Index
                    for _, folder in Index:GetChildren() do
                        if folder.Name:find("knit") then
                            local knit = folder:FindFirstChild("knit")
                            if knit then
                                local svc = knit:FindFirstChild("Services")
                                    and knit.Services:FindFirstChild("BallService")
                                if svc then
                                    local RF = svc:FindFirstChild("RF")
                                    if RF then return RF:FindFirstChild(name) end
                                end
                            end
                        end
                    end
                    return nil
                end)
                return ok2 and rf2 or nil
            end

            local remoteNames = {"CreateHitbox", "Interact", "Jump", "UpdateTilt"}
            local Remotes = {}
            local remoteLastCheck = 0
            local diagnostics = { status = "Aguardando", errors = 0 }
            local function refreshRemotes(force)
                if not force and os.clock() - remoteLastCheck < 2 then return end
                remoteLastCheck = os.clock()
                for _, name in ipairs(remoteNames) do
                    if not Remotes[name] or not Remotes[name].Parent then
                        Remotes[name] = getRF(name)
                    end
                end
            end
            local function invoke(name, ...)
                local remote = Remotes[name]
                if not remote or not remote.Parent then
                    refreshRemotes(true)
                    remote = Remotes[name]
                end
                if not remote then
                    diagnostics.status = name .. ": remote ausente"
                    return false
                end
                local ok, result = pcall(remote.InvokeServer, remote, ...)
                if not ok then
                    diagnostics.errors += 1
                    diagnostics.status = name .. ": " .. tostring(result):sub(1, 90)
                    Remotes[name] = nil
                    return false
                end
                diagnostics.status = "Acoes enviadas; resposta do servidor nao garante sucesso"
                return true, result
            end
            refreshRemotes(true)

            local AF = {
                tp = true, block = true, spike = true, jump = true,
                interval = 0.05, tpOffset = 3, jumpState = false, running = false,
            }

            -- Entrada automatica: Home/Away, P1 a P6.
            local Join = { enabled = true, active = false, confirmed = false, token = 0,
                delay = 0.45, retryDelay = 3, status = "Aguardando" }
            local positionIds = {4, 3, 2, 1, 6, 5}
            local joinRemote = nil
            local function getJoinRemote()
                if joinRemote and joinRemote.Parent then return joinRemote end
                local ok, remote = pcall(function()
                    return ReplicatedStorage:WaitForChild("Packages", 3)
                        :WaitForChild("_Index", 3)
                        :WaitForChild("sleitnick_knit@1.7.0", 3)
                        :WaitForChild("knit", 3)
                        :WaitForChild("Services", 3)
                        :WaitForChild("GameService", 3)
                        :WaitForChild("RF", 3)
                        :WaitForChild("RequestJoin", 3)
                end)
                if ok and remote then joinRemote = remote end
                return joinRemote
            end
            local function joinedByPlayerState()
                -- So aceita sinais explicitos; uma bola no mapa nao prova entrada.
                
                for _, attr in ipairs({"InMatch", "InGame", "IsPlaying"}) do
                    if LocalPlayer:GetAttribute(attr) == true then return true end
                end
                return false
            end
            local function joinSucceeded(response)
                if joinedByPlayerState() then return true end
                if response == true then return true end
                if type(response) == "table" then
                    return response.Success == true or response.success == true
                        or response.Joined == true or response.joined == true
                end
                return false
            end
            local function stopJoin()
                Join.token += 1
                Join.active = false
            end
            local function startJoin(onSuccess, forceRetry)
                if Join.active or Join.confirmed or not Join.enabled then return end
                Join.active = true
                Join.token += 1
                local mine = Join.token
                task.spawn(function()
                    while Join.enabled and mine == Join.token and not Join.confirmed do
                        if not forceRetry and joinedByPlayerState() then
                            Join.confirmed = true
                            break
                        end
                        local remote = getJoinRemote()
                        if not remote then
                            Join.status = "RequestJoin indisponivel"
                            task.wait(Join.retryDelay)
                        else
                            for teamId = 1, 2 do
                                if Join.confirmed or mine ~= Join.token then break end
                                for _, positionId in ipairs(positionIds) do
                                    if Join.confirmed or mine ~= Join.token then break end
                                    Join.status = (teamId == 1 and "Home" or "Away") .. " / ID " .. positionId
                                    local ok, response = pcall(function()
                                        return remote:InvokeServer(teamId, positionId)
                                    end)
                                    if (ok and (response == true or (type(response) == "table" and (response.Success == true or response.success == true or response.Joined == true or response.joined == true)))) or (not forceRetry and joinedByPlayerState()) then
                                        Join.confirmed = true
                                        break
                                    end
                                    task.wait(Join.delay)
                                end
                            end
                            if not Join.confirmed then
                                Join.status = "Sem vaga confirmada; tentando novamente"
                                task.wait(Join.retryDelay)
                            end
                        end
                    end
                    if mine == Join.token then
                        Join.active = false
                        if Join.confirmed then
                            Join.status = "Entrada confirmada"
                            onSuccess()
                        end
                    end
                end)
            end

            -- Uma varredura periodica; o Heartbeat reutiliza o resultado.
            local cachedBall, cachedId, lastScan = nil, 0, -1
            local function getBall()
                local now = os.clock()
                if now - lastScan < 0.15 then
                    if cachedBall and cachedBall.Parent then return cachedBall, cachedId end
                    return nil, 0
                end
                lastScan = now
                cachedBall, cachedId = nil, 0
                for _, value in ipairs(Workspace:GetDescendants()) do
                    if value.Name:sub(1, 12) == "CLIENT_BALL_" then
                        local part = value:IsA("BasePart") and value or value:FindFirstChildWhichIsA("BasePart", true)
                        if part then
                            local id = value:GetAttribute("ServerId") or part:GetAttribute("ServerId")
                                or value:GetAttribute("Id") or part:GetAttribute("Id")
                                or tonumber(value.Name:sub(13))
                            if id then cachedBall, cachedId = part, id; break end
                        end
                    end
                end
                return cachedBall, cachedId
            end

            local function getHRP()
                local c = LocalPlayer.Character
                return c and c:FindFirstChild("HumanoidRootPart")
            end

            local function getTimestamp()
                local okT, t = pcall(function() return Workspace:GetServerTimeNow() end)
                if okT and typeof(t) == "number" then return t end
                return tick()
            end


            local tpConn, mainThread, generation = nil, nil, 0

            local function startTP()
                if tpConn then tpConn:Disconnect() end
                tpConn = RunService.Heartbeat:Connect(function()
                    if not AF.running or not AF.tp then return end
                    local ball = getBall()
                    local hrp = getHRP()
                    if ball and hrp then
                        local target = ball.Position + Vector3.new(0, ball.Size.Y * 0.5 + AF.tpOffset, 0)
                        pcall(function()
                            hrp.CFrame = CFrame.new(target, target + Camera.CFrame.LookVector)
                            -- Evita acumulo de velocidade vertical entre reposicionamentos.
                            local velocity = hrp.AssemblyLinearVelocity
                            hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
                        end)
                    end
                end)
            end

            local function startLoop()
                if mainThread then return end
                startTP()
                generation += 1
                local mine = generation
                mainThread = task.spawn(function()
                    while AF.running and mine == generation do
                        local waitT = AF.interval or 0.05
                        refreshRemotes(false)
                        local ball, bid = getBall()
                        if not ball or bid == 0 then
                            diagnostics.status = "Bola ou BallId nao identificado"
                        end
                        local hrp = getHRP()
                        local look = Camera and Camera.CFrame.LookVector or Vector3.new(0, 0, -1)
                        local move = hrp and hrp.CFrame.LookVector or Vector3.zero
                        local tilt = Vector3.new(0, 1, 0)
                        local ts = getTimestamp()

                        if AF.block and bid ~= 0 and ball and Remotes.CreateHitbox and Remotes.Interact then
                            local key = "Block" .. math.random(1000000, 9999999)
                            invoke("CreateHitbox", {
                                    BallId = bid, Charge = 1, Key = key,
                                    ClientTimestamp = ts, Move = "Block",
                                })
                            invoke("Interact", {
                                    Charge = 1, Move = "Block", SpecialCharge = 0,
                                    TiltDirection = tilt, BallId = bid, MoveDirection = move,
                                    Key = key, From = "Client", LookVector = look,
                                    Timestamp = ts, ClientCanRunSpecial = false,
                                    CustomClient = {},
                                })
                            if Remotes.UpdateTilt then invoke("UpdateTilt", tilt) end
                        end

                        if AF.spike and not AF.block and bid ~= 0 and ball and Remotes.Interact then
                            local realTilt = Vector3.new(look.X, 1, look.Z)
                            invoke("Interact", {
                                    Charge = 1, Move = "Spike", SpecialCharge = 0,
                                    TiltDirection = realTilt, LookVector = look,
                                    MoveDirection = move, ClientCanRunSpecial = false,
                                    From = "Client", Timestamp = ts, BallId = bid,
                                    CustomClient = {},
                                })
                            if Remotes.UpdateTilt then invoke("UpdateTilt", realTilt) end
                        end

                        if AF.jump and Remotes.Jump then
                            AF.jumpState = not AF.jumpState
                            invoke("Jump", AF.jumpState)
                        end

                        task.wait(waitT)
                    end
                    if mine == generation then mainThread = nil end
                end)
            end


-- Interface Daishyn | Midnight
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local gui = Instance.new("ScreenGui")
gui.Name = "DaishynAutoFarmStandalone"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = game:GetService("CoreGui")
local function make(class, parent, props)
    local o = Instance.new(class)
    for k,v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end
local colors = {
    bg=Color3.fromRGB(17,18,22), panel=Color3.fromRGB(25,26,32),
    line=Color3.fromRGB(43,45,54), white=Color3.fromRGB(241,242,246),
    muted=Color3.fromRGB(145,149,163), accent=Color3.fromRGB(116,111,190),
    off=Color3.fromRGB(52,54,65), dark=Color3.fromRGB(13,14,18)
}
local function corner(parent, n)
    make("UICorner",parent,{CornerRadius=UDim.new(0,n)})
end
local function stroke(parent, color)
    make("UIStroke",parent,{Color=color or colors.line,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border})
end
local function animate(obj, props, duration)
    TweenService:Create(obj,TweenInfo.new(duration or 0.16,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),props):Play()
end
local function label(parent, text, size, font, color, pos, dimensions)
    return make("TextLabel",parent,{Text=text,TextSize=size,Font=font,TextColor3=color,
        Position=pos,Size=dimensions,BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,
        TextTruncate=Enum.TextTruncate.AtEnd})
end
-- A bolha permanece acessivel mesmo com o painel recolhido.
local bubble = make("TextButton",gui,{Name="LogoBubble",Size=UDim2.fromOffset(54,54),
    AnchorPoint=Vector2.new(0,0.5),Position=UDim2.new(0,16,0.5,0),
    BackgroundColor3=colors.dark,BorderSizePixel=0,Text="D",TextColor3=colors.white,
    Font=Enum.Font.GothamBold,TextSize=29,AutoButtonColor=false,ZIndex=10})
make("UICorner",bubble,{CornerRadius=UDim.new(1,0)})
stroke(bubble,colors.accent)
make("UIGradient",bubble,{Color=ColorSequence.new(Color3.fromRGB(255,255,255),Color3.fromRGB(161,165,189)),Rotation=110})
local bubbleDot=make("Frame",bubble,{Size=UDim2.fromOffset(7,7),Position=UDim2.new(1,-11,1,-12),
    BackgroundColor3=colors.accent,BorderSizePixel=0,ZIndex=11})
corner(bubbleDot,5)

local frame = make("Frame",gui,{Name="MainPanel",Size=UDim2.fromOffset(410,468),
    AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),
    BackgroundColor3=colors.bg,BorderSizePixel=0,Active=true,Visible=false})
corner(frame,16)
stroke(frame)
local scale=make("UIScale",frame,{Scale=1})
local header=make("Frame",frame,{Name="Header",Size=UDim2.new(1,0,0,72),BackgroundTransparency=1,Active=true})
local mark=make("TextLabel",header,{Position=UDim2.fromOffset(16,17),Size=UDim2.fromOffset(38,38),
    BackgroundColor3=colors.panel,BorderSizePixel=0,Text="D",TextSize=23,Font=Enum.Font.GothamBold,TextColor3=colors.white})
corner(mark,10)
stroke(mark)
label(header,"DAISHYN",16,Enum.Font.GothamBold,colors.white,UDim2.fromOffset(65,15),UDim2.new(1,-166,0,23))
label(header,"Auto Farm",12,Enum.Font.GothamMedium,colors.muted,UDim2.fromOffset(65,38),UDim2.new(1,-166,0,18))
local function headerButton(text,x)
    local b=make("TextButton",header,{Size=UDim2.fromOffset(32,32),Position=UDim2.new(1,x,0,20),
        BackgroundColor3=colors.panel,BorderSizePixel=0,Text=text,TextSize=19,
        TextColor3=colors.muted,Font=Enum.Font.GothamMedium,AutoButtonColor=false})
    corner(b,8)
    return b
end
local minimize=headerButton("–",-86)
local close=headerButton("×",-46)
local line=make("Frame",frame,{Position=UDim2.fromOffset(16,70),Size=UDim2.new(1,-32,0,1),BackgroundColor3=colors.line,BorderSizePixel=0})
local scroll=make("ScrollingFrame",frame,{Position=UDim2.fromOffset(16,80),Size=UDim2.new(1,-32,1,-96),
    BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=colors.off,
    CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y})
make("UIListLayout",scroll,{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder})
make("UIPadding",scroll,{PaddingBottom=UDim.new(0,6),PaddingRight=UDim.new(0,4)})
local order=0
local function section(title)
    order+=1
    local t=label(scroll,title,10,Enum.Font.GothamBold,colors.muted,UDim2.fromOffset(0,0),UDim2.new(1,0,0,23))
    t.LayoutOrder=order
end
local function row(title,desc,wide)
    order+=1
    local r=make("Frame",scroll,{Size=UDim2.new(1,-4,0,wide and 68 or 53),BackgroundColor3=colors.panel,
        BorderSizePixel=0,LayoutOrder=order})
    corner(r,9)
    local t=label(r,title,13,Enum.Font.GothamMedium,colors.white,UDim2.fromOffset(12,8),UDim2.new(1,wide and -24 or -106,0,18))
    if not wide then
        label(r,desc,10,Enum.Font.Gotham,colors.muted,UDim2.fromOffset(12,28),UDim2.new(1,-106,0,16))
    end
    return r
end
local function toggle(title,desc,callback)
    local r=row(title,desc)
    local on=({["Teleport para bola"]=AF.tp,["Block automático"]=AF.block,["Spike automático"]=AF.spike,["Pular"]=AF.jump,["Iniciar Auto Farm"]=true,["Entrada automatica"]=Join.enabled})[title] or false
    local btn=make("TextButton",r,{Size=UDim2.fromOffset(44,24),Position=UDim2.new(1,-57,.5,-12),
        BackgroundColor3=on and colors.accent or colors.off,BorderSizePixel=0,Text="",AutoButtonColor=false})
    corner(btn,12)
    local knob=make("Frame",btn,{Size=UDim2.fromOffset(16,16),Position=UDim2.fromOffset(on and 24 or 4,4),
        BackgroundColor3=colors.white,BorderSizePixel=0})
    corner(knob,8)
    btn.Activated:Connect(function()
        on=not on
        animate(btn,{BackgroundColor3=on and colors.accent or colors.off})
        animate(knob,{Position=UDim2.fromOffset(on and 24 or 4,4)})
        callback(on)
    end)
    return btn
end
local function number(title,desc,value,min,max,callback)
    local r=row(title,desc)
    local input=make("TextBox",r,{Size=UDim2.fromOffset(68,29),Position=UDim2.new(1,-81,.5,-14),
        BackgroundColor3=colors.dark,BorderSizePixel=0,Text=tostring(value),TextSize=13,
        Font=Enum.Font.GothamMedium,TextColor3=colors.white,ClearTextOnFocus=false})
    corner(input,7)
    stroke(input)
    input.FocusLost:Connect(function()
        local n=tonumber(input.Text)
        if n then value=math.clamp(n,min,max);callback(value) end
        input.Text=tostring(value)
    end)
end
local function showPanel(visible)
    frame.Visible=visible
    animate(bubble,{BackgroundColor3=visible and colors.panel or colors.dark})
end
minimize.Activated:Connect(function() showPanel(false) end)
-- Arrastar a bolha ou o cabecalho; toque simples na bolha abre/recolhe.
local drag, dragMoved, suppressBubbleClick
local uiConnections={}
local function beginDrag(input,target)
    if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch then return end
    drag={input=input,target=target,start=input.Position,position=target.Position}
    dragMoved=false
    if target==bubble then suppressBubbleClick=false end
end
bubble.InputBegan:Connect(function(input) beginDrag(input,bubble) end)
header.InputBegan:Connect(function(input) beginDrag(input,frame) end)
table.insert(uiConnections,UserInputService.InputChanged:Connect(function(input)
    if not drag then return end
    if drag.input.UserInputType==Enum.UserInputType.Touch then
        if input~=drag.input then return end
    elseif input.UserInputType~=Enum.UserInputType.MouseMovement then return end
    local delta=input.Position-drag.start
    if delta.Magnitude>5 then dragMoved=true end
    if not dragMoved then return end
    if drag.target==bubble then suppressBubbleClick=true end
    local view=Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(800,600)
    local p=drag.position
    local x=p.X.Scale*view.X+p.X.Offset+delta.X
    local y=p.Y.Scale*view.Y+p.Y.Offset+delta.Y
    local size=drag.target.AbsoluteSize
    local a=drag.target.AnchorPoint
    x=math.clamp(x,size.X*a.X,math.max(size.X*a.X,view.X-size.X*(1-a.X)))
    y=math.clamp(y,size.Y*a.Y,math.max(size.Y*a.Y,view.Y-size.Y*(1-a.Y)))
    drag.target.Position=UDim2.fromOffset(x,y)
end))
table.insert(uiConnections,UserInputService.InputEnded:Connect(function(input)
    if drag and (input==drag.input or (drag.input.UserInputType==Enum.UserInputType.MouseButton1 and input.UserInputType==Enum.UserInputType.MouseButton1)) then
        drag=nil
    end
end))
bubble.Activated:Connect(function()
    if suppressBubbleClick then suppressBubbleClick=false; return end
    showPanel(not frame.Visible)
end)
local function resizePanel()
    local camera=Workspace.CurrentCamera
    if camera then
        local v=camera.ViewportSize
        scale.Scale=math.min(1,math.max(.25,(v.X-24)/410),math.max(.25,(v.Y-40)/468))
    end
end
resizePanel()
if Workspace.CurrentCamera then
    table.insert(uiConnections,Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(resizePanel))
end
gui.Destroying:Connect(function()
    for _,c in ipairs(uiConnections) do c:Disconnect() end
end)
section("FARM")
toggle("Teleport para bola","Mantém o personagem acima da bola.",function(v) AF.tp=v end)
toggle("Block automático","Executa o bloqueio original.",function(v) AF.block=v end)
toggle("Spike automático","Executa o ataque original.",function(v) AF.spike=v end)
toggle("Pular","Alterna o pulo automaticamente.",function(v) AF.jump=v end)
section("AJUSTES")
number("Intervalo","Tempo entre ações (segundos).",0.05,0.03,0.3,function(v) AF.interval=v end)
number("Offset do TP","Altura acima da bola.",3,1,8,function(v) AF.tpOffset=v end)
local requested = true
local lastConfirmed = os.clock()
local closed = false
local function disableFarm()
    AF.running = false
    generation += 1
    if tpConn then tpConn:Disconnect();tpConn = nil end
    mainThread = nil
end
local function enableFarm()
    lastConfirmed = os.clock()
    AF.running = true
    startLoop()
end
section("PARTIDAS")
local autoJoinButton = toggle("Entrada automatica", "Tenta Home e Away antes do farm.", function(v)
    Join.enabled = v
    if not v then
        stopJoin()
        Join.status = "Entrada automatica desativada"
    elseif AF.running and not Join.confirmed then
        disableFarm()
        startJoin(enableFarm)
    end
end)
local statusRow = row("Status da entrada", "", true)
local statusText = make("TextLabel", statusRow, {
    Size = UDim2.new(1, -24, 0, 34), Position = UDim2.fromOffset(12, 29),
    BackgroundTransparency = 1, Text = "Aguardando", TextWrapped = true,
    TextColor3 = colors.muted, TextSize = 11, Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left
})
local debugRow = row("Diagnóstico das ações", "", true)
local debugText = make("TextLabel", debugRow, {
    Size = UDim2.new(1, -24, 0, 34), Position = UDim2.fromOffset(12, 29),
    BackgroundTransparency = 1, Text = "Aguardando", TextWrapped = true,
    TextColor3 = colors.muted, TextSize = 10, Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left
})
local statusConn = RunService.Heartbeat:Connect(function()
    if debugText.Parent and debugText.Text ~= diagnostics.status then
        debugText.Text = diagnostics.status
    end
    if statusText.Parent and statusText.Text ~= Join.status then
        statusText.Text = Join.status
    end
end)
local farmButton = toggle("Iniciar Auto Farm", "Inicia apos confirmar entrada.", function(v)
    requested = v
    if v then
        if Join.enabled and not Join.confirmed then
            startJoin(enableFarm)
        else
            enableFarm()
        end
    else
        stopJoin()
        disableFarm()
    end
end)
farmButton.Parent.LayoutOrder = -1
local function stop()
    closed = true
    requested = false
    stopJoin()
    if statusConn then statusConn:Disconnect() end
    AF.running=false
    generation += 1
    if tpConn then tpConn:Disconnect();tpConn=nil end
    mainThread=nil
    if gui.Parent then gui:Destroy() end
end
env.DaishynFarmStop=stop
close.MouseButton1Click:Connect(stop)
if Join.enabled then
    startJoin(enableFarm)
else
    enableFarm()
end


-- Watchdog: revalida a entrada periodicamente sem interromper o farm ativo.
task.spawn(function()
    while not closed do
        task.wait(5)
        if not closed and requested and Join.enabled and not Join.active and Join.confirmed and os.clock() - lastConfirmed >= 120 then
            Join.confirmed = false
            Join.status = "Revalidando entrada"
            startJoin(enableFarm, true)
        end
    end
end)
