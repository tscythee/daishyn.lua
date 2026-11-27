--[[
    ScyFe Auto Rollback (v4)
    Volleyball Legends

    Gira estilos ou habilidades ate vir um dos alvos escolhidos.
    Veio um alvo -> REJOIN (guarda) -> confirma -> segue para os que faltam.
    Nenhum alvo no limite de spins -> ROLLBACK (desfaz) e tenta de novo.

    Use na pasta autoexec do injetor. Configuracoes e progresso ficam em
    workspace/ScyFeAutoRollback/config_v3.json (sobrevivem a rejoin e rollback).

    Configuracao opcional antes da execucao (sobrescreve o que foi salvo):
        getgenv().ScyFeAutoRollbackConfig = {
            mode = "Style",                      -- "Style" ou "Ability"
            targetStyles = { "Kijo", "Tso" },
            targetAbilities = { "Shield Breaker" },
            spinType = "Lucky", abilityType = "Normal",
            slots = { "1", "3" },                -- vazio = slot atual
            spinsPerCycle = 10, useRollback = true, rejoinOnHit = true,
            autoStart = true, autoCodes = true,
            codes = { "CODIGO_EXTRA" },          -- opcional, alem da lista embutida
        }

    API: _G.ScyFeAutoRollback.Start() / .Stop() / .Unload()
]]

-- ============================================================
-- Instancia unica
-- ============================================================

local INSTANCE = {}
if _G.ScyFeAutoRollback and type(_G.ScyFeAutoRollback.Unload) == "function" then
    pcall(_G.ScyFeAutoRollback.Unload)
end
_G.__ScyFeInstance = INSTANCE

local function superseded()
    return _G.__ScyFeInstance ~= INSTANCE
end

-- Espera com limite de tempo (nunca fica preso para sempre)
local function waitUntil(cond, timeout, step)
    local t0 = os.clock()
    step = step or 0.25
    while true do
        local ok, res = pcall(cond)
        if ok and res then return true end
        if os.clock() - t0 >= timeout then return false end
        task.wait(step)
    end
end

waitUntil(function() return game:IsLoaded() end, 90, 0.5)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    waitUntil(function()
        LocalPlayer = Players.LocalPlayer
        return LocalPlayer ~= nil
    end, 30, 0.2)
end
if not LocalPlayer then
    warn("[ScyFe] LocalPlayer indisponivel; script encerrado.")
    return
end

-- ============================================================
-- Log e conexoes
-- ============================================================

local Hooks = { refresh = function() end }

local function log(msg)
    print("[ScyFe] " .. tostring(msg))
end

