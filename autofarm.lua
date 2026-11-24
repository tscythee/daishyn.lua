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


local gui = Instance.new("ScreenGui")
gui.Name = "DaishynAutoFarmStandalone"
gui.ResetOnSpawn = false
gui.Parent = game:GetService("CoreGui")
local function make(class, parent, props)
    local o = Instance.new(class)
    for k,v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end
local colors = {bg=Color3.fromRGB(14,14,16),panel=Color3.fromRGB(25,25,28),line=Color3.fromRGB(49,49,53),white=Color3.fromRGB(238,238,239),muted=Color3.fromRGB(155,155,160)}
local frame = make("Frame",gui,{Size=UDim2.fromOffset(440,440),Position=UDim2.new(.5,-220,.5,-220),BackgroundColor3=colors.bg,BorderSizePixel=0,Active=true,Draggable=true})
make("UICorner",frame,{CornerRadius=UDim.new(0,12)})
make("UIStroke",frame,{Color=colors.line,Thickness=1})
make("TextLabel",frame,{Size=UDim2.new(1,-65,0,56),Position=UDim2.fromOffset(20,5),BackgroundTransparency=1,Text="Daishyn Auto Farm",TextSize=21,Font=Enum.Font.GothamBold,TextColor3=colors.white,TextXAlignment=Enum.TextXAlignment.Left})
local close=make("TextButton",frame,{Size=UDim2.fromOffset(32,32),Position=UDim2.new(1,-44,0,16),BackgroundColor3=colors.panel,Text="×",TextSize=22,TextColor3=colors.white,Font=Enum.Font.Gotham})
make("UICorner",close,{CornerRadius=UDim.new(0,8)})
local scroll=make("ScrollingFrame",frame,{Position=UDim2.fromOffset(16,68),Size=UDim2.new(1,-32,1,-84),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y})
make("UIListLayout",scroll,{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder})
local function row(title,desc)
    local r=make("Frame",scroll,{Size=UDim2.new(1,-8,0,59),BackgroundColor3=colors.panel,BorderSizePixel=0})
    make("UICorner",r,{CornerRadius=UDim.new(0,8)})
    make("TextLabel",r,{Position=UDim2.fromOffset(13,8),Size=UDim2.new(1,-120,0,21),BackgroundTransparency=1,Text=title,TextColor3=colors.white,TextSize=14,Font=Enum.Font.GothamMedium,TextXAlignment=Enum.TextXAlignment.Left})
    make("TextLabel",r,{Position=UDim2.fromOffset(13,31),Size=UDim2.new(1,-120,0,17),BackgroundTransparency=1,Text=desc,TextColor3=colors.muted,TextSize=11,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left})
    return r
end
local function toggle(title,desc,callback)
    local r=row(title,desc)
    local on=({["Teleport para bola"]=AF.tp,["Block automático"]=AF.block,["Spike automático"]=AF.spike,["Pular"]=AF.jump,["Iniciar Auto Farm"]=true,["Entrada automatica"]=Join.enabled})[title] or false
    local btn=make("TextButton",r,{Size=UDim2.fromOffset(76,30),Position=UDim2.new(1,-88,.5,-15),BackgroundColor3=on and Color3.fromRGB(70,105,85) or colors.line,Text=on and "ON" or "OFF",TextSize=12,Font=Enum.Font.GothamBold,TextColor3=colors.white})
    make("UICorner",btn,{CornerRadius=UDim.new(0,7)})
    btn.MouseButton1Click:Connect(function()
        on=not on
        btn.Text=on and "ON" or "OFF"
        btn.BackgroundColor3=on and Color3.fromRGB(70,105,85) or colors.line
        callback(on)
    end)
    return btn
end
local function number(title,desc,value,min,max,callback)
    local r=row(title,desc)
    local input=make("TextBox",r,{Size=UDim2.fromOffset(75,30),Position=UDim2.new(1,-88,.5,-15),BackgroundColor3=colors.line,Text=tostring(value),TextSize=13,Font=Enum.Font.Gotham,TextColor3=colors.white,ClearTextOnFocus=false})
    make("UICorner",input,{CornerRadius=UDim.new(0,7)})
    input.FocusLost:Connect(function()
        local n=tonumber(input.Text)
        if n then value=math.clamp(n,min,max);callback(value) end
        input.Text=tostring(value)
    end)
end
toggle("Teleport para bola","Mantém o personagem acima da bola.",function(v) AF.tp=v end)
toggle("Block automático","Executa o bloqueio original.",function(v) AF.block=v end)
toggle("Spike automático","Executa o ataque original.",function(v) AF.spike=v end)
toggle("Pular","Alterna o pulo automaticamente.",function(v) AF.jump=v end)
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
local statusRow = row("Status da entrada", "O estado aparece a direita.")
local statusText = make("TextLabel", statusRow, {
    Size = UDim2.fromOffset(170, 42), Position = UDim2.new(1, -181, 0, 8),
    BackgroundTransparency = 1, Text = "Aguardando", TextWrapped = true,
    TextColor3 = colors.muted, TextSize = 11, Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Right
})
local debugRow = row("Diagnostico das acoes", "Falhas de Block, Spike ou Jump.")
local debugText = make("TextLabel", debugRow, {
    Size = UDim2.fromOffset(190, 46), Position = UDim2.new(1, -201, 0, 6),
    BackgroundTransparency = 1, Text = "Aguardando", TextWrapped = true,
    TextColor3 = colors.muted, TextSize = 10, Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Right
})
local statusConn = RunService.Heartbeat:Connect(function()
    if debugText.Parent and debugText.Text ~= diagnostics.status then
        debugText.Text = diagnostics.status
    end
    if statusText.Parent and statusText.Text ~= Join.status then
        statusText.Text = Join.status
    end
end)
toggle("Iniciar Auto Farm", "Inicia apos confirmar entrada.", function(v)
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
