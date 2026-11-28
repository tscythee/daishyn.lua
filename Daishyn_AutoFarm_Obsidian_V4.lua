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



-- Discord: opt-in, somente dados publicos da propria conta.
local HttpService = game:GetService("HttpService")
local Discord = {
    enabled = false, url = "", sent = false, busy = false,
    startedAt = os.clock(), level = nil, style = nil, source = nil, below = false,
    status = "Desativado", avatar = nil, rejoinEnabled = false,
    elapsedBase = 0, lastLevel = nil, lastLevelAt = nil, lastJob = "",
    pendingRejoin = nil, rejoins = 0, color = 0xFFFFFF
}
local configPath = "Daishyn_AutoFarm_Discord_" .. tostring(LocalPlayer.UserId) .. ".json"
local function validWebhook(url)
    return type(url) == "string" and #url <= 300
        and url:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+$") ~= nil
end
local function loadDiscord()
    if type(readfile) ~= "function" then return end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(configPath))
    end)
    if ok and type(data) == "table" then
        Discord.url = validWebhook(data.url) and data.url or ""
        Discord.enabled = data.enabled == true and Discord.url ~= ""
        Discord.sent = data.sent == true
        Discord.rejoinEnabled = data.rejoinEnabled == true
        Discord.elapsedBase = math.max(0, math.min(tonumber(data.elapsed) or 0, 31536000))
        local n = tonumber(data.lastLevel)
        if n and n >= 0 and n < 1000000 and n == math.floor(n) then Discord.lastLevel = n end
        Discord.lastLevelAt = tonumber(data.lastLevelAt)
        Discord.lastJob = type(data.lastJob) == "string" and data.lastJob or ""
        Discord.rejoins = math.max(0, math.floor(tonumber(data.rejoins) or 0))
        Discord.color = data.color == 0 and 0 or 0xFFFFFF
        if type(data.pendingRejoin) == "table" and type(data.pendingRejoin.job) == "string" and type(data.pendingRejoin.at) == "number" then
            Discord.pendingRejoin = data.pendingRejoin
        end
    end
end
local function elapsedTotal()
    return Discord.elapsedBase + math.max(0, os.clock() - Discord.startedAt)
end
local function saveDiscord()
    if type(writefile) ~= "function" then return false end
    return pcall(function()
        writefile(configPath, HttpService:JSONEncode({
            enabled = Discord.enabled, url = Discord.url, sent = Discord.sent,
            rejoinEnabled = Discord.rejoinEnabled, elapsed = math.floor(elapsedTotal()),
            lastLevel = Discord.lastLevel, lastLevelAt = Discord.lastLevelAt,
            lastJob = Discord.lastJob, pendingRejoin = Discord.pendingRejoin,
            rejoins = Discord.rejoins, color = Discord.color
        }))
    end)
end
loadDiscord()
-- JobId diferente confirma entrada em outro servidor, nao apenas nova execucao da GUI.
local currentJob = tostring(game.JobId or "")
if currentJob ~= "" then
    if Discord.lastJob ~= "" and Discord.lastJob ~= currentJob then
        Discord.rejoins = Discord.rejoins + 1
        if Discord.enabled and Discord.rejoinEnabled and validWebhook(Discord.url) then
            Discord.pendingRejoin = {job=currentJob, at=os.time(), previousLevel=Discord.lastLevel, count=Discord.rejoins}
        else
            Discord.pendingRejoin = nil
        end
    end
    Discord.lastJob = currentJob
end
saveDiscord()