local conns = {}
local function track(c)
    conns[#conns + 1] = c
    return c
end

-- ============================================================
-- Utilidades de texto/lista
-- ============================================================

local function norm(s)
    s = tostring(s or "")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s:lower()
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

local function toList(v)
    local out = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do
            if type(x) == "string" and x ~= "" then out[#out + 1] = x end
        end
    elseif type(v) == "string" and v ~= "" then
        out[1] = v
    end
    return out
end

local function splitCSV(str)
    local out = {}
    for part in tostring(str or ""):gmatch("[^,;]+") do
        local t = part:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then out[#out + 1] = t end
    end
    return out
end

local function indexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

-- ============================================================
-- Listas do jogo
-- ============================================================

local SLOT_ORDER = { "1", "2", "3", "4", "+" }

local STYLE_LIST = {}
local STYLE_SET = {}    -- norm(nome) -> nome
for _, n in ipairs({
    "Akari", "Akuto", "Azmei", "Bakuri", "Encho", "Feiko", "Hakka", "Hakochi", "Hidari", "Hinto",
    "Hirakumi", "Ibara", "Imaezi", "Jinko", "Kazana", "Kijo", "Kisuki", "Koshoti", "Kozai", "Kumo",
    "Kyamo", "Kyoshin", "Mamori", "Mikage", "Ninyoku", "Okazu", "Oyatsu", "Riku", "Roketto", "Ronin",
    "Sagumi", "Sanju", "Sazuroku", "Shiro", "Taichou", "The Twins", "Timeskip Hinto", "Timeskip Kyamo",
    "Timeskip Okazu", "Tonkura", "Tsuchiro", "Uchikai", "Yakisukai", "Yogan", "Yokai", "Yomosuke",
}) do
    if not STYLE_SET[norm(n)] then
        STYLE_SET[norm(n)] = n
        STYLE_LIST[#STYLE_LIST + 1] = n
    end
end
table.sort(STYLE_LIST, function(a, b) return a:lower() < b:lower() end)

local ABILITY_LIST = {
    "Shield Breaker", "Magnetic Pull", "Lead Feet", "Extra Touch", "Godly", "Redirection Jump",
    "Curve Spike", "Divine Strength", "Legendary", "Steel Block", "Zero Gravity Set", "Rare",
    "Boom Jump", "Moonball", "Common", "Super Sprint", "Team Spirit", "Rolling Thunder",
}
local ABILITY_SET = {}
for _, n in ipairs(ABILITY_LIST) do ABILITY_SET[norm(n)] = n end

-- ============================================================
-- Configuracao e progresso (arquivo)
-- ============================================================

local ROOT = "ScyFeAutoRollback"
local CONFIG_FILE = ROOT .. "/config_v3.json"
local LEGACY_FILE = ROOT .. "/config.json"

local function fsReady()
    return type(writefile) == "function" and type(readfile) == "function"
        and type(isfile) == "function" and type(isfolder) == "function"
        and type(makefolder) == "function"
end

local function readJson(path)
    if not fsReady() then return nil end
    local ok, raw = pcall(function()
        if isfile(path) then return readfile(path) end
        return nil
    end)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok2 and type(data) == "table" then return data end
    return nil
end

local DEFAULT_SETTINGS = {
    mode = "Style",
    targetStyles = {},
    extraStyles = "",
    spinType = "Normal",
    targetAbilities = {},
    extraAbilities = "",
    abilityType = "Normal",
    slots = {},                 -- vazio = slot atual
    useRollback = true,
    spinsPerCycle = 10,
    interval = 0.5,
    autoStart = true,           -- entrar no jogo basta para a automacao comecar
    rejoinOnHit = true,
    saveWait = 3,
    autoCodes = true,
}

-- Converte o config antigo (v2) para o formato atual
local function migrateLegacy(old)
    local s = {}
    for _, k in ipairs({ "mode", "spinType", "abilityType", "useRollback", "spinsPerCycle", "interval",
        "autoStart", "rejoinOnHit", "saveWait", "autoCodes" }) do
        if old[k] ~= nil then s[k] = old[k] end
    end
    s.targetStyles = toList(old.targetStyles or old.targetStyle)
    s.extraStyles = tostring(old.extraStyles or "")
    s.targetAbilities = toList(old.targetAbilities or old.targetAbility)
    s.extraAbilities = tostring(old.extraAbilities or "")
    local slot = tostring(old.slot or "")
    if indexOf(SLOT_ORDER, slot) then s.slots = { slot } end
    return s
end

local function sanitizeSettings(s)
    -- v3 guardava "slotMode": so o modo Manual tinha slots escolhidos; os demais viram "slot atual"
    if s.slotMode ~= nil and s.slotMode ~= "Manual" then s.slots = {} end
    for k in pairs(s) do
        if DEFAULT_SETTINGS[k] == nil then s[k] = nil end
    end
    for k, v in pairs(DEFAULT_SETTINGS) do
        if s[k] == nil then s[k] = deepCopy(v) end
    end
    if s.mode ~= "Ability" then s.mode = "Style" end
    if s.spinType ~= "Lucky" then s.spinType = "Normal" end
    if s.abilityType ~= "Lucky" then s.abilityType = "Normal" end
    s.targetStyles = toList(s.targetStyles)
    s.targetAbilities = toList(s.targetAbilities)
    s.extraStyles = tostring(s.extraStyles or "")
    s.extraAbilities = tostring(s.extraAbilities or "")
    local slots = {}
    for _, v in ipairs(toList(s.slots)) do
        if indexOf(SLOT_ORDER, v) and not indexOf(slots, v) then slots[#slots + 1] = v end
    end
    s.slots = slots
    s.spinsPerCycle = math.clamp(math.floor(tonumber(s.spinsPerCycle) or 10), 1, 9999)
    s.interval = math.clamp(tonumber(s.interval) or 0.5, 0.1, 10)
    s.saveWait = math.clamp(tonumber(s.saveWait) or 3, 0, 30)
    for _, k in ipairs({ "useRollback", "autoStart", "rejoinOnHit", "autoCodes" }) do
        s[k] = s[k] == true
    end
    return s
end

local Store = { cfg = nil }

do
    local data = readJson(CONFIG_FILE)
    local cfg = { version = 3, settings = {}, progress = {} }
    if data and type(data.settings) == "table" then
        cfg.settings = data.settings
        if type(data.progress) == "table" then cfg.progress = data.progress end
    else
        local legacy = readJson(LEGACY_FILE)
        if legacy then cfg.settings = migrateLegacy(legacy) end
    end
    Store.cfg = cfg
end

local S = sanitizeSettings(Store.cfg.settings)
Store.cfg.settings = S

-- Configuracao explicita via getgenv tem prioridade sobre o arquivo
local override = nil
if type(getgenv) == "function" then
    local okEnv, env = pcall(getgenv)
    if okEnv and type(env) == "table" and type(env.ScyFeAutoRollbackConfig) == "table" then
        override = env.ScyFeAutoRollbackConfig
    end
end
if override then
    for k in pairs(DEFAULT_SETTINGS) do
        if override[k] ~= nil then S[k] = deepCopy(override[k]) end
    end
    -- atalhos de nome unico
    if override.targetStyle ~= nil and override.targetStyles == nil then S.targetStyles = toList(override.targetStyle) end
    if override.targetAbility ~= nil and override.targetAbilities == nil then S.targetAbilities = toList(override.targetAbility) end
    S = sanitizeSettings(S)
    Store.cfg.settings = S
end

-- Progresso fica por conta (UserId)
local function newProgress()
    return {
        done = {},            -- { name, slot, confirmed, at }
        huntSig = "",
        huntDone = false,
        cycles = 0,
        resume = false,
        resumeAt = 0,
        pending = nil,        -- { name, slot, at } aguardando confirmacao
        codes = { done = {}, bad = {}, pending = {} },
    }
end

local function P()
    local key = tostring(LocalPlayer.UserId)
    local p = Store.cfg.progress[key]
    if type(p) ~= "table" then
        p = newProgress()
        Store.cfg.progress[key] = p
    end
    if type(p.done) ~= "table" then p.done = {} end
    if type(p.codes) ~= "table" then p.codes = {} end
    for _, k in ipairs({ "done", "bad", "pending" }) do
        if type(p.codes[k]) ~= "table" then p.codes[k] = {} end
    end
    p.slotLocks = nil   -- removido na v4
    p.codes.log = nil
    return p
end

local function saveStore()
    if not fsReady() then return end
    pcall(function()
        if not isfolder(ROOT) then makefolder(ROOT) end
        writefile(CONFIG_FILE, HttpService:JSONEncode(Store.cfg))
    end)
end

-- ============================================================
-- Sessao, alvos e progresso
-- ============================================================

local Session = { active = false, token = 0, tries = 0 }

local function persist()
    local p = P()
    p.resume = Session.active
    p.resumeAt = os.time()
    saveStore()
end

local function modeInfo()
    if S.mode == "Ability" then
        return {
            service = "AbilityService", panel = "Abilities",
            lucky = (S.abilityType == "Lucky"), set = ABILITY_SET,
        }
    end
    return {
        service = "StyleService", panel = "Styles",
        lucky = (S.spinType == "Lucky"), set = STYLE_SET,
    }
end

-- Alvos do modo atual: marcados na lista + digitados em "Outros", sem repetir
local function activeTargets()
    local picked, extra
    if S.mode == "Ability" then
        picked, extra = S.targetAbilities, S.extraAbilities
    else
        picked, extra = S.targetStyles, S.extraStyles
    end
    local out, seen = {}, {}
    for _, n in ipairs(picked) do
        local k = norm(n)
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = n
        end
    end
    for _, n in ipairs(splitCSV(extra)) do
        local k = norm(n)
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = n
        end
    end
    return out
end

local function isCompleted(name)
    local k = norm(name)
    for _, e in ipairs(P().done) do
        if e.confirmed and norm(e.name) == k then return true end
    end
    return false
end

local function remainingTargets()
    local out = {}
    for _, n in ipairs(activeTargets()) do
        if not isCompleted(n) then out[#out + 1] = n end
    end
    return out
end

-- Nome do alvo pendente que corresponde ao texto lido, ou nil
local function matchTarget(current)
    if current == nil then return nil end
    local k = norm(current)
    for _, n in ipairs(remainingTargets()) do
        if norm(n) == k then return n end
    end
    return nil
end

local function huntSignature()
    local keys = {}
    for _, n in ipairs(activeTargets()) do keys[#keys + 1] = norm(n) end
    table.sort(keys)
    return S.mode .. "|" .. table.concat(keys, ",")
end

-- Se mudou modo ou lista de alvos, a caca recomeca
local function syncHunt()
    local p = P()
    local sig = huntSignature()
    if sig ~= p.huntSig then
        p.huntSig = sig
        p.done = {}
        p.huntDone = false
        p.pending = nil
    end
end

local function saveAll()
    syncHunt()
    persist()
end

local function recordCompleted(name, slot)
    local p = P()
    p.done[#p.done + 1] = { name = name, slot = slot, confirmed = true, at = os.time() }
    saveStore()
end

syncHunt()

-- ============================================================
-- Remotes do Knit
-- ============================================================

local function knitServices()
    local pk = ReplicatedStorage:FindFirstChild("Packages")
    local idx = pk and pk:FindFirstChild("_Index")
    if not idx then return nil end
    local cand = idx:FindFirstChild("sleitnick_knit@1.7.0")
    if not cand then
        for _, c in ipairs(idx:GetChildren()) do
            if c.Name:sub(1, 14) == "sleitnick_knit" then
                cand = c
                break
            end
        end
    end
    local knit = cand and cand:FindFirstChild("knit")
    return knit and knit:FindFirstChild("Services")
end

local function findRemote(serviceName, remoteName)
    local services = knitServices()
    local svc = services and services:FindFirstChild(serviceName)
    local folder = svc and svc:FindFirstChild("RF")
    return folder and folder:FindFirstChild(remoteName)
end

-- A chave do rollback tem um zero-width space (U+200B) entre "Spike" e o byte 143.
-- Escrita com escapes decimais para o caractere invisivel nao se perder ao copiar.
local ROLLBACK_KEY = "Spike\226\128\139\143"

-- ============================================================
-- Leitura do estilo/habilidade atual
-- ============================================================

local function getLobbyPanel(panelName)
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local interface = gui and gui:FindFirstChild("Interface")
    local lobby = interface and interface:FindFirstChild("Lobby")
    return lobby and lobby:FindFirstChild(panelName)
end

local function longestKnown(text, set)
    local t = norm(text)
    if t == "" then return nil end
    if set[t] then return set[t] end
    local best, bestLen = nil, 0
    for key, name in pairs(set) do
        if #key > bestLen and t:find(key, 1, true) then
            best = name
            bestLen = #key
        end
    end
    return best
end

local Reader = { attrHolder = nil, attrKey = nil, attrNext = 0, tagLabel = nil, tagNext = 0 }

local function readPanel(panelName)
    local panel = getLobbyPanel(panelName)
    local topPanel = panel and panel:FindFirstChild("TopPanel")
    local displayName = topPanel and topPanel:FindFirstChild("DisplayName")
    if not displayName then return nil end
    local ok, txt = pcall(function() return displayName.Text end)
    if ok and type(txt) == "string" and txt ~= "" then return txt end
    return nil
end

-- Atributo do jogador/personagem cujo valor e exatamente um nome conhecido
local function readAttr(set)
    if Reader.attrHolder and Reader.attrKey then
        local okA, v = pcall(function() return Reader.attrHolder:GetAttribute(Reader.attrKey) end)
        if okA and type(v) == "string" and set[norm(v)] then return v end
        Reader.attrHolder = nil
        Reader.attrKey = nil
    end
    if os.clock() < Reader.attrNext then return nil end
    Reader.attrNext = os.clock() + 1.5
    local holders = { LocalPlayer }
    if LocalPlayer.Character then holders[#holders + 1] = LocalPlayer.Character end
    for _, h in ipairs(holders) do
        local okA, attrs = pcall(function() return h:GetAttributes() end)
        if okA and type(attrs) == "table" then
            for k, v in pairs(attrs) do
                if type(v) == "string" and set[norm(v)] then
                    Reader.attrHolder = h
                    Reader.attrKey = k
                    return v
                end
            end
        end
    end
    return nil
end

-- Texto sobre a cabeca do proprio personagem (so estilos)
local function readNameTag(set)
    local char = LocalPlayer.Character
    if not char then return nil end
    if Reader.tagLabel and Reader.tagLabel.Parent then
        local okT, t = pcall(function() return Reader.tagLabel.Text end)
        if okT and type(t) == "string" then
            local k = longestKnown(t, set)
            if k then return k end
        end
        Reader.tagLabel = nil
    end
    if os.clock() < Reader.tagNext then return nil end
    Reader.tagNext = os.clock() + 1
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("TextLabel") then
            local okT, t = pcall(function() return d.Text end)
            if okT and type(t) == "string" then
                local k = longestKnown(t, set)
                if k then
                    Reader.tagLabel = d
                    return k
                end
            end
        end
    end
    return nil
end

local function readCurrent()
    local info = modeInfo()
    local v = readPanel(info.panel)
    if v then return v end
    v = readAttr(info.set)
    if v then return v end
    if S.mode ~= "Ability" then return readNameTag(info.set) end
    return nil
end

-- ============================================================
-- Selecao de slot (so estilo). O jogo decide o que e permitido.
-- ============================================================

local BLOCK_WORDS = { "buy", "purchase", "robux", "shop", "gamepass", "product", "premium", "vip" }

local function looksLikePurchase(inst)
    local path = inst:GetFullName():lower()
    for _, w in ipairs(BLOCK_WORDS) do
        if path:find(w, 1, true) then return true end
    end
    return false
end

-- Clica num GuiButton chamando os eventos dele
local function pressButton(btn)
    local fired = false
    if type(firesignal) == "function" then
        local a = pcall(firesignal, btn.MouseButton1Click)
        local b = pcall(firesignal, btn.Activated)
        fired = a or b
    end
    if not fired and type(getconnections) == "function" then
        for _, sig in ipairs({ btn.MouseButton1Click, btn.Activated }) do
            local okc, list = pcall(getconnections, sig)
            if okc and type(list) == "table" then
                for _, c in ipairs(list) do
                    if pcall(function() c:Fire() end) then fired = true end
                end
            end
        end
    end
    return fired
end

-- Botao do slot dentro do painel de estilos (nunca botoes de compra)
local function findSlotButton(slot)
    local styles = getLobbyPanel("Styles")
    if not styles then return nil end
    local names, texts
    if slot == "+" then
        names = { ["slot5"] = true, ["5"] = true, ["plus"] = true, ["extra"] = true, ["extraslot"] = true, ["addslot"] = true }
        texts = { ["+"] = true, ["5"] = true }
    else
        names = { [slot] = true, ["slot" .. slot] = true }
        texts = { [slot] = true }
    end
    for _, d in ipairs(styles:GetDescendants()) do
        if d:IsA("GuiButton") and not looksLikePurchase(d) then
            local nm = (d.Name:lower():gsub("[%s_%-]", ""))
            if names[nm] then return d end
            if d:IsA("TextButton") and texts[norm(d.Text)] then return d end
        end
    end
    return nil
end

-- Clica no slot (ate 5 tentativas, 1s entre elas)
local function selectSlot(slot, alive)
    alive = alive or function() return true end
    for _ = 1, 5 do
        local btn = findSlotButton(slot)
        if btn and pressButton(btn) then return true end
        if not alive() then return false end
        task.wait(1)
    end
    return false
end

-- ============================================================
-- Nivel do jogador
-- ============================================================

local function parseLevel(text)
    text = tostring(text or ""):upper()
    text = text:gsub("<[^>]+>", "")
    local n = text:match("^%s*LVL%.?%s*(%d+)%s*$")
        or text:match("^%s*LEVEL%s*(%d+)%s*$")
        or text:match("^%s*NIVEL%s*(%d+)%s*$")
    return n and tonumber(n) or nil
end

local levelLabelCache = nil

-- Atributo, leaderstats ou o texto "LVL 204" do HUD. Devolve o nivel (ou nil)
local function getPlayerLevel()
    local attr = LocalPlayer:GetAttribute("Level")
    if type(attr) == "number" then return attr end

    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        for _, nm in ipairs({ "Level", "LVL", "Lvl", "Nivel" }) do
            local v = ls:FindFirstChild(nm)
            if v and (v:IsA("IntValue") or v:IsA("NumberValue")) then return v.Value end
        end
    end

    if levelLabelCache and levelLabelCache.Parent then
        local n = parseLevel(levelLabelCache.Text)
        if n then return n end
    end
    levelLabelCache = nil

    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible then
            local n = parseLevel(d.Text)
            if n then
                local path = d:GetFullName():lower()
                if not (path:find("leaderboard", 1, true) or path:find("scoreboard", 1, true)
                    or path:find("friends", 1, true) or path:find("playerlist", 1, true)) then
                    levelLabelCache = d
                    return n
                end
            end
        end
    end
    return nil
end

-- ============================================================
-- Codigos
-- ============================================================

-- Lista conferida em 25/11/2026 (volleyballlegends.wiki, rocodes.gg e progameguides.com;
-- a wiki cita o anuncio oficial do Discord). Os codigos das updates 94 a 96 ja constam como
-- expirados nas fontes mais recentes. Regra do jogo: resgate exige nivel 15.
local CODE_MIN_LEVEL = 15
local BUILTIN_CODES = { "UPDATE_97", "YOGAN_RETURNS", "TURKEY_STAMPEDE" }

-- Lista embutida + codigos extras do config, sem repeticao
local function codeList()
    local out, seen = {}, {}
    local function add(c)
        if type(c) ~= "string" then return end
        c = c:gsub("^%s+", ""):gsub("%s+$", ""):upper()
        if c ~= "" and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end
    for _, c in ipairs(BUILTIN_CODES) do add(c) end
    if override and type(override.codes) == "table" then
        for _, c in ipairs(override.codes) do add(c) end
    end
    return out
end

-- Classifica a resposta do servidor: "ok", "done" (ja usado), "level" ou "bad" (invalido/expirado)
local function classifyCodeResult(ok, res)
    if not ok or res == false then return "bad" end
    local t = type(res) == "string" and res:lower() or ""
    if t ~= "" then
        if t:find("level", 1, true) or t:find("lvl", 1, true) or t:find("nivel", 1, true) then return "level" end
        if t:find("already", 1, true) or t:find("redeemed", 1, true) or t:find("ja resgat", 1, true) then return "done" end
        if t:find("invalid", 1, true) or t:find("expired", 1, true) or t:find("not valid", 1, true)
            or t:find("inval", 1, true) or t:find("expirad", 1, true) then
            return "bad"
        end
    end
    return "ok"
end

local codesBusy = false

local function pendingCodesCount()
    local n = 0
    for _ in pairs(P().codes.pending) do n = n + 1 end
    return n
end

-- Codigos da lista que ainda nao foram resgatados nem recusados
local function eligibleCodes()
    local cs = P().codes
    local n = 0
    for _, code in ipairs(codeList()) do
        if not cs.done[code] and not cs.bad[code] then n = n + 1 end
    end
    return n
end

-- Resumo: resgatados, aguardando nivel, recusados
local function codeSummary()
    local cs = P().codes
    local ok, bad = 0, 0
    for _ in pairs(cs.done) do ok = ok + 1 end
    for _ in pairs(cs.bad) do bad = bad + 1 end
    return ok, pendingCodesCount(), bad
end

-- Resgata os codigos elegiveis. Abaixo do nivel 15 o codigo fica pendente (sem chamar o servidor)
local function runCodes()
    if codesBusy then return end
    codesBusy = true
    local okRun, errRun = pcall(function()
        local cs = P().codes
        local rf = findRemote("CodeService", "Redeem")
        if not rf then return end
        local level = getPlayerLevel()
        if not level then
            log("codigos: nivel ainda nao legivel; tentativa adiada")
            return
        end
        for _, code in ipairs(codeList()) do
            if not cs.done[code] and not cs.bad[code] then
                if level < CODE_MIN_LEVEL then
                    cs.pending[code] = CODE_MIN_LEVEL
                else
                    local ok, res = pcall(function() return rf:InvokeServer(code) end)
                    local status = classifyCodeResult(ok, res)
                    log(string.format("codigo %s -> %s (%s)", code, status, tostring(res)))
                    if status == "level" then
                        cs.pending[code] = CODE_MIN_LEVEL
                    elseif status == "bad" then
                        cs.bad[code] = true
                        cs.pending[code] = nil
                    else
                        cs.done[code] = true
                        cs.pending[code] = nil
                    end
                    task.wait(0.4)
                end
            end
        end
        saveStore()
    end)
    codesBusy = false
    if not okRun then log("erro nos codigos: " .. tostring(errRun)) end
    Hooks.refresh()
end

-- ============================================================
-- Maquina de estados
-- ============================================================

local Machine = { state = "INITIALIZING", detail = "" }

-- IDLE e ERROR podem ser alcancados de qualquer estado
local TRANSITIONS = {
    INITIALIZING = { LOADING = true },
    IDLE = { LOADING = true },
    LOADING = { READY = true, COMPLETED = true },
    READY = { ROLLING = true, SAVING = true, COMPLETED = true, LOADING = true },
    ROLLING = { READY = true, SAVING = true, REJOINING = true },
    SAVING = { REJOINING = true, READY = true, COMPLETED = true },
    REJOINING = { LOADING = true },
    ERROR = { LOADING = true },
    COMPLETED = { LOADING = true },
}

local function setState(name, detail)
    local cur = Machine.state
    if name ~= cur and name ~= "IDLE" and name ~= "ERROR" then
        local allowed = TRANSITIONS[cur]
        if not (allowed and allowed[name]) then
            log("transicao invalida " .. cur .. " -> " .. name .. " (ignorada)")
            return false
        end
    end
    Machine.state = name
    Machine.detail = detail or ""
    Hooks.refresh()
    return true
end

local function setDetail(text)
    Machine.detail = text or ""
    Hooks.refresh()
end

-- msg: texto curto para o usuario | detail: informacao tecnica (so no console)
local function fail(msg, detail)
    log("ERRO: " .. tostring(detail or msg))
    Session.active = false
    setState("ERROR", tostring(msg))
    persist()
end

local function completeHunt()
    P().huntDone = true
    Session.active = false
    setState("COMPLETED", "")
    persist()
end

local function alwaysAlive() return true end

local function waitTime(seconds, alive)
    alive = alive or alwaysAlive
    local t0 = os.clock()
    while alive() and os.clock() - t0 < seconds do
        task.wait(0.1)
    end
end

-- ============================================================
-- Verificacao essencial: servico de spin e leitura do resultado (maximo 15s)
-- ============================================================

local function ensureReady(alive)
    local info = modeInfo()
    local missing = "remote"
    local t0 = os.clock()
    while alive() and os.clock() - t0 < 15 do
        if findRemote(info.service, "Roll") then
            if readCurrent() ~= nil then return true end
            missing = "leitura"
        else
            missing = "remote"
        end
        task.wait(1)
    end
    if not alive() then return false, "cancelado" end
    return false, missing
end

-- ============================================================
-- Giro
-- ============================================================

-- 1 spin, com ate 3 tentativas se o remote falhar
local function spinWithRetry(alive)
    local lastErr = "falha desconhecida"
    for attempt = 1, 3 do
        local info = modeInfo()
        local rf = findRemote(info.service, "Roll")
        if rf then
            local ok, res = pcall(function() return rf:InvokeServer(info.lucky) end)
            if ok then return true end
            lastErr = tostring(res)
        else
            lastErr = "remote Roll nao encontrado"
        end
        if not alive() then return false, "cancelado" end
        if attempt < 3 then waitTime(3, alive) end
    end
    return false, lastErr
end

-- Depois do spin, confere o valor varias vezes durante o intervalo
-- Devolve (nome do alvo ou nil, texto lido)
local function waitForTarget(maxWait, alive)
    local t0 = os.clock()
    local last = nil
    repeat
        last = readCurrent()
        local m = matchTarget(last)
        if m then return m, last end
        if not alive() then return nil, last end
        task.wait(0.05)
    until os.clock() - t0 >= maxWait
    last = readCurrent()
    return matchTarget(last), last
end

-- REJOIN: reentra no jogo mantendo o que foi salvo. Tenta ate 4 vezes.
local function teleportRejoin(alive, text)
    alive = alive or alwaysAlive
    for attempt = 1, 4 do
        if not alive() then return false, "cancelado" end
        setState("REJOINING", string.format("%s (%d/4)", text, attempt))
        pcall(function() TeleportService:Teleport(game.PlaceId) end)
        waitTime(12, alive)
    end
    return false, "teleport nao completou"
end

-- ROLLBACK: desfaz as acoes desde o ultimo save e reentra
local function rollbackAndRejoin(alive)
    local rf = nil
    local t0 = os.clock()
    while alive() and not rf and os.clock() - t0 < 15 do
        rf = findRemote("SettingsService", "UpdateKeybind")
        if not rf then task.wait(0.5) end
    end
    if not alive() then return false, "cancelado" end
    if not rf then return false, "remote UpdateKeybind nao encontrado" end

    local p = P()
    p.cycles = (tonumber(p.cycles) or 0) + 1
    setState("REJOINING", "rollback")
    persist() -- grava resume=true para o autoexec continuar depois do teleport

    local ok, err = pcall(function()
        rf:InvokeServer("MouseButton1", true, ROLLBACK_KEY)
    end)
    if not ok then return false, "rollback falhou: " .. tostring(err) end

    task.wait(0.5)
    return teleportRejoin(alive, "rollback")
end

-- ============================================================
-- Slot do proximo objetivo e confirmacao
-- ============================================================

-- Primeiro slot escolhido que ainda nao guarda um objetivo concluido.
-- Sem slots escolhidos (ou em habilidades) existe um unico lugar: o atual.
local function chooseSlot()
    if S.mode == "Ability" or #S.slots == 0 then
        if #P().done > 0 then return nil end
        return (S.mode == "Ability") and "-" or "Atual"
    end
    local used = {}
    for _, e in ipairs(P().done) do
        if e.slot then used[e.slot] = true end
    end
    for _, sl in ipairs(SLOT_ORDER) do
        if indexOf(S.slots, sl) and not used[sl] then return sl end
    end
    return nil
end

-- Depois do rejoin: confirma que o resultado foi realmente salvo
local function confirmPending(alive)
    local p = P()
    local pend = p.pending
    if not pend then return true end
    setDetail("Confirmando " .. pend.name)
    if pend.slot and pend.slot ~= "Atual" and pend.slot ~= "-" then
        if not selectSlot(pend.slot, alive) then
            if not alive() then return false, "cancelado" end
            return false, "Slot " .. pend.slot .. " indisponível para confirmar " .. pend.name .. "."
        end
        waitTime(1, alive)
    end

    local t0 = os.clock()
    while alive() and os.clock() - t0 < 12 do
        local seen = readCurrent()
        if seen and norm(seen) == norm(pend.name) then
            recordCompleted(pend.name, pend.slot)
            p.pending = nil
            saveStore()
            return true
        end
        task.wait(0.5)
    end
    if not alive() then return false, "cancelado" end
    p.pending = nil
    saveStore()
    return false, pend.name .. " não foi confirmado após o rejoin."
end

-- ============================================================
-- Codigos na inicializacao (uma vez por execucao do script)
-- ============================================================

local codesStartupDone = false
local function codesStartup()
    if codesStartupDone then
        waitUntil(function() return not codesBusy end, 40, 0.5)
        return
    end
    codesStartupDone = true
    waitUntil(function() return findRemote("CodeService", "Redeem") ~= nil end, 30, 1)
    waitUntil(function() return getPlayerLevel() ~= nil end, 20, 1)
    runCodes()
end

-- ============================================================
-- Loop de giro e sessao
-- ============================================================

-- Gira ate vir um alvo. Devolve o nome do alvo; nil se parou/errou/deu rollback
local function rollLoop(alive)
    Session.tries = 0
    while alive() do
        if Session.tries >= S.spinsPerCycle then
            if S.useRollback then
                local ok, err = rollbackAndRejoin(alive)
                if alive() and not ok then fail("Rollback não concluído.", err) end
            else
                fail("Limite de spins atingido.")
            end
            return nil
        end

        Session.tries = Session.tries + 1
        setState("ROLLING", "")

        local ok, err = spinWithRetry(alive)
        if not alive() then return nil end
        if not ok then
            fail("Falha ao girar.", err)
            return nil
        end

        local hit = waitForTarget(S.interval, alive)
        if not alive() then return nil end
        if hit then return hit end
    end
    return nil
end

local function sessionMain(token)
    local function alive()
        return Session.active and token == Session.token and not superseded()
    end

    setState("LOADING", "")
    if #activeTargets() == 0 then
        fail("Selecione ao menos um alvo.")
        return
    end
    local okReady, missing = ensureReady(alive)
    if not alive() then return end
    if not okReady then
        if missing == "remote" then
            fail("Serviço de spin indisponível.")
        else
            fail("Não foi possível ler o resultado do spin.")
        end
        return
    end

    if S.autoCodes then
        codesStartup()
        if not alive() then return end
    end

    local okC, errC = confirmPending(alive)
    if not alive() then return end
    if not okC then
        fail(errC)
        return
    end

    while alive() do
        setState("READY", "")
        if #activeTargets() == 0 then
            fail("Selecione ao menos um alvo.")
            return
        end
        if #remainingTargets() == 0 then
            completeHunt()
            return
        end

        local slot = chooseSlot()
        if not slot then
            fail("Sem slot livre para o próximo objetivo.")
            return
        end
        if slot ~= "Atual" and slot ~= "-" then
            if not selectSlot(slot, alive) then
                if alive() then fail("Slot " .. slot .. " indisponível.") end
                return
            end
            waitTime(1, alive)
            if not alive() then return end
        end
        Session.slot = slot

        -- o slot ja tem um alvo? registra sem gastar spin
        local pre = matchTarget(readCurrent())
        if pre then
            recordCompleted(pre, slot)
        else
            local hit = rollLoop(alive)
            if not hit then return end

            setState("SAVING", hit)
            P().pending = { name = hit, slot = slot, at = os.time() }
            persist()

            waitTime(S.saveWait, alive)
            if not alive() then return end
            if S.rejoinOnHit then
                local okT, errT = teleportRejoin(alive, "Guardando " .. hit)
                if alive() and not okT then fail("Rejoin não concluído.", errT) end
                return
            end
            -- sem rejoin: confirma na hora (o servidor so salva ao sair do jogo)
            local okP, errP = confirmPending(alive)
            if not alive() then return end
            if not okP then
                fail(errP)
                return
            end
        end
    end
end

local function resetProgress()
    local p = P()
    p.done = {}
    p.huntDone = false
    p.pending = nil
    p.cycles = 0
    saveStore()
    Hooks.refresh()
end

-- fresh = true: inicio manual. Se a caca anterior terminou, comeca uma nova
local function startSession(fresh)
    if Session.active then return false end
    if fresh and P().huntDone then resetProgress() end
    Session.active = true
    Session.token = Session.token + 1
    Session.tries = 0
    Session.slot = nil
    persist()
    local token = Session.token
    task.spawn(function()
        local ok, err = pcall(sessionMain, token)
        if not ok and token == Session.token and Session.active then
            fail("Erro inesperado.", err)
        end
    end)
    return true
end

local function stopSession()
    Session.active = false
    Session.token = Session.token + 1
    setState("IDLE", "")
    persist()
end

-- Tarefa de fundo: resgata os codigos que ainda faltam quando o nivel 15 for alcancado
local function startBackground()
    task.spawn(function()
        while not superseded() do
            task.wait(30)
            if S.autoCodes and not codesBusy and eligibleCodes() > 0
                and Machine.state ~= "SAVING" and Machine.state ~= "REJOINING" then
                local lvl = getPlayerLevel()
                if lvl and lvl >= CODE_MIN_LEVEL then runCodes() end
            end
        end
    end)
end

-- ============================================================
-- GUI (dentro de uma funcao para nao estourar o limite de variaveis locais do chunk)
-- ============================================================

local function buildGui()

    local C = {
        bg = Color3.fromRGB(12, 12, 14),
        panel = Color3.fromRGB(20, 20, 23),
        row = Color3.fromRGB(26, 26, 30),
        rowHi = Color3.fromRGB(36, 36, 41),
        line = Color3.fromRGB(46, 46, 52),
        line2 = Color3.fromRGB(74, 74, 82),
        text = Color3.fromRGB(238, 238, 242),
        sub = Color3.fromRGB(142, 142, 152),
        dim = Color3.fromRGB(98, 98, 108),
        ok = Color3.fromRGB(150, 205, 165),
        warn = Color3.fromRGB(214, 184, 120),
        err = Color3.fromRGB(214, 126, 126),
    }

    local ROW_H = 30
    local HEADER_H = 38
    local TAB_H = 28

    local function getHiddenParent()
        if type(gethui) == "function" then
            local ok, hui = pcall(gethui)
            if ok and hui then return hui end
        end
        local ok, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok and cg then return cg end
        return LocalPlayer:WaitForChild("PlayerGui")
    end

    local function protect(gui)
        if type(protect_gui) == "function" then pcall(protect_gui, gui) end
        if type(syn) == "table" and type(syn.protect_gui) == "function" then
            pcall(syn.protect_gui, gui)
        end
    end

    local function newInstance(class, props, parent)
        local inst = Instance.new(class)
        for k, v in pairs(props or {}) do inst[k] = v end
        if parent then inst.Parent = parent end
        return inst
    end

    local function corner(inst, radius)
        return newInstance("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, inst)
    end

    local function stroke(inst, color, thickness)
        return newInstance("UIStroke", {
            Color = color or C.line,
            Thickness = thickness or 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, inst)
    end

    local function padding(inst, l, r, t, b)
        return newInstance("UIPadding", {
            PaddingLeft = UDim.new(0, l),
            PaddingRight = UDim.new(0, r),
            PaddingTop = UDim.new(0, t),
            PaddingBottom = UDim.new(0, b),
        }, inst)
    end

    local function vlist(inst, gap)
        return newInstance("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, gap or 5),
        }, inst)
    end

    local function tween(inst, props, t)
        pcall(function()
            TweenService:Create(inst, TweenInfo.new(t or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
        end)
    end

    local ui = { dynamic = {} }

    -- --------------------------------------------------------
    -- Janela
    -- --------------------------------------------------------

    local ScreenGui = newInstance("ScreenGui", {
        Name = "ScyFe_AutoRollback",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })
    protect(ScreenGui)
    ScreenGui.Parent = getHiddenParent()

    local FloatBtn = newInstance("TextButton", {
        Size = UDim2.fromOffset(36, 36),
        Position = UDim2.new(0, 10, 0.5, -18),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Text = "S",
        TextColor3 = C.text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        AutoButtonColor = false,
        Selectable = false,
        ZIndex = 50,
    }, ScreenGui)
    corner(FloatBtn, 18)
    local FloatStroke = stroke(FloatBtn, C.line2, 1.5)

    local Window = newInstance("Frame", {
        Name = "Window",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(320, 400),
        BackgroundColor3 = C.bg,
        BorderSizePixel = 0,
        Visible = false,
        ClipsDescendants = true,
        ZIndex = 10,
    }, ScreenGui)
    corner(Window, 10)
    stroke(Window, C.line, 1)

    local function applyWindowSize()
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        Window.Size = UDim2.fromOffset(math.clamp(vp.X - 24, 270, 330), math.clamp(vp.Y - 56, 280, 410))
    end
    applyWindowSize()
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyWindowSize)) end
    end)

    -- Arrastar. onTap so dispara se nao houve arrasto
    local function makeDraggable(handle, target, onTap)
        local dragging = false
        local moved = false
        local dragStart, posStart
        track(handle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                moved = false
                dragStart = input.Position
                posStart = target.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        dragging = false
                        if not moved and onTap then onTap() end
                    end
                end)
            end
        end))
        track(UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                if delta.Magnitude > 6 then moved = true end
                if moved then
                    target.Position = UDim2.new(
                        posStart.X.Scale, posStart.X.Offset + delta.X,
                        posStart.Y.Scale, posStart.Y.Offset + delta.Y
                    )
                end
            end
        end))
    end

    local guiVisible = false
    local function setGuiVisible(v)
        guiVisible = v
        Window.Visible = v
    end

    local Header = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundTransparency = 1,
        ZIndex = 11,
    }, Window)

    local TitleLabel = newInstance("TextLabel", {
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -56, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = C.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Dashboard",
        ZIndex = 12,
    }, Header)

    local CloseBtn = newInstance("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(24, 24),
        BackgroundColor3 = C.row,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = C.sub,
        Text = "x",
        AutoButtonColor = false,
        ZIndex = 13,
    }, Header)
    corner(CloseBtn, 6)

    local TabBar = newInstance("ScrollingFrame", {
        Position = UDim2.fromOffset(0, HEADER_H),
        Size = UDim2.new(1, 0, 0, TAB_H),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollingDirection = Enum.ScrollingDirection.X,
        ScrollBarThickness = 0,
        ZIndex = 11,
    }, Window)
    padding(TabBar, 6, 6, 0, 0)
    newInstance("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 0),
    }, TabBar)

    newInstance("Frame", {
        Position = UDim2.fromOffset(0, HEADER_H + TAB_H),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = C.line,
        BorderSizePixel = 0,
        ZIndex = 11,
    }, Window)

    local PagesHolder = newInstance("Frame", {
        Position = UDim2.fromOffset(0, HEADER_H + TAB_H + 1),
        Size = UDim2.new(1, 0, 1, -(HEADER_H + TAB_H + 1)),
        BackgroundTransparency = 1,
        ZIndex = 11,
    }, Window)

    makeDraggable(Header, Window, nil)
    makeDraggable(FloatBtn, FloatBtn, function() setGuiVisible(not guiVisible) end)
    track(CloseBtn.MouseButton1Click:Connect(function() setGuiVisible(false) end))
    track(UserInputService.InputBegan:Connect(function(input, gp)
        if gp then return end
        if input.KeyCode == Enum.KeyCode.RightShift then setGuiVisible(not guiVisible) end
    end))

    -- --------------------------------------------------------
    -- Componentes
    -- --------------------------------------------------------

    local Pages = {}

    local function newPage(key, title)
        local sf = newInstance("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = C.line2,
            Visible = false,
            ZIndex = 12,
        }, PagesHolder)
        padding(sf, 10, 10, 8, 10)
        vlist(sf, 5)
        local pg = { title = title, frame = sf, n = 0 }
        Pages[key] = pg
        return pg
    end

    local function nextOrder(pg)
        pg.n = pg.n + 1
        return pg.n
    end

    local function baseRow(pg, height)
        local row = newInstance("Frame", {
            Size = UDim2.new(1, 0, 0, height or ROW_H),
            BackgroundColor3 = C.row,
            BorderSizePixel = 0,
            LayoutOrder = nextOrder(pg),
            ZIndex = 13,
        }, pg.frame)
        corner(row, 6)
        stroke(row, C.line, 1)
        return row
    end

    local function rowLabel(row, text, rightPad)
        return newInstance("TextLabel", {
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(1, -(rightPad or 10), 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = C.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = text,
            ZIndex = 14,
        }, row)
    end

    local function rowSwitch(pg, text, get, set)
        local row = baseRow(pg)
        rowLabel(row, text, 60)
        local trackFrame = newInstance("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -10, 0.5, 0),
            Size = UDim2.fromOffset(32, 16),
            BorderSizePixel = 0,
            ZIndex = 14,
        }, row)
        corner(trackFrame, 8)
        stroke(trackFrame, C.line2, 1)
        local knob = newInstance("Frame", {
            AnchorPoint = Vector2.new(0, 0.5),
            Size = UDim2.fromOffset(10, 10),
            BorderSizePixel = 0,
            ZIndex = 15,
        }, trackFrame)
        corner(knob, 5)
        local click = newInstance("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 16,
        }, row)
        local function paint(animate)
            local on = get() == true
            local pos = on and UDim2.new(1, -13, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
            trackFrame.BackgroundColor3 = on and C.text or C.panel
            knob.BackgroundColor3 = on and C.bg or C.sub
            if animate then tween(knob, { Position = pos }, 0.12) else knob.Position = pos end
        end
        track(click.MouseButton1Click:Connect(function()
            set(not (get() == true))
            paint(true)
        end))
        paint(false)
    end

    local function rowInput(pg, text, get, set)
        local row = baseRow(pg)
        rowLabel(row, text, 100)
        local box = newInstance("TextBox", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -6, 0.5, 0),
            Size = UDim2.fromOffset(72, 22),
            BackgroundColor3 = C.panel,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = C.text,
            ClearTextOnFocus = false,
            Text = tostring(get()),
            ZIndex = 14,
        }, row)
        corner(box, 5)
        stroke(box, C.line, 1)
        track(box.FocusLost:Connect(function()
            set(box.Text)
            box.Text = tostring(get())
        end))
    end

    local function rowInputWide(pg, text, get, set, placeholder)
        local row = baseRow(pg, 52)
        newInstance("TextLabel", {
            Position = UDim2.fromOffset(10, 4),
            Size = UDim2.new(1, -20, 0, 16),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = C.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = text,
            ZIndex = 14,
        }, row)
        local box = newInstance("TextBox", {
            Position = UDim2.fromOffset(10, 22),
            Size = UDim2.new(1, -20, 0, 24),
            BackgroundColor3 = C.panel,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = C.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            PlaceholderText = placeholder or "",
            PlaceholderColor3 = C.dim,
            ClearTextOnFocus = false,
            Text = tostring(get()),
            ZIndex = 14,
        }, row)
        corner(box, 5)
        stroke(box, C.line, 1)
        padding(box, 8, 8, 0, 0)
        track(box.FocusLost:Connect(function()
            set(box.Text)
            box.Text = tostring(get())
        end))
    end

    -- Lista que abre logo abaixo da linha. multi = true permite marcar varios
    local function rowDropdown(pg, text, options, get, set, multi)
        local row = baseRow(pg)
        rowLabel(row, text, 190)
        local valueLabel = newInstance("TextLabel", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -26, 0.5, 0),
            Size = UDim2.new(0, 150, 0, 18),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = C.sub,
            TextXAlignment = Enum.TextXAlignment.Right,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "",
            ZIndex = 14,
        }, row)
        local chevron = newInstance("TextLabel", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -10, 0.5, 0),
            Size = UDim2.fromOffset(12, 12),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextColor3 = C.sub,
            Text = "v",
            ZIndex = 14,
        }, row)
        local click = newInstance("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 16,
        }, row)

        local list = newInstance("ScrollingFrame", {
            Size = UDim2.new(1, 0, 0, 0),
            BackgroundColor3 = C.panel,
            BorderSizePixel = 0,
            Visible = false,
            ClipsDescendants = true,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = C.line2,
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            CanvasSize = UDim2.new(),
            LayoutOrder = nextOrder(pg),
            ZIndex = 15,
        }, pg.frame)
        corner(list, 6)
        stroke(list, C.line, 1)
        padding(list, 4, 4, 4, 4)
        vlist(list, 2)

        local items = {}
        local open = false
        local function paint()
            local v = get()
            if multi then
                valueLabel.Text = (#v == 0) and "nenhum" or table.concat(v, ", ")
            else
                valueLabel.Text = tostring(v)
            end
            for opt, item in pairs(items) do
                local on
                if multi then on = indexOf(v, opt) ~= nil else on = (v == opt) end
                item.TextColor3 = on and C.text or C.sub
                item.Text = (multi and (on and "[x] " or "[  ] ") or (on and "> " or "   ")) .. opt
            end
        end
        local function setOpen(v)
            open = v
            list.Visible = v
            list.Size = v and UDim2.new(1, 0, 0, math.min(#options * 26 + 8, 156)) or UDim2.new(1, 0, 0, 0)
            chevron.Text = v and "^" or "v"
        end
        for i, opt in ipairs(options) do
            local item = newInstance("TextButton", {
                Size = UDim2.new(1, -8, 0, 24),
                BackgroundColor3 = C.row,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamMedium,
                TextSize = 11,
                TextColor3 = C.sub,
                TextXAlignment = Enum.TextXAlignment.Left,
                Text = opt,
                AutoButtonColor = false,
                LayoutOrder = i,
                ZIndex = 16,
            }, list)
            corner(item, 4)
            padding(item, 8, 8, 0, 0)
            items[opt] = item
            track(item.MouseButton1Click:Connect(function()
                if multi then
                    local cur = deepCopy(get())
                    local idx = indexOf(cur, opt)
                    if idx then table.remove(cur, idx) else cur[#cur + 1] = opt end
                    local ordered = {}
                    for _, o in ipairs(options) do
                        if indexOf(cur, o) then ordered[#ordered + 1] = o end
                    end
                    set(ordered)
                else
                    set(opt)
                    setOpen(false)
                end
                paint()
            end))
        end
        track(click.MouseButton1Click:Connect(function() setOpen(not open) end))
        paint()
    end

    local function rowChips(pg, text, options, isOn, toggle)
        local row = baseRow(pg, 56)
        newInstance("TextLabel", {
            Position = UDim2.fromOffset(10, 4),
            Size = UDim2.new(1, -20, 0, 16),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = C.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = text,
            ZIndex = 14,
        }, row)
        local holder = newInstance("Frame", {
            Position = UDim2.fromOffset(10, 24),
            Size = UDim2.new(1, -20, 0, 24),
            BackgroundTransparency = 1,
            ZIndex = 14,
        }, row)
        newInstance("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 4),
        }, holder)
        local count = #options
        local chips = {}
        local function paint()
            for opt, b in pairs(chips) do
                local on = isOn(opt)
                b.BackgroundColor3 = on and C.text or C.panel
                b.TextColor3 = on and C.bg or C.sub
            end
        end
        for i, opt in ipairs(options) do
            local b = newInstance("TextButton", {
                Size = UDim2.new(1 / count, -((count - 1) * 4) / count, 1, 0),
                BackgroundColor3 = C.panel,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                TextSize = 11,
                TextColor3 = C.sub,
                Text = opt,
                AutoButtonColor = false,
                LayoutOrder = i,
                ZIndex = 15,
            }, holder)
            corner(b, 5)
            stroke(b, C.line, 1)
            chips[opt] = b
            track(b.MouseButton1Click:Connect(function()
                toggle(opt)
                paint()
            end))
        end
        paint()
    end

    local function rowKV(pg, key, getValue, getColor)
        local row = baseRow(pg, 28)
        newInstance("TextLabel", {
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(0.4, -10, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = C.sub,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = key,
            ZIndex = 14,
        }, row)
        local value = newInstance("TextLabel", {
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -10, 0, 0),
            Size = UDim2.new(0.6, -10, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = C.text,
            TextXAlignment = Enum.TextXAlignment.Right,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "",
            ZIndex = 14,
        }, row)
        ui.dynamic[#ui.dynamic + 1] = function()
            value.Text = tostring(getValue())
            value.TextColor3 = getColor and getColor() or C.text
        end
    end

    -- Texto de varias linhas. hideWhenEmpty esconde a linha quando nao ha texto
    local function rowInfo(pg, getText, color, hideWhenEmpty)
        local row = newInstance("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = C.row,
            BorderSizePixel = 0,
            LayoutOrder = nextOrder(pg),
            ZIndex = 13,
        }, pg.frame)
        corner(row, 6)
        stroke(row, C.line, 1)
        padding(row, 10, 10, 7, 7)
        local lbl = newInstance("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = color or C.sub,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            Text = "",
            ZIndex = 14,
        }, row)
        ui.dynamic[#ui.dynamic + 1] = function()
            local t = getText()
            lbl.Text = t
            if hideWhenEmpty then row.Visible = (t ~= "") end
        end
    end

    local function rowButton(pg, text, onClick)
        local row = baseRow(pg)
        rowLabel(row, text, 80)
        local hintLabel = newInstance("TextLabel", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -10, 0.5, 0),
            Size = UDim2.new(0, 120, 0, 18),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = C.dim,
            TextXAlignment = Enum.TextXAlignment.Right,
            Text = "",
            ZIndex = 14,
        }, row)
        local click = newInstance("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 16,
        }, row)
        track(click.MouseEnter:Connect(function() tween(row, { BackgroundColor3 = C.rowHi }, 0.1) end))
        track(click.MouseLeave:Connect(function() tween(row, { BackgroundColor3 = C.row }, 0.1) end))
        track(click.MouseButton1Click:Connect(function()
            tween(row, { BackgroundColor3 = C.rowHi }, 0.06)
            task.delay(0.12, function() tween(row, { BackgroundColor3 = C.row }, 0.12) end)
            onClick(hintLabel)
        end))
        return hintLabel
    end

    -- Botao que pede um segundo toque (acoes destrutivas)
    local function rowConfirmButton(pg, text, action)
        local armedAt = 0
        rowButton(pg, text, function(hintLabel)
            if armedAt ~= 0 and os.clock() - armedAt < 3 then
                armedAt = 0
                hintLabel.Text = ""
                action()
            else
                armedAt = os.clock()
                hintLabel.Text = "toque de novo"
                task.delay(3, function()
                    if armedAt ~= 0 and os.clock() - armedAt >= 3 then
                        armedAt = 0
                        hintLabel.Text = ""
                    end
                end)
            end
        end)
    end

    local function rowDual(pg, aText, aFn, bText, bFn)
        local row = newInstance("Frame", {
            Size = UDim2.new(1, 0, 0, ROW_H),
            BackgroundTransparency = 1,
            LayoutOrder = nextOrder(pg),
            ZIndex = 13,
        }, pg.frame)
        local function mk(text, xScale, fn)
            local b = newInstance("TextButton", {
                Position = UDim2.new(xScale, xScale == 0 and 0 or 3, 0, 0),
                Size = UDim2.new(0.5, -3, 1, 0),
                BackgroundColor3 = C.row,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = C.text,
                Text = text,
                AutoButtonColor = false,
                ZIndex = 14,
            }, row)
            corner(b, 6)
            stroke(b, C.line2, 1)
            track(b.MouseEnter:Connect(function() tween(b, { BackgroundColor3 = C.rowHi }, 0.1) end))
            track(b.MouseLeave:Connect(function() tween(b, { BackgroundColor3 = C.row }, 0.1) end))
            track(b.MouseButton1Click:Connect(fn))
            return b
        end
        return mk(aText, 0, aFn), mk(bText, 0.5, bFn)
    end

    -- --------------------------------------------------------
    -- Textos dinamicos
    -- --------------------------------------------------------

    local STATE_LABEL = {
        INITIALIZING = "Iniciando", IDLE = "Parado", LOADING = "Preparando", READY = "Pronto",
        ROLLING = "Girando", SAVING = "Salvando", REJOINING = "Reentrando", ERROR = "Erro",
        COMPLETED = "Concluído",
    }

    local function stateColor()
        local st = Machine.state
        if st == "ERROR" then return C.err end
        if st == "COMPLETED" then return C.ok end
        if st == "REJOINING" or st == "SAVING" then return C.warn end
        return C.text
    end

    local function completedText()
        local p = P()
        local lines = { "Concluídos" }
        for _, e in ipairs(p.done) do
            local where = (e.slot and e.slot ~= "-" and e.slot ~= "Atual") and ("  ·  slot " .. e.slot) or ""
            lines[#lines + 1] = e.name .. where
        end
        if p.pending then lines[#lines + 1] = p.pending.name .. "  ·  confirmando" end
        if #lines == 1 then lines[2] = "-" end
        return table.concat(lines, "\n")
    end

    -- --------------------------------------------------------
    -- Dashboard
    -- --------------------------------------------------------

    local pgD = newPage("dash", "Dashboard")

    rowKV(pgD, "Status", function() return STATE_LABEL[Machine.state] or Machine.state end, stateColor)
    rowInfo(pgD, function()
        if Machine.state == "ERROR" then return Machine.detail end
        return ""
    end, C.err, true)
    rowKV(pgD, "Objetivo atual", function() return remainingTargets()[1] or "-" end)
    rowKV(pgD, "Progresso", function()
        local total = #activeTargets()
        return string.format("%d/%d", total - #remainingTargets(), total)
    end)
    rowKV(pgD, "Slot em uso", function()
        if Session.active and Session.slot then return Session.slot end
        return "-"
    end)
    rowKV(pgD, "Ciclo", function()
        local cycle = (tonumber(P().cycles) or 0) + 1
        if Session.active then
            return string.format("%d  ·  %d/%d", cycle, Session.tries, S.spinsPerCycle)
        end
        return tostring(cycle)
    end)
    rowInfo(pgD, completedText, C.sub)
    local startBtn, stopBtn = rowDual(pgD, "INICIAR", function() startSession(true) end, "PARAR", function() stopSession() end)
    ui.dynamic[#ui.dynamic + 1] = function()
        startBtn.TextColor3 = Session.active and C.dim or C.text
        stopBtn.TextColor3 = Session.active and C.text or C.dim
    end

    -- --------------------------------------------------------
    -- Alvos
    -- --------------------------------------------------------

    local pgT = newPage("targets", "Alvos")
    local applyModeGroups

    rowDropdown(pgT, "Modo", { "Estilo", "Habilidade" },
        function() return S.mode == "Ability" and "Habilidade" or "Estilo" end,
        function(v)
            S.mode = (v == "Habilidade") and "Ability" or "Style"
            if applyModeGroups then applyModeGroups() end
            saveAll()
        end, false)

    local function makeGroup(pg)
        local frame = newInstance("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            LayoutOrder = nextOrder(pg),
            ZIndex = 13,
        }, pg.frame)
        vlist(frame, 5)
        return { frame = frame, n = 0 }, frame
    end

    local styleG, styleFrame = makeGroup(pgT)
    local abilityG, abilityFrame = makeGroup(pgT)

    applyModeGroups = function()
        styleFrame.Visible = S.mode ~= "Ability"
        abilityFrame.Visible = S.mode == "Ability"
    end

    rowDropdown(styleG, "Estilos", STYLE_LIST,
        function() return S.targetStyles end,
        function(v)
            S.targetStyles = v
            saveAll()
        end, true)
    rowInputWide(styleG, "Outros (separe por vírgula)",
        function() return S.extraStyles end,
        function(t)
            S.extraStyles = tostring(t or "")
            saveAll()
        end, "ex: Kijo, Tso")
    rowDropdown(styleG, "Tipo", { "Normal", "Lucky" },
        function() return S.spinType end,
        function(v)
            S.spinType = v
            saveAll()
        end, false)

    rowDropdown(abilityG, "Habilidades", ABILITY_LIST,
        function() return S.targetAbilities end,
        function(v)
            S.targetAbilities = v
            saveAll()
        end, true)
    rowInputWide(abilityG, "Outras (separe por vírgula)",
        function() return S.extraAbilities end,
        function(t)
            S.extraAbilities = tostring(t or "")
            saveAll()
        end, "ex: Shield Breaker")
    rowDropdown(abilityG, "Tipo", { "Normal", "Lucky" },
        function() return S.abilityType end,
        function(v)
            S.abilityType = v
            saveAll()
        end, false)

    applyModeGroups()

    -- --------------------------------------------------------
    -- Slots
    -- --------------------------------------------------------

    local pgS = newPage("slots", "Slots")

    rowChips(pgS, "Slots", { "Atual", "1", "2", "3", "4", "+" },
        function(opt)
            if opt == "Atual" then return #S.slots == 0 end
            return indexOf(S.slots, opt) ~= nil
        end,
        function(opt)
            if opt == "Atual" then
                S.slots = {}
            else
                local idx = indexOf(S.slots, opt)
                if idx then table.remove(S.slots, idx) else S.slots[#S.slots + 1] = opt end
            end
            saveAll()
        end)

    -- --------------------------------------------------------
    -- Automacao
    -- --------------------------------------------------------

    local pgA = newPage("auto", "Automação")

    rowInput(pgA, "Spins por ciclo",
        function() return S.spinsPerCycle end,
        function(t)
            local n = tonumber(t)
            if n then S.spinsPerCycle = math.clamp(math.floor(n), 1, 9999) end
            saveAll()
        end)
    rowInput(pgA, "Intervalo (s)",
        function() return S.interval end,
        function(t)
            local n = tonumber(t)
            if n then S.interval = math.clamp(math.floor(n * 100 + 0.5) / 100, 0.1, 10) end
            saveAll()
        end)
    rowSwitch(pgA, "Rollback se nada vier",
        function() return S.useRollback end,
        function(v)
            S.useRollback = v
            saveAll()
        end)
    rowSwitch(pgA, "Rejoin ao pegar",
        function() return S.rejoinOnHit end,
        function(v)
            S.rejoinOnHit = v
            saveAll()
        end)
    rowInput(pgA, "Espera do rejoin (s)",
        function() return S.saveWait end,
        function(t)
            local n = tonumber(t)
            if n then S.saveWait = math.clamp(math.floor(n * 10 + 0.5) / 10, 0, 30) end
            saveAll()
        end)

    -- --------------------------------------------------------
    -- Config
    -- --------------------------------------------------------

    local pgC = newPage("config", "Config")

    rowSwitch(pgC, "Iniciar automaticamente",
        function() return S.autoStart end,
        function(v)
            S.autoStart = v
            saveAll()
        end)
    rowSwitch(pgC, "Resgatar códigos ao iniciar",
        function() return S.autoCodes end,
        function(v)
            S.autoCodes = v
            saveAll()
        end)
    rowInfo(pgC, function()
        local ok, wait, bad = codeSummary()
        return string.format("Códigos: %d resgatados  ·  %d aguardando nível %d  ·  %d recusados", ok, wait, CODE_MIN_LEVEL, bad)
    end, C.sub)
    rowButton(pgC, "Resgatar códigos agora", function()
        if Machine.state == "SAVING" or Machine.state == "REJOINING" then return end
        task.spawn(runCodes)
    end)
    rowConfirmButton(pgC, "Descarregar script", function()
        if _G.ScyFeAutoRollback and _G.ScyFeAutoRollback.Unload then _G.ScyFeAutoRollback.Unload() end
    end)

    -- --------------------------------------------------------
    -- Abas
    -- --------------------------------------------------------

    local TAB_ORDER = { "dash", "targets", "slots", "auto", "config" }
    local TAB_LABEL = { dash = "Dashboard", targets = "Alvos", slots = "Slots", auto = "Automação", config = "Config" }
    local tabButtons = {}

    local function makeTabButton(label, order, onClick)
        local btn = newInstance("TextButton", {
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = C.sub,
            Text = label,
            AutoButtonColor = false,
            LayoutOrder = order,
            ZIndex = 12,
        }, TabBar)
        padding(btn, 8, 8, 0, 0)
        local bar = newInstance("Frame", {
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.new(0, 8, 1, 0),
            Size = UDim2.new(1, -16, 0, 2),
            BackgroundColor3 = C.text,
            BorderSizePixel = 0,
            Visible = false,
            ZIndex = 13,
        }, btn)
        track(btn.MouseButton1Click:Connect(onClick))
        return { btn = btn, bar = bar }
    end

    local lastRefresh = 0
    local refreshPending = false

    local function refreshNow()
        lastRefresh = os.clock()
        refreshPending = false
        for _, fn in ipairs(ui.dynamic) do pcall(fn) end
        if Machine.state == "ERROR" then
            FloatStroke.Color = C.err
        elseif Session.active then
            FloatStroke.Color = C.text
        else
            FloatStroke.Color = C.line2
        end
    end

    Hooks.refresh = function()
        if os.clock() - lastRefresh >= 0.1 then
            refreshNow()
        else
            refreshPending = true
        end
    end

    local function showPage(key)
        for k, pg in pairs(Pages) do pg.frame.Visible = (k == key) end
        for k, t in pairs(tabButtons) do
            t.btn.TextColor3 = (k == key) and C.text or C.sub
            t.bar.Visible = (k == key)
        end
        TitleLabel.Text = Pages[key].title
        refreshNow()
    end

    for i, key in ipairs(TAB_ORDER) do
        tabButtons[key] = makeTabButton(TAB_LABEL[key], i, function() showPage(key) end)
    end

    task.spawn(function()
        while not superseded() do
            task.wait(0.5)
            if guiVisible or refreshPending then refreshNow() end
        end
    end)

    showPage("dash")

    return ScreenGui
end

local ScreenGui = buildGui()

-- ============================================================
-- API, descarregar e inicio automatico
-- ============================================================

local function unload()
    Session.active = false
    Session.token = Session.token + 1
    persist() -- resume = false: reexecutar o script nao inicia sozinho
    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    pcall(function() ScreenGui:Destroy() end)
    if _G.__ScyFeInstance == INSTANCE then _G.__ScyFeInstance = nil end
    _G.ScyFeAutoRollback = nil
end

_G.ScyFeAutoRollback = {
    Start = function() return startSession(true) end,
    Stop = function() stopSession() end,
    State = S,
    Machine = Machine,
    Unload = unload,
}

log("v4 carregado. RightShift ou botao S abre/fecha o menu.")

startBackground()
setState("IDLE", "")

-- Codigos na inicializacao (independe da automacao de giro)
if S.autoCodes then
    task.spawn(function()
        if not superseded() then codesStartup() end
    end)
end

local function shouldResume()
    local p = P()
    return p.resume == true and (os.time() - (tonumber(p.resumeAt) or 0)) < 300
end

-- Entrou no jogo (autoexec ou rejoin): espera inicial de 5s e comeca
if shouldResume() or (S.autoStart and not P().huntDone) then
    task.spawn(function()
        task.wait(5)
        if not superseded() and not Session.active then startSession(false) end
    end)
end