-- Aceita RichText e o formato observado: Lvl 1 - Hinto.
local function parseLevel(text)
    local clean = tostring(text or ""):gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub(" ", " ")
    clean = clean:gsub("–", "-"):gsub("—", "-")
    local lower = clean:lower()
    local n, last = lower:match("^%s*lvl%.?%s*:?%s*(%d+)%s*%-%s*()")
    if not n then
        n, last = lower:match("^%s*level%s*:?%s*(%d+)%s*%-%s*()")
    end
    if n then
        local style = clean:sub(last):match("^%s*(.-)%s*$")
        if style ~= "" and #style <= 100 and not style:find("[\r\n]") then
            return tonumber(n), style
        end
    end
    n = lower:match("^%s*lvl%.?%s*:?%s*(%d+)%s*$")
        or lower:match("^%s*level%s*:?%s*(%d+)%s*$")
        or lower:match("^%s*nivel%s*:?%s*(%d+)%s*$")
    return tonumber(n)
end
local function validLevel(v)
    return type(v) == "number" and v >= 0 and v < 1000000 and v == math.floor(v)
end
local function ownBillboard(billboard, character)
    if not billboard:IsA("BillboardGui")  then return false end
    local adornee = billboard.Adornee
    if adornee then return adornee == character or adornee:IsDescendantOf(character) end
    return billboard:IsDescendantOf(character)
end
local function readOwnTag()
    local character = LocalPlayer.Character
    if not character then return nil end
    local foundLevel, foundStyle, levelConflict, styleConflict
    local function scan(root)
        if not root then return end
        for _, billboard in ipairs(root:GetDescendants()) do
            if ownBillboard(billboard, character) then
                for _, item in ipairs(billboard:GetDescendants()) do
                    if item:IsA("TextLabel") or item:IsA("TextButton") then
                        local n, style = parseLevel(item.Text)
                        if validLevel(n) then
                            if foundLevel and foundLevel ~= n then levelConflict = true end
                            foundLevel = n
                            if style then
                                if foundStyle and foundStyle ~= style then styleConflict = true end
                                foundStyle = style
                            end
                        end
                    end
                end
            end
        end
    end
    scan(character)
    scan(LocalPlayer:FindFirstChild("PlayerGui"))
    scan(workspace)
    return not levelConflict and foundLevel or nil, not styleConflict and foundStyle or nil
end
local function readOwnData()
    local n, source, style
    local styleKeys = {"EquippedStyle", "CurrentStyle", "SelectedStyle", "Style"}
    local levelKeys = {"Level", "LVL", "Lvl", "Nivel"}
    local function read(root, label, allowValues)
        if not root then return end
        for _, name in ipairs(levelKeys) do
            local v = root:GetAttribute(name)
            if not validLevel(v) and allowValues then
                local item = root:FindFirstChild(name)
                if item and (item:IsA("IntValue") or item:IsA("NumberValue")) then v = item.Value end
            end
            if validLevel(v) and not n then n, source = v, label end
        end
        for _, name in ipairs(styleKeys) do
            local v = root:GetAttribute(name)
            if type(v) ~= "string" and allowValues then
                local item = root:FindFirstChild(name)
                if item and item:IsA("StringValue") then v = item.Value end
            end
            if type(v) == "string" and #v > 0 and #v <= 100 and not style then style = v end
        end
    end
    read(LocalPlayer,"Dados da conta",true)
    read(LocalPlayer:FindFirstChild("leaderstats"),"leaderstats",true)
    for _, folder in ipairs({"Data", "PlayerData", "Stats"}) do
        read(LocalPlayer:FindFirstChild(folder),"Dados locais / "..folder,true)
    end
    read(LocalPlayer.Character,"Atributos do avatar",false)
    return n, style, source
end
local function getPlayerLevel()
    local dataLevel, dataStyle, dataSource = readOwnData()
    local tagLevel, tagStyle = readOwnTag()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local candidate, candidateStyle, conflict, styleConflict
    if gui then
        for _, d in ipairs(gui:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Visible and not d:FindFirstAncestorWhichIsA("BillboardGui") then
                local path = d:GetFullName():lower()
                if not (path:find("leaderboard",1,true) or path:find("scoreboard",1,true) or path:find("friends",1,true) or path:find("playerlist",1,true) or path:find("daishyn",1,true)) then
                    local n, style = parseLevel(d.Text)
                    if validLevel(n) then
                        if candidate and candidate ~= n then conflict = true end
                        candidate = n
                        if style then
                            if candidateStyle and candidateStyle ~= style then styleConflict = true end
                            candidateStyle = style
                        end
                    end
                end
            end
        end
    end
    local style = dataStyle or tagStyle or (not styleConflict and candidateStyle or nil)
    if validLevel(dataLevel) then return dataLevel, style, dataSource end
    if validLevel(tagLevel) then return tagLevel, style, "Identificação do avatar" end
    if not conflict and validLevel(candidate) then return candidate, style, "HUD local" end
    return nil, style
end
local function discordRequest(options)
    local fn = (type(request) == "function" and request)
        or (type(http_request) == "function" and http_request)
        or (type(syn) == "table" and type(syn.request) == "function" and syn.request)
    if not fn then return nil, "HTTP indisponível" end
    local ok, response = pcall(fn, options)
    if not ok or type(response) ~= "table" then return nil, "Falha HTTP" end
    local code = tonumber(response.StatusCode or response.Status or response.status_code)
    if not code or code < 200 or code >= 300 then
        return nil, code and ("HTTP " .. tostring(code)) or "Sem confirmação HTTP"
    end
    return response
end
local function getAvatar()
    if Discord.avatar then return Discord.avatar end
    local response = discordRequest({
        Url = "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds="
            .. tostring(LocalPlayer.UserId) .. "&size=150x150&format=Png&isCircular=false",
        Method = "GET"
    })
    if not response then return nil end
    local ok, data = pcall(function() return HttpService:JSONDecode(response.Body or response.body or "") end)
    local item = ok and type(data) == "table" and type(data.data) == "table" and data.data[1]
    local url = type(item) == "table" and item.state == "Completed" and item.imageUrl
    if type(url) == "string" and url:match("^https://[%w%-]+%.rbxcdn%.com/") then
        Discord.avatar = url
        return url
    end
    return nil
end
local function duration(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%02dh %02dm %02ds",math.floor(seconds/3600),math.floor(seconds/60)%60,seconds%60)
end
local function sendDiscord(url, test, level, at, elapsed, isClosed, style, rejoin)
    if not validWebhook(url) then return false,"URL inválida" end
    local embed = {
        title = test and "Conexão sincronizada" or (rejoin and "Rejoin realizado" or "Nível 15 alcançado!"),
        description = test and "Canal conectado ao Daishyn Auto Farm. Confira os dados atuais abaixo." or (rejoin and "Uma nova sessão de servidor foi identificada. O acompanhamento da conta continua." or "Objetivo de nível concluído."),
        color = Discord.color,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ",at),
        footer = {text = "DAISHYN / AUTO FARM"}
    }
    do
        embed.fields = {
            {name="Nick da conta",value=LocalPlayer.Name,inline=true},
            {name="Nível atual",value=level and tostring(level) or "Aguardando sincronização",inline=true},
            {name="Estilo equipado",value=style or "Não detectado",inline=true},
            {name="Tempo acumulado",value=duration(elapsed),inline=true},
            {name="Horário",value="<t:"..tostring(at)..":F>",inline=false}
        }
        if rejoin then
            table.insert(embed.fields,{name="Nível anterior salvo",value=rejoin.previousLevel and tostring(rejoin.previousLevel) or "Não detectado",inline=true})
            table.insert(embed.fields,{name="Reconexões detectadas",value=tostring(rejoin.count or 1),inline=true})
        end
        if test or rejoin then
            table.insert(embed.fields,{name="Status da conta",value=AF.running and "Farm ativo" or (Join.active and "Entrando na partida" or "Pausado"),inline=true})
            table.insert(embed.fields,{name="Leitura do nível",value=level and (Discord.source or "Leitura atual") or "Aguardando atualização do jogo",inline=true})
            if test then
                table.insert(embed.fields,{name="Notificações",value=Discord.enabled and "Ativadas" or "Desativadas",inline=true})
                table.insert(embed.fields,{name="Avisos de reconexão",value=Discord.rejoinEnabled and "Ativados" or "Desativados",inline=true})
                table.insert(embed.fields,{name="Objetivo",value=level and level >= 15 and "Nível 15 confirmado" or "Acompanhando progresso",inline=true})
            end
        end
        local avatar = getAvatar()
        if avatar then embed.thumbnail = {url=avatar} end
    end
    if isClosed() or Discord.url ~= url or (not test and not Discord.enabled) or (rejoin and not Discord.rejoinEnabled) then
        return false,"Envio cancelado"
    end
    local response, err = discordRequest({
        Url=url.."?wait=true", Method="POST",
        Headers={["Content-Type"]="application/json"},
        Body=HttpService:JSONEncode({
            username="Daishyn Logs", embeds={embed}, allowed_mentions={parse={}}
        })
    })
    return response ~= nil, err
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
    bg=Color3.fromRGB(15,16,20), panel=Color3.fromRGB(23,25,31),
    line=Color3.fromRGB(43,45,54), white=Color3.fromRGB(241,242,246),
    muted=Color3.fromRGB(145,149,163), accent=Color3.fromRGB(116,111,190),
    off=Color3.fromRGB(45,48,58), dark=Color3.fromRGB(12,13,17),
    green=Color3.fromRGB(104,188,151)
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

local frame = make("Frame",gui,{Name="MainPanel",Size=UDim2.fromOffset(460,550),
    AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),
    BackgroundColor3=colors.bg,BorderSizePixel=0,Active=true,Visible=true})
corner(frame,16)
stroke(frame)
local scale=make("UIScale",frame,{Scale=1})
local header=make("Frame",frame,{Name="Header",Size=UDim2.new(1,0,0,72),BackgroundTransparency=1,Active=true})
local mark=make("TextLabel",header,{Position=UDim2.fromOffset(16,17),Size=UDim2.fromOffset(38,38),
    BackgroundColor3=colors.panel,BorderSizePixel=0,Text="D",TextSize=23,Font=Enum.Font.GothamBold,TextColor3=colors.white})
corner(mark,10)
stroke(mark)
label(header,"DAISHYN",16,Enum.Font.GothamBold,colors.white,UDim2.fromOffset(65,15),UDim2.new(1,-166,0,23))
label(header,"Auto Farm / Obsidian",12,Enum.Font.GothamMedium,colors.muted,UDim2.fromOffset(65,38),UDim2.new(1,-166,0,18))
local function headerButton(text,x)
    local b=make("TextButton",header,{Size=UDim2.fromOffset(32,32),Position=UDim2.new(1,x,0,20),
        BackgroundColor3=colors.panel,BorderSizePixel=0,Text=text,TextSize=19,
        TextColor3=colors.muted,Font=Enum.Font.GothamMedium,AutoButtonColor=false})
    corner(b,8)
    b.MouseEnter:Connect(function() animate(b,{BackgroundColor3=colors.off,TextColor3=colors.white}) end)
    b.MouseLeave:Connect(function() animate(b,{BackgroundColor3=colors.panel,TextColor3=colors.muted}) end)
    return b
end
local minimize=headerButton("–",-86)
local close=headerButton("×",-46)
local line=make("Frame",frame,{Position=UDim2.fromOffset(16,70),Size=UDim2.new(1,-32,0,1),BackgroundColor3=colors.line,BorderSizePixel=0})
-- Perfil e progresso permanecem visíveis em todas as abas.
local overview=make("Frame",frame,{Position=UDim2.fromOffset(16,82),Size=UDim2.new(1,-32,0,104),BackgroundColor3=colors.panel,BorderSizePixel=0})
corner(overview,12); stroke(overview)
local avatar=make("ImageLabel",overview,{Position=UDim2.fromOffset(12,12),Size=UDim2.fromOffset(43,43),BackgroundColor3=colors.dark,BorderSizePixel=0,Image="rbxthumb://type=AvatarHeadShot&id="..LocalPlayer.UserId.."&w=150&h=150"})
corner(avatar,9)
label(overview,LocalPlayer.Name,14,Enum.Font.GothamBold,colors.white,UDim2.fromOffset(66,12),UDim2.new(1,-200,0,20))
local styleLabel=label(overview,"Estilo: aguardando",12,Enum.Font.Gotham,colors.muted,UDim2.fromOffset(66,34),UDim2.new(1,-180,0,20))
local levelLabel=label(overview,"LVL — / 15",15,Enum.Font.GothamBold,colors.white,UDim2.new(1,-123,0,13),UDim2.fromOffset(111,22))
levelLabel.TextXAlignment=Enum.TextXAlignment.Right
local timeLabel=label(overview,"00h 00m 00s",11,Enum.Font.GothamMedium,colors.muted,UDim2.new(1,-123,0,34),UDim2.fromOffset(111,20))
timeLabel.TextXAlignment=Enum.TextXAlignment.Right
local track=make("Frame",overview,{Position=UDim2.fromOffset(12,66),Size=UDim2.new(1,-24,0,5),BackgroundColor3=colors.off,BorderSizePixel=0,ClipsDescendants=true})
corner(track,3)
local fill=make("Frame",track,{Size=UDim2.fromScale(0,1),BackgroundColor3=colors.accent,BorderSizePixel=0});corner(fill,3)
local sourceLabel=label(overview,"Aguardando leitura do nível",10,Enum.Font.Gotham,colors.muted,UDim2.fromOffset(12,79),UDim2.new(1,-24,0,16))
local tabBar=make("Frame",frame,{Position=UDim2.fromOffset(16,198),Size=UDim2.new(1,-32,0,34),BackgroundTransparency=1})
local pages, tabButtons = {}, {}
local scroll
local function selectTab(name)
    for key,page in pairs(pages) do
        page.Visible=key==name
        tabButtons[key].BackgroundColor3=key==name and colors.panel or colors.bg
        tabButtons[key].TextColor3=key==name and colors.white or colors.muted
    end
end
for i,name in ipairs({"Farm","Ajustes","Discord"}) do
    local button=make("TextButton",tabBar,{Position=UDim2.new((i-1)/3,0,0,0),Size=UDim2.new(1/3,-4,1,0),BackgroundColor3=colors.bg,BorderSizePixel=0,Text=name,Font=Enum.Font.GothamMedium,TextSize=13,TextColor3=colors.muted,AutoButtonColor=false})
    corner(button,8); tabButtons[name]=button
    button.MouseEnter:Connect(function() if not pages[name].Visible then animate(button,{BackgroundColor3=colors.off}) end end)
    button.MouseLeave:Connect(function() if not pages[name].Visible then animate(button,{BackgroundColor3=colors.bg}) end end)
    local page=make("ScrollingFrame",frame,{Position=UDim2.fromOffset(16,243),Size=UDim2.new(1,-32,1,-282),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=colors.off,CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,Visible=false})
    make("UIListLayout",page,{Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder})
    make("UIPadding",page,{PaddingBottom=UDim.new(0,6),PaddingRight=UDim.new(0,4)})
    pages[name]=page
    button.Activated:Connect(function() selectTab(name) end)
end
scroll=pages.Farm; selectTab("Farm")
local footer=label(frame,"DAISHYN  /  AUTO FARM",10,Enum.Font.GothamMedium,colors.muted,UDim2.new(0,16,1,-30),UDim2.new(1,-150,0,18))
local farmState=label(frame,"Aguardando",11,Enum.Font.GothamMedium,colors.muted,UDim2.new(1,-145,1,-30),UDim2.fromOffset(129,18))
farmState.TextXAlignment=Enum.TextXAlignment.Right
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
    stroke(r)
    local t=label(r,title,13,Enum.Font.GothamMedium,colors.white,UDim2.fromOffset(12,8),UDim2.new(1,wide and -24 or -106,0,18))
    if not wide then
        label(r,desc,10,Enum.Font.Gotham,colors.muted,UDim2.fromOffset(12,28),UDim2.new(1,-106,0,16))
    end
    return r
end
local function toggle(title,desc,callback,initial)
    local r=row(title,desc)
    local on=({["Teleport para bola"]=AF.tp,["Block automático"]=AF.block,["Spike automático"]=AF.spike,["Pular"]=AF.jump,["Iniciar Auto Farm"]=true,["Entrada automatica"]=Join.enabled})[title] or false
    if initial ~= nil then on = initial == true end
    local btn=make("TextButton",r,{Size=UDim2.fromOffset(44,24),Position=UDim2.new(1,-57,.5,-12),
        BackgroundColor3=on and colors.accent or colors.off,BorderSizePixel=0,Text="",AutoButtonColor=false})
    corner(btn,12)
    local knob=make("Frame",btn,{Size=UDim2.fromOffset(16,16),Position=UDim2.fromOffset(on and 24 or 4,4),
        BackgroundColor3=colors.white,BorderSizePixel=0})
    corner(knob,8)
    btn.MouseEnter:Connect(function() animate(knob,{BackgroundColor3=Color3.fromRGB(215,218,230)}) end)
    btn.MouseLeave:Connect(function() animate(knob,{BackgroundColor3=colors.white}) end)
    local function flip()
        on=not on
        animate(btn,{BackgroundColor3=on and colors.accent or colors.off})
        animate(knob,{Position=UDim2.fromOffset(on and 24 or 4,4)})
        callback(on)
    end
    btn.Activated:Connect(flip)
    local hit=make("TextButton",r,{Size=UDim2.new(1,-70,1,0),BackgroundTransparency=1,Text="",AutoButtonColor=false,ZIndex=3})
    hit.Activated:Connect(flip)
    btn:GetAttributeChangedSignal("ForceOff"):Connect(function()
        if btn:GetAttribute("ForceOff") then
            on=false
            animate(btn,{BackgroundColor3=colors.off})
            animate(knob,{Position=UDim2.fromOffset(4,4)})
            btn:SetAttribute("ForceOff",false)
        end
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
        scale.Scale=math.min(1,math.max(.25,(v.X-24)/460),math.max(.25,(v.Y-40)/550))
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
scroll=pages.Ajustes
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
scroll=pages.Farm
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
local lastStatusUpdate=0
local statusConn = RunService.Heartbeat:Connect(function()
    if os.clock()-lastStatusUpdate<.25 then return end
    lastStatusUpdate=os.clock()
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

scroll=pages.Discord
section("DISCORD")
local discordEnabledButton = toggle("Notificações Discord","Envia o objetivo de nível 15.",function(v)
    Discord.enabled = v
    if not v then Discord.pendingRejoin = nil end
    Discord.status = v and (validWebhook(Discord.url) and "Monitorando nível" or "Configure uma URL") or "Desativado"
    if not saveDiscord() then Discord.status = Discord.status .. " / apenas sessão" end
end, Discord.enabled)
local rejoinButton = toggle("Avisar reconexões","Notifica entrada em outro servidor.",function(v)
    Discord.rejoinEnabled = v
    if not v then Discord.pendingRejoin = nil end
    saveDiscord()
end,Discord.rejoinEnabled)
toggle("Embed branco","Desative para usar a cor preta.",function(v)
    Discord.color = v and 0xFFFFFF or 0
    saveDiscord()
end,Discord.color == 0xFFFFFF)
local webhookRow = row("Webhook privada", "", true)
webhookRow.Size = UDim2.new(1,-4,0,72)
local webhookInput = make("TextBox",webhookRow,{
    Position=UDim2.fromOffset(12,31),Size=UDim2.new(1,-24,0,30),
    BackgroundColor3=colors.dark,BorderSizePixel=0,Text="",
    PlaceholderText=Discord.url ~= "" and "URL salva • cole para substituir" or "Cole a URL da sua webhook",
    TextColor3=colors.white,PlaceholderColor3=colors.muted,TextSize=11,
    Font=Enum.Font.Gotham,ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left
})
corner(webhookInput,7)
stroke(webhookInput)
webhookInput.FocusLost:Connect(function()
    local url = webhookInput.Text:match("^%s*(.-)%s*$")
    webhookInput.Text = ""
    if url == "" then return end
    if not validWebhook(url) then Discord.status = "URL inválida"; return end
    if Discord.url ~= url then Discord.pendingRejoin = nil end
    Discord.url = url
    webhookInput.PlaceholderText = "URL salva • cole para substituir"
    Discord.status = saveDiscord() and "Webhook salva" or "Webhook salva apenas nesta sessão"
end)
local function discordButton(text, callback)
    local r = row("","",true)
    r.Size = UDim2.new(1,-4,0,44)
    local b = make("TextButton",r,{
        Size=UDim2.new(1,0,1,0), BackgroundColor3=colors.panel,Text=text,
        Font=Enum.Font.GothamMedium,TextSize=13,TextColor3=colors.white,
        BorderSizePixel=0,AutoButtonColor=false
    })
    corner(b,9)
    b.MouseEnter:Connect(function() animate(b,{BackgroundColor3=colors.off}) end)
    b.MouseLeave:Connect(function() animate(b,{BackgroundColor3=colors.panel}) end)
    b.Activated:Connect(function() callback(b) end)
    return b
end
discordButton("Testar conexão",function(button)
    if Discord.busy then return end
    if not validWebhook(Discord.url) then Discord.status="Configure uma URL";return end
    Discord.busy=true
    Discord.status="Testando..."
    button.Text="Sincronizando..."
    local url=Discord.url
    task.spawn(function()
        local ok, result, err = pcall(sendDiscord,url,true,Discord.source and Discord.level or nil,os.time(),elapsedTotal(),function() return closed end,Discord.style)
        Discord.busy=false
        Discord.status=ok and result and "Conexão sincronizada" or (ok and (err or "Falha no teste") or "Falha no teste")
        if button.Parent then
            button.Text=ok and result and "Sincronizado" or "Falha • tentar novamente"
            button.TextColor3=ok and result and colors.green or colors.white
            task.delay(3,function() if button.Parent and not Discord.busy then button.Text="Testar conexão";button.TextColor3=colors.white end end)
        end
    end)
end)
discordButton("Remover webhook",function()
    Discord.url=""
    Discord.enabled=false
    Discord.pendingRejoin=nil
    Discord.status=saveDiscord() and "Webhook removida" or "Webhook removida nesta sessão"
    webhookInput.Text=""
    webhookInput.PlaceholderText="Cole a URL da sua webhook"
    -- Atualiza o estado visual do switch sem disparar outra ação.
    if discordEnabledButton then
        discordEnabledButton:SetAttribute("ForceOff",true)
    end
end)
local discordRow=row("Status do Discord","",true)
local discordText=make("TextLabel",discordRow,{
    Size=UDim2.new(1,-24,0,34), Position=UDim2.fromOffset(12,29),
    BackgroundTransparency=1,Text="Aguardando nível",TextWrapped=true,
    TextColor3=colors.muted,TextSize=11,Font=Enum.Font.Gotham,
    TextXAlignment=Enum.TextXAlignment.Left
})
if Discord.enabled then
    Discord.status = Discord.sent and "Objetivo já notificado" or "Monitorando nível"
end
-- Mantem o ultimo nivel salvo como historico, nunca como prova de conquista nova.
local nextAttempt = 0
local nextCheckpoint = 0
local firstRead = os.clock()
local function dispatch(rejoin, level, style)
    Discord.busy = true
    Discord.status = rejoin and "Enviando reconexão..." or "Enviando objetivo..."
    local url, at, elapsed = Discord.url, rejoin and rejoin.at or os.time(), elapsedTotal()
    nextAttempt = os.clock() + 30
    task.spawn(function()
        local safe, result, err = pcall(sendDiscord,url,false,level,at,elapsed,function() return closed end,style,rejoin)
        Discord.busy = false
        if safe and result then
            if rejoin then
                if Discord.pendingRejoin == rejoin then Discord.pendingRejoin = nil end
            else
                Discord.sent = true
            end
            local saved = saveDiscord()
            Discord.status = (rejoin and "Reconexão notificada" or "Nível 15 notificado") .. (saved and "" or " / apenas sessão")
        else
            Discord.status = safe and (err or "Falha no envio") or "Falha no envio"
        end
    end)
end
task.spawn(function()
    while not closed and gui.Parent do
        local ok, level, style, source = pcall(getPlayerLevel)
        local live = ok and validLevel(level)
        if ok then Discord.style = style end
        if live then
            Discord.level, Discord.source = level, source
            if Discord.lastLevel ~= level or not Discord.lastLevelAt then
                Discord.lastLevel, Discord.lastLevelAt = level, os.time()
                saveDiscord()
            end
        else
            Discord.level, Discord.source = Discord.lastLevel, nil
        end
        if Discord.enabled and validWebhook(Discord.url) and not Discord.busy and os.clock() >= nextAttempt then
            if live and level >= 15 and not Discord.sent then
                dispatch(nil,level,Discord.style)
            elseif Discord.pendingRejoin and Discord.rejoinEnabled and (live or os.clock()-firstRead >= 20) then
                dispatch(Discord.pendingRejoin,live and level or nil,Discord.style)
            end
        end
        if os.clock() >= nextCheckpoint then
            nextCheckpoint = os.clock() + 10
            saveDiscord()
        end
        if discordText.Parent then
            discordText.Text="Nível: "..(Discord.level and tostring(Discord.level) or "não detectado").." • "..Discord.status
            levelLabel.Text=Discord.level and ("LVL "..Discord.level.." / 15") or "LVL — / 15"
            styleLabel.Text="Estilo: "..(Discord.style or "não detectado")
            local stamp = Discord.lastLevelAt and os.date("%H:%M:%S",Discord.lastLevelAt) or "—"
            sourceLabel.Text=live and (source.." • alteração às "..stamp) or (Discord.level and ("Último nível salvo • "..stamp) or "Aguardando sincronização")
            fill.BackgroundColor3=Discord.level and Discord.level>=15 and colors.green or colors.accent
            animate(fill,{Size=UDim2.fromScale(math.clamp((Discord.level or 0)/15,0,1),1)},.2)
        end
        task.wait(2)
    end
end)

task.spawn(function()
    while not closed and gui.Parent do
        timeLabel.Text=duration(elapsedTotal())
        farmState.Text=AF.running and "Farm ativo" or (Join.active and "Entrando..." or "Pausado")
        farmState.TextColor3=AF.running and colors.green or colors.muted
        bubbleDot.BackgroundColor3=AF.running and colors.green or colors.accent
        task.wait(1)
    end
end)

local function stop()
    saveDiscord()
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
local teleportConnection = LocalPlayer.OnTeleport:Connect(function()
    if not closed then saveDiscord() end
end)
gui.Destroying:Connect(function() teleportConnection:Disconnect() end)
env.DaishynFarmStop=stop
close.Activated:Connect(stop)
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
