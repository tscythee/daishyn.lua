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

local LogLines = {}
local function log(msg)
    msg = tostring(msg)
    print("[ScyFe] " .. msg)
    LogLines[#LogLines + 1] = os.date("%H:%M:%S") .. " " .. msg
    if #LogLines > 40 then table.remove(LogLines, 1) end
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

-- Raridades Secret / Ultra / EVO: nunca sobrescrever sem permissao explicita
local VALUABLE_NAMES = {
    "Encho", "Hakka", "Akari", "Ronin", "Sanju", "Kisuki", "Timeskip Hinto", "Timeskip Okazu",
    "Timeskip Kyamo", "Kazana", "Taichou", "Yogan", "Mikage", "Mamori", "Ibara", "Riku",
    "Roketto", "Shiro", "The Twins", "Hidari", "Feiko", "Kumo", "Kijo", "Jinko",
}

local OTHER_STYLES = {
    "Akuto", "Bakuri", "Hinto", "Okazu", "Kyamo", "Hirakumi", "Kozai", "Azmei", "Uchikai",
    "Yokai", "Sazuroku", "Kyoshin", "Yomosuke", "Oyatsu", "Tsuchiro", "Imaezi", "Tonkura",
    "Ninyoku", "Hakochi", "Yakisukai", "Sagumi", "Koshoti",
}

local STYLE_LIST = {}
local STYLE_SET = {}    -- norm(nome) -> nome
local VALUABLE = {}     -- norm(nome) -> true
for _, n in ipairs(VALUABLE_NAMES) do
    VALUABLE[norm(n)] = true
    if not STYLE_SET[norm(n)] then
        STYLE_SET[norm(n)] = n
        STYLE_LIST[#STYLE_LIST + 1] = n
    end
end
for _, n in ipairs(OTHER_STYLES) do
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

local function writeText(path, text)
    if not fsReady() then return false end
    return pcall(function()
        if not isfolder(ROOT) then makefolder(ROOT) end
        writefile(path, text)
    end)
end

local DEFAULT_SETTINGS = {
    mode = "Style",
    targetStyles = {},
    extraStyles = "",
    spinType = "Normal",
    targetAbilities = {},
    extraAbilities = "",
    abilityType = "Normal",
    slotMode = "Auto",          -- Auto | Manual | Atual
    slots = { "1" },
    allowValuable = false,
    useRollback = true,
    spinsPerCycle = 10,
    interval = 0.5,
    autoStart = true,           -- entrar no jogo basta para a automacao comecar
    rejoinOnHit = true,
    saveWait = 3,
    autoCodes = true,
    codesLevel = 15,
    pityEnabled = true,
    pitySwapNonTarget = false,
}

-- Converte o config antigo (v2) para o formato novo
local function migrateLegacy(old)
    local s = {}
    local keys = { "mode", "spinType", "abilityType", "useRollback", "spinsPerCycle", "interval",
        "autoStart", "rejoinOnHit", "saveWait", "codesLevel" }
    for _, k in ipairs(keys) do
        if old[k] ~= nil then s[k] = old[k] end
    end
    s.targetStyles = toList(old.targetStyles or old.targetStyle)
    s.extraStyles = tostring(old.extraStyles or "")
    s.targetAbilities = toList(old.targetAbilities or old.targetAbility)
    s.extraAbilities = tostring(old.extraAbilities or "")
    -- "Atual" (v2) podia sobrescrever personagens: na v3 o padrao e o modo Automatico seguro
    local slot = tostring(old.slot or "Atual")
    if indexOf(SLOT_ORDER, slot) then
        s.slotMode = "Manual"
        s.slots = { slot }
    end
    return s
end

local function sanitizeSettings(s)
    for k, v in pairs(DEFAULT_SETTINGS) do
        if s[k] == nil then s[k] = deepCopy(v) end
    end
    if s.mode ~= "Ability" then s.mode = "Style" end
    if s.spinType ~= "Lucky" then s.spinType = "Normal" end
    if s.abilityType ~= "Lucky" then s.abilityType = "Normal" end
    if s.slotMode ~= "Manual" and s.slotMode ~= "Atual" then s.slotMode = "Auto" end
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
    s.codesLevel = math.clamp(math.floor(tonumber(s.codesLevel) or 15), 1, 999)
    for _, k in ipairs({ "allowValuable", "useRollback", "autoStart", "rejoinOnHit", "autoCodes", "pityEnabled", "pitySwapNonTarget" }) do
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

-- Progresso e protecoes ficam por conta (UserId)
local function newProgress()
    return {
        done = {},            -- { name, slot, confirmed, at, how }
        huntSig = "",
        huntDone = false,
        cycles = 0,
        resume = false,
        resumeAt = 0,
        pending = nil,        -- { name, slot, at } aguardando confirmacao
        slotLocks = {},       -- ["1"] = "Kijo"
        codes = { done = {}, bad = {}, pending = {}, log = {} },
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
    if type(p.slotLocks) ~= "table" then p.slotLocks = {} end
    if type(p.codes) ~= "table" then p.codes = {} end
    for _, k in ipairs({ "done", "bad", "pending", "log" }) do
        if type(p.codes[k]) ~= "table" then p.codes[k] = {} end
    end
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
            service = "AbilityService", panel = "Abilities", noun = "habilidade",
            lucky = (S.abilityType == "Lucky"), set = ABILITY_SET,
        }
    end
    return {
        service = "StyleService", panel = "Styles", noun = "estilo",
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

-- Se mudou modo ou lista de alvos, a caca recomeca (slots protegidos continuam)
local function syncHunt()
    local p = P()
    local sig = huntSignature()
    if sig ~= p.huntSig then
        if p.pending and p.pending.slot and p.pending.slot ~= "Atual" and p.pending.slot ~= "-" then
            p.slotLocks[p.pending.slot] = p.pending.name .. " (a confirmar)"
        end
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

local function recordCompleted(name, slot, how)
    local p = P()
    p.done[#p.done + 1] = { name = name, slot = slot, confirmed = true, at = os.time(), how = how or "" }
    if slot and slot ~= "Atual" and slot ~= "-" then
        p.slotLocks[slot] = name
    end
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

local function findRemote(serviceName, remoteName, kind)
    local services = knitServices()
    local svc = services and services:FindFirstChild(serviceName)
    local folder = svc and svc:FindFirstChild(kind or "RF")
    return folder and folder:FindFirstChild(remoteName)
end

-- A chave do rollback tem um zero-width space (U+200B) entre "Spike" e o byte 143.
-- Escrita com escapes decimais para o caractere invisivel nao se perder ao copiar.
local ROLLBACK_KEY = "Spike\226\128\139\143"

-- ============================================================
-- Leitura do estilo/habilidade atual (sem exigir a janela aberta)
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

local Reader = { source = "nenhuma", attrHolder = nil, attrKey = nil, attrNext = 0, tagLabel = nil, tagNext = 0 }

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
    if v then
        Reader.source = "painel " .. info.panel
        return v
    end
    v = readAttr(info.set)
    if v then
        Reader.source = "atributo " .. tostring(Reader.attrKey)
        return v
    end
    if S.mode ~= "Ability" then
        v = readNameTag(info.set)
        if v then
            Reader.source = "nametag"
            return v
        end
    end
    Reader.source = "nenhuma"
    return nil
end

-- ============================================================
-- Slots (so estilo): localizar, inspecionar, selecionar
-- ============================================================

local BLOCK_WORDS = { "buy", "purchase", "robux", "shop", "gamepass", "product", "premium", "vip" }
local LOCK_WORDS = { "lock", "bloque", "cadeado" }

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

-- Botao do slot dentro do painel de estilos (so botoes que parecem slot)
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

local EMPTY_MARKS = { ["empty"] = true, ["vazio"] = true, ["none"] = true, ["nenhum"] = true, ["empty slot"] = true }

-- Le o que o slot mostra. known = sabemos com certeza o conteudo (nome conhecido ou vazio)
local function inspectSlot(slot)
    local btn = findSlotButton(slot)
    if not btn then return { slot = slot, exists = false, known = false, locked = false } end
    local info = { slot = slot, exists = true, locked = false, known = false, occupant = nil, empty = false, path = btn:GetFullName() }
    local roots = { btn }
    local parent = btn.Parent
    if parent and parent:IsA("GuiObject") and #parent:GetChildren() <= 12 then roots[#roots + 1] = parent end
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("GuiObject") then
                local nm = d.Name:lower()
                for _, w in ipairs(LOCK_WORDS) do
                    if nm:find(w, 1, true) and d.Visible then info.locked = true end
                end
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    local okT, t = pcall(function() return d.Text end)
                    if okT and type(t) == "string" and t ~= "" then
                        local nt = norm(t)
                        if STYLE_SET[nt] and not info.occupant then info.occupant = STYLE_SET[nt] end
                        if EMPTY_MARKS[nt] then info.empty = true end
                        for _, w in ipairs(LOCK_WORDS) do
                            if nt:find(w, 1, true) then info.locked = true end
                        end
                    end
                end
            end
        end
    end
    info.known = info.occupant ~= nil or info.empty
    return info
end

-- Um slot e seguro? mode = "Auto" ou "Manual". Devolve ok, motivo, info
local function slotVerdict(slot, mode)
    local info = inspectSlot(slot)
    if not info.exists then return false, "botao nao encontrado", info end
    if info.locked then return false, "bloqueado", info end
    local lockedBy = P().slotLocks[slot]
    if lockedBy then return false, "protegido (" .. lockedBy .. ")", info end
    local occ = info.occupant
    if occ then
        if isCompleted(occ) then return false, "tem objetivo concluido (" .. occ .. ")", info end
        if VALUABLE[norm(occ)] and not (mode == "Manual" and S.allowValuable) then
            return false, "tem personagem valioso (" .. occ .. ")", info
        end
    end
    if mode == "Auto" and not info.known then
        return false, "conteudo desconhecido (nao e seguro)", info
    end
    return true, "ok", info
end

local function selectSlot(slot)
    if slot == "Atual" or slot == "-" then return true, "slot atual" end
    local btn = findSlotButton(slot)
    if not btn then
        return false, "botao do slot " .. slot .. " nao encontrado (use Mapear)"
    end
    if not pressButton(btn) then
        return false, "nao consegui clicar no slot (executor sem firesignal/getconnections)"
    end
    return true, btn:GetFullName()
end

-- Resumo para a GUI (usa o ultimo cache de inspecao)
local SlotCache = {}
local function refreshSlotCache()
    for _, sl in ipairs(SLOT_ORDER) do
        SlotCache[sl] = inspectSlot(sl)
    end
end

local function slotSummaryText()
    local lines = {}
    local locks = P().slotLocks
    for _, sl in ipairs(SLOT_ORDER) do
        local info = SlotCache[sl]
        local txt
        if locks[sl] then
            txt = "protegido: " .. locks[sl]
        elseif not info then
            txt = "nao lido"
        elseif not info.exists then
            txt = "nao encontrado"
        elseif info.locked then
            txt = "bloqueado"
        elseif info.occupant then
            txt = info.occupant .. (VALUABLE[norm(info.occupant)] and " (valioso)" or "")
        elseif info.empty then
            txt = "vazio"
        else
            txt = "conteudo desconhecido"
        end
        lines[#lines + 1] = sl .. ": " .. txt
    end
    return table.concat(lines, "\n")
end

-- ============================================================
-- Pity / selecao de probabilidade (deteccao heuristica)
-- ============================================================

local PITY_WORDS = { "pity", "select", "featured", "chance", "rate", "odds", "target", "boost", "wish", "guarantee" }
local Pity = { status = "ainda nao verificado", selected = nil, target = nil, failedTarget = nil }

local function colorIsGreen(c)
    return c.G > 0.45 and c.G > c.R + 0.2 and c.G > c.B + 0.2
end

local function hasGreen(root)
    local list = root:GetDescendants()
    table.insert(list, 1, root)
    local n = 0
    for _, d in ipairs(list) do
        n = n + 1
        if n > 80 then break end
        if d:IsA("GuiObject") and d.Visible then
            local okC, col = pcall(function() return d.BackgroundColor3 end)
            if okC and typeof(col) == "Color3" and d.BackgroundTransparency < 0.9 and colorIsGreen(col) then
                return true
            end
            if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                local okI, ic = pcall(function() return d.ImageColor3 end)
                if okI and typeof(ic) == "Color3" and d.ImageTransparency < 0.9 and colorIsGreen(ic) then
                    return true
                end
            end
        elseif d:IsA("UIStroke") then
            if colorIsGreen(d.Color) and d.Transparency < 0.9 then return true end
        end
    end
    return false
end

local function cardName(btn)
    local function exact(t)
        local nt = norm(t)
        return STYLE_SET[nt]
    end
    if btn:IsA("TextButton") then
        local k = exact(btn.Text)
        if k then return k end
    end
    for _, d in ipairs(btn:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local okT, t = pcall(function() return d.Text end)
            if okT and type(t) == "string" then
                local k = exact(t)
                if k then return k end
            end
        end
    end
    return nil
end

local function pityScan()
    local res = { cards = {}, selected = nil, ambiguous = false }
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    if not gui then return res end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("GuiButton") then
            local path = d:GetFullName():lower()
            local kw = false
            for _, w in ipairs(PITY_WORDS) do
                if path:find(w, 1, true) then
                    kw = true
                    break
                end
            end
            if kw and not looksLikePurchase(d) then
                local name = cardName(d)
                if name then
                    res.cards[#res.cards + 1] = { name = name, btn = d, green = hasGreen(d) }
                end
            end
        end
    end
    local greens = {}
    for _, c in ipairs(res.cards) do
        if c.green then greens[#greens + 1] = c end
    end
    if #greens == 1 then
        res.selected = greens[1].name
    elseif #greens > 1 then
        res.ambiguous = true
    end
    return res
end

-- Sincroniza a selecao verde com o proximo objetivo pendente (so se der para confirmar)
local function pitySync()
    if not S.pityEnabled then
        Pity.status = "desativado"
        return
    end
    if S.mode == "Ability" then
        Pity.status = "so para estilos"
        return
    end
    local remaining = remainingTargets()
    if #remaining == 0 then
        Pity.status = "sem objetivos pendentes"
        return
    end
    local target = remaining[1]
    local scan = pityScan()
    Pity.target = target
    Pity.selected = scan.selected
    if #scan.cards == 0 then
        Pity.status = "nao mapeado (nenhuma carta encontrada)"
        return
    end
    if scan.ambiguous then
        Pity.status = "ambiguo (varias marcacoes verdes)"
        return
    end
    if scan.selected and norm(scan.selected) == norm(target) then
        Pity.status = "ok: " .. target .. " ja selecionado"
        return
    end
    if scan.selected then
        for _, n in ipairs(remaining) do
            if norm(n) == norm(scan.selected) then
                Pity.status = "ok: " .. scan.selected .. " (objetivo pendente) mantido"
                return
            end
        end
        if not isCompleted(scan.selected) and not S.pitySwapNonTarget then
            Pity.status = "mantido: " .. scan.selected .. " (nao e objetivo; troca desativada)"
            return
        end
    end
    if Pity.failedTarget == norm(target) then
        Pity.status = "tentativa anterior nao confirmou para " .. target
        return
    end
    local card = nil
    for _, c in ipairs(scan.cards) do
        if norm(c.name) == norm(target) then
            card = c
            break
        end
    end
    if not card then
        Pity.status = "objetivo " .. target .. " sem carta nesta tela"
        return
    end
    if not pressButton(card.btn) then
        Pity.status = "nao consegui clicar (executor sem firesignal/getconnections)"
        Pity.failedTarget = norm(target)
        return
    end
    task.wait(0.8)
    local after = pityScan()
    Pity.selected = after.selected
    if after.selected and norm(after.selected) == norm(target) then
        Pity.status = "selecionado: " .. target
        Pity.failedTarget = nil
        log("Pity: selecao verde movida para " .. target)
    else
        Pity.status = "clique nao confirmou a marcacao em " .. target
        Pity.failedTarget = norm(target)
    end
end

-- ============================================================
-- Nivel do jogador e codigos
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

-- Atributo, leaderstats ou o texto "LVL 204" do HUD. Devolve nivel, origem
local function getPlayerLevel()
    local attr = LocalPlayer:GetAttribute("Level")
    if type(attr) == "number" then return attr, "atributo Level" end

    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        for _, nm in ipairs({ "Level", "LVL", "Lvl", "Nivel" }) do
            local v = ls:FindFirstChild(nm)
            if v and (v:IsA("IntValue") or v:IsA("NumberValue")) then
                return v.Value, "leaderstats." .. nm
            end
        end
    end

    if levelLabelCache and levelLabelCache.Parent then
        local n = parseLevel(levelLabelCache.Text)
        if n then return n, levelLabelCache:GetFullName() end
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
                    return n, d:GetFullName()
                end
            end
        end
    end
    return nil
end

local CODES_URL = "https://beebom.com/haikyuu-legends-codes/"

local function fetchCodes()
    local list = {}
    if override and type(override.codes) == "table" then
        for _, c in ipairs(override.codes) do
            if type(c) == "string" and c ~= "" then list[#list + 1] = c end
        end
        return list
    end
    local ok, body = pcall(function() return game:HttpGet(CODES_URL) end)
    if (not ok or type(body) ~= "string") and type(request) == "function" then
        local ok2, res = pcall(request, { Url = CODES_URL, Method = "GET" })
        if ok2 and type(res) == "table" and type(res.Body) == "string" then
            ok = true
            body = res.Body
        end
    end
    if not ok or type(body) ~= "string" then return list end
    local seen = {}
    for line in string.gmatch(body, "[^\n]+") do
        if string.find(line, "(NEW)", 1, true) then
            local code = string.match(line, "(%u+[%u%d_]+)")
            if code and not seen[code] then
                seen[code] = true
                list[#list + 1] = code
            end
        end
        if #list >= 15 then break end
    end
    return list
end

-- Classifica a resposta do servidor. Devolve status ("ok","done","bad","level"), nivel exigido
local function classifyCodeResult(ok, res, level)
    if not ok then return "bad", nil end
    local t = type(res) == "string" and res:lower() or ""
    if t ~= "" then
        if t:find("level", 1, true) or t:find("lvl", 1, true) or t:find("nivel", 1, true) then
            return "level", tonumber(t:match("(%d+)")) or S.codesLevel
        end
        if t:find("already", 1, true) or t:find("redeemed", 1, true) or t:find("ja resgat", 1, true) then
            return "done", nil
        end
        if t:find("invalid", 1, true) or t:find("expired", 1, true) or t:find("not valid", 1, true)
            or t:find("inval", 1, true) or t:find("expirad", 1, true) then
            return "bad", nil
        end
        return "ok", nil
    end
    if res == false then
        if level < S.codesLevel then return "level", S.codesLevel end
        return "bad", nil
    end
    return "ok", nil
end

local codesBusy = false
local CodeStats = { ok = 0, bad = 0, pending = 0, last = "nenhum resgate ainda" }

local function codeLog(msg)
    local cs = P().codes
    cs.log[#cs.log + 1] = os.date("%H:%M:%S") .. " " .. msg
    if #cs.log > 20 then table.remove(cs.log, 1) end
    log("codigo: " .. msg)
end

-- Resgata codigos elegiveis. onlyPending = so os que aguardavam nivel
local function runCodes(onlyPending)
    if codesBusy then return end
    codesBusy = true
    local okRun, errRun = pcall(function()
        local cs = P().codes
        local level = getPlayerLevel() or 0
        local rf = findRemote("CodeService", "Redeem")
        if not rf then
            CodeStats.last = "remote Redeem nao encontrado"
            return
        end
        local list = {}
        local seen = {}
        for code, req in pairs(cs.pending) do
            if level >= (tonumber(req) or S.codesLevel) then
                list[#list + 1] = code
                seen[code] = true
            end
        end
        if not onlyPending then
            for _, code in ipairs(fetchCodes()) do
                if not seen[code] and not cs.done[code] and not cs.bad[code] and cs.pending[code] == nil then
                    list[#list + 1] = code
                    seen[code] = true
                end
            end
        end
        if #list == 0 then
            CodeStats.last = "nenhum codigo elegivel agora"
            return
        end
        for _, code in ipairs(list) do
            local ok, res = pcall(function() return rf:InvokeServer(code) end)
            local status, req = classifyCodeResult(ok, res, level)
            if status == "ok" or status == "done" then
                cs.done[code] = true
                cs.pending[code] = nil
                if status == "ok" then CodeStats.ok = CodeStats.ok + 1 end
            elseif status == "level" then
                cs.pending[code] = req or S.codesLevel
                CodeStats.pending = CodeStats.pending + 1
            else
                cs.bad[code] = true
                cs.pending[code] = nil
                CodeStats.bad = CodeStats.bad + 1
            end
            codeLog(string.format("%s -> %s (resposta: %s)", code, status, tostring(res)))
            task.wait(0.4)
        end
        CodeStats.last = string.format("ok %d | pendentes por nivel %d | invalidos %d",
            CodeStats.ok, CodeStats.pending, CodeStats.bad)
        saveStore()
    end)
    codesBusy = false
    if not okRun then
        CodeStats.last = "erro: " .. tostring(errRun)
        log("erro nos codigos: " .. tostring(errRun))
    end
end

local function pendingCodesCount()
    local n = 0
    for _ in pairs(P().codes.pending) do n = n + 1 end
    return n
end

-- ============================================================
-- Maquina de estados
-- ============================================================

local Machine = { state = "INITIALIZING", detail = "iniciando", since = os.clock() }

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
    if name ~= cur then
        Machine.state = name
        Machine.since = os.clock()
    end
    Machine.detail = detail or ""
    Hooks.refresh()
    return true
end

local function setDetail(text)
    Machine.detail = text or ""
    Hooks.refresh()
end

local function fail(msg)
    log("ERRO: " .. tostring(msg))
    Session.active = false
    setState("ERROR", tostring(msg))
    persist()
end

local function completeHunt(msg)
    local p = P()
    p.huntDone = true
    Session.active = false
    setState("COMPLETED", msg or "todos os objetivos concluidos")
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
-- Recursos necessarios (com limite de tempo e novas tentativas)
-- ============================================================

local function missingResources()
    local missing = {}
    local info = modeInfo()
    if not LocalPlayer:FindFirstChild("PlayerGui") then missing[#missing + 1] = "PlayerGui" end
    if not findRemote(info.service, "Roll") then missing[#missing + 1] = "remote " .. info.service .. ".Roll" end
    if readCurrent() == nil then missing[#missing + 1] = "leitura do " .. info.noun .. " atual" end
    return missing
end

local function waitResources(alive)
    local rounds = 3
    local lastMissing = {}
    for round = 1, rounds do
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 45 do
            lastMissing = missingResources()
            if #lastMissing == 0 then return true end
            setState("LOADING", string.format("aguardando (%d/%d): %s", round, rounds, table.concat(lastMissing, ", ")))
            task.wait(1)
        end
        if not alive() then return false, "cancelado" end
        if round < rounds then waitTime(5, alive) end
    end
    return false, table.concat(lastMissing, ", ")
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
            if ok then
                Session.lastRoll = tostring(res)
                return true
            end
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
    setState("REJOINING", "rollback do ciclo " .. tostring(p.cycles))
    persist() -- grava resume=true para o autoexec continuar depois do teleport

    local ok, err = pcall(function()
        rf:InvokeServer("MouseButton1", true, ROLLBACK_KEY)
    end)
    if not ok then return false, "rollback falhou: " .. tostring(err) end

    task.wait(0.5)
    return teleportRejoin(alive, "rollback feito, reentrando")
end

-- ============================================================
-- Slots: escolha segura, adocao do que ja existe e confirmacao
-- ============================================================

local function chooseSlot(alive)
    if S.mode == "Ability" then
        if S.slotMode ~= "Atual" and #P().done > 0 then
            return nil, "habilidades: este script ainda nao gerencia slots de habilidade; girar de novo substituiria a habilidade preservada. Escolha o proximo objetivo manualmente (ou use o modo Atual)."
        end
        return "-"
    end
    if S.slotMode == "Atual" then return "Atual" end

    local mode = (S.slotMode == "Manual") and "Manual" or "Auto"
    local candidates = {}
    if mode == "Manual" then
        for _, sl in ipairs(SLOT_ORDER) do
            if indexOf(S.slots, sl) then candidates[#candidates + 1] = sl end
        end
        if #candidates == 0 then return nil, "nenhum slot autorizado (aba Slots)" end
    else
        candidates = SLOT_ORDER
    end

    -- o painel precisa existir; espera um pouco (com limite)
    waitUntil(function() return (not alive()) or getLobbyPanel("Styles") ~= nil end, 10, 0.5)
    if not alive() then return nil, "cancelado" end

    local best, bestRank = nil, 99
    local reasons = {}
    local protectedCount = 0
    for _, sl in ipairs(candidates) do
        local ok, why, info = slotVerdict(sl, mode)
        SlotCache[sl] = info
        if ok then
            local rank = 1
            if mode == "Auto" then
                if info.empty then rank = 1 elseif info.known then rank = 2 else rank = 3 end
            end
            if rank < bestRank then
                best = sl
                bestRank = rank
            end
        else
            reasons[#reasons + 1] = sl .. ": " .. why
            if why:sub(1, 9) == "protegido" then protectedCount = protectedCount + 1 end
        end
    end
    if best then return best end
    if protectedCount == #candidates then
        return nil, "ha mais objetivos do que slots disponiveis (todos os slots permitidos ja guardam personagens)"
    end
    return nil, "nenhum slot seguro (" .. table.concat(reasons, "; ") .. ")"
end

-- Personagem pendente que ja esta num slot: registra e protege, sem gastar spin
local function adoptExisting()
    if S.mode == "Ability" or S.slotMode == "Atual" then return end
    local remaining = remainingTargets()
    if #remaining == 0 then return end
    local p = P()
    for _, sl in ipairs(SLOT_ORDER) do
        local info = inspectSlot(sl)
        SlotCache[sl] = info
        if info.occupant and not p.slotLocks[sl] then
            for _, n in ipairs(remaining) do
                if norm(n) == norm(info.occupant) and not isCompleted(n) then
                    recordCompleted(n, sl, "ja estava no slot")
                    log("ja possui " .. n .. " no slot " .. sl .. " (protegido)")
                end
            end
        end
    end
end

-- Depois do rejoin: confirma que o resultado foi realmente salvo
local function confirmPending(alive)
    local p = P()
    local pend = p.pending
    if not pend then return true end
    local where = tostring(pend.slot or "-")
    setDetail("confirmando " .. pend.name .. " (slot " .. where .. ")")
    local hasSlot = pend.slot and pend.slot ~= "Atual" and pend.slot ~= "-"

    if hasSlot then
        local okSel, why = selectSlot(pend.slot)
        if not okSel then
            p.slotLocks[pend.slot] = pend.name .. " (a confirmar)"
            saveStore()
            return false, "nao consegui selecionar o slot " .. pend.slot .. " para confirmar " .. pend.name
                .. " (" .. tostring(why) .. "). O slot foi protegido; verifique manualmente."
        end
        waitTime(1, alive)
    end

    local seen = nil
    local t0 = os.clock()
    while alive() and os.clock() - t0 < 12 do
        seen = readCurrent()
        if seen and norm(seen) == norm(pend.name) then
            recordCompleted(pend.name, pend.slot, "confirmado")
            p.pending = nil
            saveStore()
            log("confirmado: " .. pend.name .. " (slot " .. where .. ")")
            return true
        end
        task.wait(0.5)
    end
    if not alive() then return false, "cancelado" end

    if hasSlot then p.slotLocks[pend.slot] = pend.name .. " (nao confirmado)" end
    p.pending = nil
    saveStore()
    if seen == nil then
        return false, "nao consegui ler o slot para confirmar " .. pend.name .. ". O slot foi protegido; verifique manualmente."
    end
    log("nao confirmado: esperava " .. pend.name .. " e li " .. tostring(seen) .. " (slot " .. where .. " protegido)")
    return true
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
                if alive() and not ok then fail("rollback: " .. tostring(err)) end
            else
                fail("limite de spins atingido sem nenhum alvo (rollback desligado)")
            end
            return nil
        end

        Session.tries = Session.tries + 1
        setState("ROLLING", string.format("ciclo %d | tentativa %d/%d",
            (tonumber(P().cycles) or 0) + 1, Session.tries, S.spinsPerCycle))

        local ok, err = spinWithRetry(alive)
        if not alive() then return nil end
        if not ok then
            fail("falha ao girar: " .. tostring(err))
            return nil
        end

        local hit, got = waitForTarget(S.interval, alive)
        if not alive() then return nil end
        if hit then return hit, got end
        Session.last = tostring(got or "?")
        Hooks.refresh()
    end
    return nil
end

-- Codigos na inicializacao: roda uma vez por execucao do script (os demais esperam terminar)
local codesStartupDone = false
local function codesStartup()
    if codesStartupDone then
        waitUntil(function() return not codesBusy end, 40, 0.5)
        return
    end
    codesStartupDone = true
    waitUntil(function() return findRemote("CodeService", "Redeem") ~= nil end, 60, 1)
    runCodes(false)
end

local function sessionMain(token)
    local function alive()
        return Session.active and token == Session.token and not superseded()
    end

    setState("LOADING", "verificando recursos")
    local okRes, why = waitResources(alive)
    if not alive() then return end
    if not okRes then
        fail("recursos indisponiveis: " .. tostring(why))
        return
    end

    if S.autoCodes then
        setDetail("resgatando codigos")
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
        setState("READY", "preparando proximo objetivo")
        if #activeTargets() == 0 then
            fail("nenhum alvo selecionado (aba Alvos)")
            return
        end
        if #remainingTargets() == 0 then
            completeHunt()
            return
        end

        adoptExisting()
        if #remainingTargets() == 0 then
            completeHunt()
            return
        end

        local slot, whySlot = chooseSlot(alive)
        if not alive() then return end
        if not slot then
            fail(whySlot)
            return
        end
        if slot ~= "Atual" and slot ~= "-" then
            setDetail("selecionando slot " .. slot)
            local okS, infoS = selectSlot(slot)
            if not okS then
                fail("slot " .. slot .. ": " .. tostring(infoS))
                return
            end
            waitTime(1, alive)
            if not alive() then return end
        end
        Session.slot = slot

        pcall(pitySync)
        if not alive() then return end

        local pre = matchTarget(readCurrent())
        if pre then
            recordCompleted(pre, slot, "ja estava no slot")
            log("ja possui " .. pre .. " no slot " .. tostring(slot))
        else
            local hit = rollLoop(alive)
            if not hit then return end

            setState("SAVING", "veio " .. hit)
            local p = P()
            p.pending = { name = hit, slot = slot, at = os.time() }
            persist()
            log("veio " .. hit .. " (slot " .. tostring(slot) .. ")")

            waitTime(S.saveWait, alive)
            if not alive() then return end
            if S.rejoinOnHit then
                local okT, errT = teleportRejoin(alive, "guardando " .. hit .. " (rejoin)")
                if alive() and not okT then fail("rejoin: " .. tostring(errT)) end
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

local function startSession()
    if Session.active then return false end
    Session.active = true
    Session.token = Session.token + 1
    Session.tries = 0
    Session.last = nil
    persist()
    local token = Session.token
    task.spawn(function()
        local ok, err = pcall(sessionMain, token)
        if not ok then
            log("erro interno: " .. tostring(err))
            if token == Session.token and Session.active then fail("erro interno: " .. tostring(err)) end
        end
    end)
    return true
end

local function stopSession(msg)
    Session.active = false
    Session.token = Session.token + 1
    setState("IDLE", msg or "parado")
    persist()
end

local function resetProgress()
    local p = P()
    p.done = {}
    p.huntDone = false
    p.pending = nil
    p.slotLocks = {}
    p.cycles = 0
    Pity.failedTarget = nil
    saveStore()
    Hooks.refresh()
end

-- Tarefa de fundo: libera codigos que aguardavam nivel
local function startBackground()
    task.spawn(function()
        while not superseded() do
            task.wait(10)
            if S.autoCodes and not codesBusy and pendingCodesCount() > 0
                and Machine.state ~= "SAVING" and Machine.state ~= "REJOINING" then
                local lvl = getPlayerLevel()
                if lvl then
                    local eligible = false
                    for _, req in pairs(P().codes.pending) do
                        if lvl >= (tonumber(req) or S.codesLevel) then eligible = true end
                    end
                    if eligible then runCodes(true) end
                end
            end
        end
    end)
end

-- ============================================================
-- Diagnostico (mapa do que o script consegue ler no jogo)
-- ============================================================

local function buildDump()
    local L = {}
    local function add(t) L[#L + 1] = t end
    add("== ScyFe dump v3 ==")
    add("estado: " .. Machine.state .. " | detalhe: " .. Machine.detail)
    add("leitura atual: " .. Reader.source .. " | modo: " .. S.mode .. " | slotMode: " .. S.slotMode)

    local services = knitServices()
    for _, svc in ipairs({ "StyleService", "AbilityService", "CodeService", "SettingsService" }) do
        local folder = services and services:FindFirstChild(svc)
        if folder then
            for _, kind in ipairs({ "RF", "RE" }) do
                local sub = folder:FindFirstChild(kind)
                if sub then
                    local names = {}
                    for _, c in ipairs(sub:GetChildren()) do names[#names + 1] = c.Name end
                    add(svc .. "." .. kind .. ": " .. table.concat(names, ", "))
                end
            end
        else
            add(svc .. ": nao encontrado")
        end
    end

    add("-- atributos")
    local holders = { { "Player", LocalPlayer }, { "Character", LocalPlayer.Character } }
    for _, h in ipairs(holders) do
        if h[2] then
            local okA, attrs = pcall(function() return h[2]:GetAttributes() end)
            if okA and type(attrs) == "table" then
                local n = 0
                for k, v in pairs(attrs) do
                    n = n + 1
                    if n <= 40 then add(h[1] .. "." .. tostring(k) .. " = " .. tostring(v)) end
                end
            end
        end
    end
    local sv = 0
    for _, d in ipairs(LocalPlayer:GetDescendants()) do
        if d:IsA("StringValue") and sv < 40 then
            sv = sv + 1
            add("StringValue " .. d:GetFullName() .. " = " .. tostring(d.Value))
        end
    end

    add("-- painel Styles / slots")
    local styles = getLobbyPanel("Styles")
    if styles then
        local count = 0
        for _, d in ipairs(styles:GetDescendants()) do
            if d:IsA("GuiObject") and count < 250 then
                local nm = d.Name:lower()
                local interesting = d:IsA("GuiButton") or nm:find("slot", 1, true) or nm:find("lock", 1, true)
                    or nm:find("plus", 1, true) or nm:find("equip", 1, true) or nm:find("select", 1, true)
                if interesting then
                    count = count + 1
                    local txt = ""
                    local okT, t = pcall(function() return d.Text end)
                    if okT and type(t) == "string" then txt = t end
                    local path = (d:GetFullName():gsub("^.-Styles", "Styles"))
                    add(string.format("%s | %s | text=%q | visible=%s", path, d.ClassName, txt, tostring(d.Visible)))
                end
            end
        end
    else
        add("painel Styles nao encontrado")
    end
    for _, sl in ipairs(SLOT_ORDER) do
        local info = inspectSlot(sl)
        add(string.format("slot %s: exists=%s locked=%s occupant=%s empty=%s known=%s", sl,
            tostring(info.exists), tostring(info.locked), tostring(info.occupant), tostring(info.empty), tostring(info.known)))
    end

    add("-- pity")
    local scan = pityScan()
    add(string.format("cartas=%d selecionado=%s ambiguo=%s", #scan.cards, tostring(scan.selected), tostring(scan.ambiguous)))
    for _, c in ipairs(scan.cards) do
        add(string.format("carta %s | verde=%s | %s", c.name, tostring(c.green), c.btn:GetFullName()))
    end
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    if gui then
        local nPity, nPct = 0, 0
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("GuiObject") then
                local nm = d.Name:lower()
                for _, w in ipairs(PITY_WORDS) do
                    if nm:find(w, 1, true) and nPity < 80 then
                        nPity = nPity + 1
                        local txt = ""
                        local okT, t = pcall(function() return d.Text end)
                        if okT and type(t) == "string" then txt = t end
                        add(string.format("pity? %s | %s | text=%q", d:GetFullName(), d.ClassName, txt))
                        break
                    end
                end
                if d:IsA("TextLabel") and nPct < 40 then
                    local okT, t = pcall(function() return d.Text end)
                    if okT and type(t) == "string" and t:find("%d+%s*%%") then
                        nPct = nPct + 1
                        add(string.format("percentual %s | text=%q", d:GetFullName(), t))
                    end
                end
            end
        end
    end

    add("-- nivel / codigos")
    local lvl, src = getPlayerLevel()
    add("nivel=" .. tostring(lvl) .. " origem=" .. tostring(src))
    for _, l in ipairs(P().codes.log) do add("codigo " .. l) end

    local text = table.concat(L, "\n")
    for _, l in ipairs(L) do print("[ScyFe dump] " .. l) end
    local saved = writeText(ROOT .. "/dump.txt", text)
    local copied = false
    if type(setclipboard) == "function" then copied = pcall(setclipboard, text) end
    return #L, copied, saved
end

-- A GUI inteira fica dentro de uma funcao (evita o limite de 200 variaveis locais do chunk principal)
local function buildGui()

-- ============================================================
-- GUI: tema e utilidades
-- ============================================================

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

local function stroke(inst, color, thickness, transparency)
    return newInstance("UIStroke", {
        Color = color or C.line,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
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
        Padding = UDim.new(0, gap or 6),
    }, inst)
end

local function tween(inst, props, t)
    pcall(function()
        TweenService:Create(inst, TweenInfo.new(t or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
    end)
end

local ui = { dynamic = {}, repaint = {} }

-- ============================================================
-- GUI: janela
-- ============================================================

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
    Size = UDim2.fromOffset(38, 38),
    Position = UDim2.new(0, 10, 0.5, -19),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
    Text = "S",
    TextColor3 = C.text,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    AutoButtonColor = false,
    Selectable = false,
    ZIndex = 50,
}, ScreenGui)
corner(FloatBtn, 19)
local FloatStroke = stroke(FloatBtn, C.line2, 1.5)

local Window = newInstance("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.fromOffset(360, 460),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Visible = false,
    ClipsDescendants = true,
    ZIndex = 10,
}, ScreenGui)
corner(Window, 12)
stroke(Window, C.line, 1)

local function viewportSize()
    local cam = workspace.CurrentCamera
    if cam then return cam.ViewportSize end
    return Vector2.new(800, 600)
end

local function applyWindowSize()
    local vp = viewportSize()
    local w = math.clamp(vp.X - 24, 280, 400)
    local h = math.clamp(vp.Y - 56, 300, 540)
    Window.Size = UDim2.fromOffset(w, h)
end
applyWindowSize()
pcall(function()
    local cam = workspace.CurrentCamera
    if cam then
        track(cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyWindowSize))
    end
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

local HEADER_H = 56
local TAB_H = 32

local Header = newInstance("Frame", {
    Size = UDim2.new(1, 0, 0, HEADER_H),
    BackgroundTransparency = 1,
    ZIndex = 11,
}, Window)

local TitleLabel = newInstance("TextLabel", {
    Position = UDim2.fromOffset(16, 8),
    Size = UDim2.new(1, -90, 0, 20),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = C.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "Dashboard",
    ZIndex = 12,
}, Header)

local DescLabel = newInstance("TextLabel", {
    Position = UDim2.fromOffset(16, 29),
    Size = UDim2.new(1, -90, 0, 16),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = C.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "",
    ZIndex = 12,
}, Header)

local function headerButton(text, xOffset)
    local b = newInstance("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, xOffset, 0, 10),
        Size = UDim2.fromOffset(28, 28),
        BackgroundColor3 = C.row,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = C.sub,
        Text = text,
        AutoButtonColor = false,
        ZIndex = 13,
    }, Header)
    corner(b, 8)
    stroke(b, C.line, 1)
    return b
end

local HelpBtn = headerButton("?", -44)
local CloseBtn = headerButton("x", -10)

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
padding(TabBar, 10, 10, 0, 0)
newInstance("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 2),
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

-- ============================================================
-- GUI: componentes de linha
-- ============================================================

local Pages = {}

local function newPage(key, title, desc)
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
    padding(sf, 12, 12, 10, 12)
    vlist(sf, 6)
    local pg = { key = key, title = title, desc = desc, frame = sf, n = 0 }
    Pages[key] = pg
    return pg
end

local function nextOrder(pg)
    pg.n = pg.n + 1
    return pg.n
end

local function baseRow(pg, height)
    local row = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, height),
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
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -(rightPad or 12), 1, 0),
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

local function sectionTitle(pg, text)
    return newInstance("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = C.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = string.upper(text),
        LayoutOrder = nextOrder(pg),
        ZIndex = 13,
    }, pg.frame)
end

local function rowSwitch(pg, text, get, set)
    local row = baseRow(pg, 36)
    rowLabel(row, text, 64)
    local trackFrame = newInstance("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(34, 18),
        BorderSizePixel = 0,
        ZIndex = 14,
    }, row)
    corner(trackFrame, 9)
    stroke(trackFrame, C.line2, 1)
    local knob = newInstance("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.fromOffset(12, 12),
        BorderSizePixel = 0,
        ZIndex = 15,
    }, trackFrame)
    corner(knob, 6)
    local click = newInstance("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 16,
    }, row)
    local function paint(animate)
        local on = get() == true
        local pos = on and UDim2.new(1, -15, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
        if on then
            trackFrame.BackgroundColor3 = C.text
            knob.BackgroundColor3 = C.bg
        else
            trackFrame.BackgroundColor3 = C.panel
            knob.BackgroundColor3 = C.sub
        end
        if animate then tween(knob, { Position = pos }, 0.12) else knob.Position = pos end
    end
    track(click.MouseButton1Click:Connect(function()
        set(not (get() == true))
        paint(true)
    end))
    paint(false)
    ui.repaint[#ui.repaint + 1] = function() paint(false) end
end

local function rowInput(pg, text, get, set, placeholder)
    local row = baseRow(pg, 36)
    rowLabel(row, text, 130)
    local box = newInstance("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(104, 24),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = C.text,
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = C.dim,
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
    ui.repaint[#ui.repaint + 1] = function() box.Text = tostring(get()) end
end

local function rowInputWide(pg, text, get, set, placeholder)
    local row = baseRow(pg, 58)
    newInstance("TextLabel", {
        Position = UDim2.fromOffset(12, 6),
        Size = UDim2.new(1, -24, 0, 16),
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
        Position = UDim2.fromOffset(12, 26),
        Size = UDim2.new(1, -24, 0, 24),
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
    ui.repaint[#ui.repaint + 1] = function() box.Text = tostring(get()) end
end

-- Lista que abre logo abaixo da linha. multi = true permite marcar varios
local function rowDropdown(pg, text, options, get, set, multi)
    local row = baseRow(pg, 36)
    rowLabel(row, text, 190)
    local valueLabel = newInstance("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -28, 0.5, 0),
        Size = UDim2.new(0, 170, 0, 18),
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
        Size = UDim2.fromOffset(14, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
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
    local function summary()
        local v = get()
        if multi then
            if #v == 0 then return "nenhum" end
            return table.concat(v, ", ")
        end
        return tostring(v)
    end
    local function paint()
        valueLabel.Text = summary()
        for opt, item in pairs(items) do
            local on
            if multi then on = indexOf(get(), opt) ~= nil else on = (get() == opt) end
            item.TextColor3 = on and C.text or C.sub
            item.Text = (multi and (on and "[x] " or "[  ] ") or (on and "> " or "   ")) .. opt
        end
    end
    local function setOpen(v)
        open = v
        list.Visible = v
        list.Size = v and UDim2.new(1, 0, 0, math.min(#options * 28 + 8, 172)) or UDim2.new(1, 0, 0, 0)
        chevron.Text = v and "^" or "v"
    end
    for i, opt in ipairs(options) do
        local item = newInstance("TextButton", {
            Size = UDim2.new(1, -8, 0, 26),
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
                -- mantem a ordem da lista
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
    ui.repaint[#ui.repaint + 1] = paint
end

local function rowChips(pg, text, options, isOn, toggle)
    local row = baseRow(pg, 62)
    newInstance("TextLabel", {
        Position = UDim2.fromOffset(12, 6),
        Size = UDim2.new(1, -24, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = C.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = text,
        ZIndex = 14,
    }, row)
    local holder = newInstance("Frame", {
        Position = UDim2.fromOffset(12, 28),
        Size = UDim2.new(1, -24, 0, 26),
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
            if isOn(opt) then
                b.BackgroundColor3 = C.text
                b.TextColor3 = C.bg
            else
                b.BackgroundColor3 = C.panel
                b.TextColor3 = C.sub
            end
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
    ui.repaint[#ui.repaint + 1] = paint
end

local function rowKV(pg, key, getValue, getColor)
    local row = baseRow(pg, 32)
    newInstance("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.38, -12, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = C.sub,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = key,
        ZIndex = 14,
    }, row)
    local value = newInstance("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 0),
        Size = UDim2.new(0.62, -12, 1, 0),
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

local function rowInfo(pg, getText, color)
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
    padding(row, 12, 12, 9, 9)
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
        Text = getText(),
        ZIndex = 14,
    }, row)
    ui.dynamic[#ui.dynamic + 1] = function() lbl.Text = getText() end
end

local function rowButton(pg, text, hint, onClick)
    local row = baseRow(pg, 36)
    rowLabel(row, text, 150)
    local hintLabel = newInstance("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.new(0, 130, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = C.dim,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = hint or "tocar para executar",
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
    rowButton(pg, text, "tocar 2x para confirmar", function(hintLabel)
        if os.clock() - armedAt < 3 then
            armedAt = 0
            hintLabel.Text = "feito"
            action()
            task.delay(2, function() hintLabel.Text = "tocar 2x para confirmar" end)
        else
            armedAt = os.clock()
            hintLabel.Text = "toque de novo (3s)"
            task.delay(3, function()
                if armedAt ~= 0 and os.clock() - armedAt >= 3 then
                    armedAt = 0
                    hintLabel.Text = "tocar 2x para confirmar"
                end
            end)
        end
    end)
end

local function rowDual(pg, aText, aFn, bText, bFn)
    local row = newInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
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
    local a = mk(aText, 0, aFn)
    local b = mk(bText, 0.5, bFn)
    return a, b
end

-- ============================================================
-- GUI: textos dinamicos
-- ============================================================

local function stateColor()
    local st = Machine.state
    if st == "ERROR" then return C.err end
    if st == "COMPLETED" then return C.ok end
    if st == "REJOINING" or st == "SAVING" then return C.warn end
    return C.text
end

local function pendingText()
    if #activeTargets() == 0 then return "nenhum alvo selecionado" end
    local rem = remainingTargets()
    if #rem == 0 then return "nenhum (todos concluidos)" end
    return table.concat(rem, ", ")
end

local function completedText()
    local p = P()
    if #p.done == 0 and not p.pending then return "nenhum ainda" end
    local lines = {}
    for _, e in ipairs(p.done) do
        local where = (e.slot and e.slot ~= "-" and e.slot ~= "Atual") and (" - slot " .. e.slot) or ""
        lines[#lines + 1] = e.name .. where
    end
    if p.pending then lines[#lines + 1] = p.pending.name .. " (aguardando confirmacao)" end
    return table.concat(lines, "\n")
end

local function slotModeLabel()
    if S.slotMode == "Manual" then return "Manual" end
    if S.slotMode == "Atual" then return "Atual (sem protecao)" end
    return "Automatico"
end

local function runDump(hintLabel)
    task.spawn(function()
        local ok, n, copied, saved = pcall(buildDump)
        local msg
        if ok then
            msg = copied and "copiado" or (saved and "salvo em dump.txt" or "gerado no console")
            log(string.format("mapa gerado: %d linhas | clipboard: %s | arquivo: %s", n, tostring(copied), tostring(saved)))
        else
            msg = "erro (veja o console)"
            log("erro no mapa: " .. tostring(n))
        end
        hintLabel.Text = msg
        task.delay(4, function() hintLabel.Text = "tocar para mapear" end)
    end)
end

local applyModeGroups

-- Impede acoes manuais que mexem no jogo enquanto a automacao esta girando/salvando/reentrando
local function gameBusy()
    local st = Machine.state
    return st == "ROLLING" or st == "SAVING" or st == "REJOINING" or st == "LOADING"
end

-- ============================================================
-- Pagina: Dashboard
-- ============================================================

local pgD = newPage("dash", "Dashboard", "Status geral da automacao")

sectionTitle(pgD, "Estado")
rowKV(pgD, "Estado", function() return Machine.state end, stateColor)
rowInfo(pgD, function()
    local d = Machine.detail ~= "" and Machine.detail or "-"
    return d
end)
rowKV(pgD, "Objetivo atual", function()
    local rem = remainingTargets()
    return rem[1] or "-"
end)
rowKV(pgD, "Progresso", function()
    local total = #activeTargets()
    return string.format("%d/%d", total - #remainingTargets(), total)
end)
rowKV(pgD, "Slot em uso", function()
    if S.mode == "Ability" then return "-" end
    if Session.active and Session.slot then return Session.slot end
    return slotModeLabel()
end)
rowKV(pgD, "Leitura", function() return Reader.source end)
rowKV(pgD, "Ciclo", function()
    return string.format("%d | %d/%d | ultimo: %s", (tonumber(P().cycles) or 0) + 1,
        Session.tries, S.spinsPerCycle, tostring(Session.last or "-"))
end)
sectionTitle(pgD, "Concluidos")
rowInfo(pgD, function() return completedText() end)
rowDual(pgD, "INICIAR", function()
    if not startSession() then log("ja esta em execucao") end
end, "PARAR", function()
    stopSession("parado pelo usuario")
end)

-- ============================================================
-- Pagina: Alvos
-- ============================================================

local pgT = newPage("targets", "Alvos", "Personagens ou habilidades que voce quer pegar")

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
    vlist(frame, 6)
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
rowInputWide(styleG, "Outros estilos (separe por virgula)",
    function() return S.extraStyles end,
    function(t)
        S.extraStyles = tostring(t or "")
        saveAll()
    end, "ex: Kijo, Tso")
rowDropdown(styleG, "Tipo de spin", { "Normal", "Lucky" },
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
rowInputWide(abilityG, "Outras habilidades (separe por virgula)",
    function() return S.extraAbilities end,
    function(t)
        S.extraAbilities = tostring(t or "")
        saveAll()
    end, "ex: Shield Breaker")
rowDropdown(abilityG, "Tipo de spin", { "Normal", "Lucky" },
    function() return S.abilityType end,
    function(v)
        S.abilityType = v
        saveAll()
    end, false)

applyModeGroups()

sectionTitle(pgT, "Pendentes")
rowInfo(pgT, function() return pendingText() end)
sectionTitle(pgT, "Concluidos")
rowInfo(pgT, function() return completedText() end)
rowConfirmButton(pgT, "Resetar progresso", function()
    resetProgress()
    for _, fn in ipairs(ui.repaint) do pcall(fn) end
end)

-- ============================================================
-- Pagina: Slots
-- ============================================================

local pgS = newPage("slots", "Slots", "Onde os personagens podem ser girados")

rowInfo(pgS, function()
    if S.mode == "Ability" then
        return "Modo Habilidade: slots de habilidade ainda nao sao gerenciados. Depois de guardar uma habilidade, o script nao gira outra por cima dela."
    end
    return "Automatico: so usa slot com certeza seguro. Manual: so os slots marcados. Atual: nao troca de slot e nao protege nada."
end)
rowDropdown(pgS, "Modo de slot", { "Automatico", "Manual", "Atual (sem protecao)" },
    function() return slotModeLabel() end,
    function(v)
        if v == "Manual" then
            S.slotMode = "Manual"
        elseif v == "Automatico" then
            S.slotMode = "Auto"
        else
            S.slotMode = "Atual"
        end
        saveAll()
    end, false)
rowChips(pgS, "Slots autorizados (modo Manual)", SLOT_ORDER,
    function(opt) return indexOf(S.slots, opt) ~= nil end,
    function(opt)
        local idx = indexOf(S.slots, opt)
        if idx then table.remove(S.slots, idx) else S.slots[#S.slots + 1] = opt end
        saveAll()
    end)
rowSwitch(pgS, "Sobrescrever valiosos (Manual)",
    function() return S.allowValuable end,
    function(v)
        S.allowValuable = v
        saveAll()
    end)
sectionTitle(pgS, "Leitura dos slots")
rowInfo(pgS, function() return slotSummaryText() end)
rowButton(pgS, "Atualizar leitura", "tocar para ler", function()
    task.spawn(function()
        pcall(refreshSlotCache)
        Hooks.refresh()
    end)
end)
rowConfirmButton(pgS, "Liberar slots protegidos", function()
    P().slotLocks = {}
    saveStore()
    Hooks.refresh()
end)
rowButton(pgS, "Mapear slots (diagnostico)", "tocar para mapear", runDump)

-- ============================================================
-- Pagina: Automacao
-- ============================================================

local pgA = newPage("auto", "Automacao", "Execucao, rejoin e rollback")

rowSwitch(pgA, "Iniciar automaticamente",
    function() return S.autoStart end,
    function(v)
        S.autoStart = v
        saveAll()
    end)
rowSwitch(pgA, "Rejoin ao pegar (guarda o alvo)",
    function() return S.rejoinOnHit end,
    function(v)
        S.rejoinOnHit = v
        saveAll()
    end)
rowInput(pgA, "Espera antes do rejoin (s)",
    function() return S.saveWait end,
    function(t)
        local n = tonumber(t)
        if n then S.saveWait = math.clamp(math.floor(n * 10 + 0.5) / 10, 0, 30) end
        saveAll()
    end)
rowSwitch(pgA, "Rollback se nada vier",
    function() return S.useRollback end,
    function(v)
        S.useRollback = v
        saveAll()
    end)
rowInput(pgA, "Spins por ciclo",
    function() return S.spinsPerCycle end,
    function(t)
        local n = tonumber(t)
        if n then S.spinsPerCycle = math.clamp(math.floor(n), 1, 9999) end
        saveAll()
    end)
rowInput(pgA, "Intervalo por spin (s)",
    function() return S.interval end,
    function(t)
        local n = tonumber(t)
        if n then S.interval = math.clamp(math.floor(n * 100 + 0.5) / 100, 0.1, 10) end
        saveAll()
    end)
sectionTitle(pgA, "Como funciona")
rowInfo(pgA, function()
    return "REJOIN: reentra guardando o que voce ja pegou. Usado quando vem um alvo.\n"
        .. "ROLLBACK: reentra desfazendo as acoes. Usado so quando o limite de spins acaba sem nenhum alvo.\n"
        .. "Rollbacks feitos: " .. tostring(P().cycles or 0)
end)

-- ============================================================
-- Pagina: Pity
-- ============================================================

local pgP = newPage("pity", "Pity", "Selecao verde e garantias do jogo")

rowSwitch(pgP, "Sincronizar selecao",
    function() return S.pityEnabled end,
    function(v)
        S.pityEnabled = v
        saveAll()
    end)
rowSwitch(pgP, "Trocar selecao que nao e objetivo",
    function() return S.pitySwapNonTarget end,
    function(v)
        S.pitySwapNonTarget = v
        saveAll()
    end)
rowKV(pgP, "Selecao atual", function() return Pity.selected or "-" end)
rowKV(pgP, "Objetivo", function() return Pity.target or "-" end)
rowInfo(pgP, function() return "Status: " .. tostring(Pity.status) end)
rowButton(pgP, "Sincronizar agora", "tocar para executar", function()
    if gameBusy() then
        Pity.status = "aguarde: a automacao esta em andamento (" .. Machine.state .. ")"
        Hooks.refresh()
        return
    end
    task.spawn(function()
        pcall(pitySync)
        Hooks.refresh()
    end)
end)
rowButton(pgP, "Mapear Pity (diagnostico)", "tocar para mapear", runDump)
rowInfo(pgP, function()
    return "O script so usa os botoes que o jogo ja tem: procura as cartas da selecao e a marcacao verde e move a marcacao para o proximo objetivo pendente. "
        .. "Ele nao altera probabilidades nem garantias e nao le o contador do Pity. Se nao achar a tela ou nao conseguir confirmar o clique, nao faz nada."
end)

-- ============================================================
-- Pagina: Config
-- ============================================================

local pgC = newPage("config", "Config", "Codigos, diagnostico e opcoes gerais")

rowSwitch(pgC, "Resgatar codigos ao iniciar",
    function() return S.autoCodes end,
    function(v)
        S.autoCodes = v
        saveAll()
    end)
rowInput(pgC, "Nivel minimo (pendentes)",
    function() return S.codesLevel end,
    function(t)
        local n = tonumber(t)
        if n then S.codesLevel = math.clamp(math.floor(n), 1, 999) end
        saveAll()
    end)
rowInfo(pgC, function()
    return "Codigos: " .. CodeStats.last .. "\nAguardando nivel: " .. tostring(pendingCodesCount())
end)
rowButton(pgC, "Resgatar codigos agora", "tocar para executar", function()
    if Machine.state == "SAVING" or Machine.state == "REJOINING" then
        CodeStats.last = "aguarde: salvando/reentrando (" .. Machine.state .. ")"
        Hooks.refresh()
        return
    end
    task.spawn(function()
        runCodes(false)
        Hooks.refresh()
    end)
end)
rowButton(pgC, "Mapear tudo (diagnostico)", "tocar para mapear", runDump)
rowInfo(pgC, function()
    local n = #LogLines
    local first = math.max(1, n - 4)
    local out = {}
    for i = first, n do out[#out + 1] = LogLines[i] end
    return (#out > 0) and table.concat(out, "\n") or "sem registros"
end)
rowConfirmButton(pgC, "Descarregar script", function()
    if _G.ScyFeAutoRollback and _G.ScyFeAutoRollback.Unload then _G.ScyFeAutoRollback.Unload() end
end)

-- ============================================================
-- Ajuda (?)
-- ============================================================

local HELP = {
    { "Alvos", "ALVOS\n\n"
        .. "Na aba Alvos escolha o modo (Estilo ou Habilidade), marque um ou mais personagens na lista e, se o nome nao aparecer, digite em 'Outros' separado por virgula (ex.: Kijo, Tso).\n\n"
        .. "A ordem nao importa: o que vier primeiro e guardado e o script segue atras dos que faltam. Quando todos forem concluidos, ele para.\n\n"
        .. "Se um alvo ja estiver em um dos seus slots, ele e reconhecido e protegido sem gastar spin." },
    { "Slots", "SLOTS\n\n"
        .. "Automatico: o script le os slots e so usa um quando tem certeza de que e seguro (vazio ou com personagem conhecido que nao seja Secret, Ultra ou EVO). Slots bloqueados, protegidos ou com conteudo desconhecido nunca sao usados.\n\n"
        .. "Manual: voce marca exatamente quais slots podem ser usados (1, 2, 3, 4, +). Ele usa so esses.\n\n"
        .. "Atual: nao troca de slot e nao protege nada. Use so se tiver certeza.\n\n"
        .. "Depois de guardar um personagem, o slot fica protegido e nao e reutilizado, mesmo depois de rejoin. Se houver mais objetivos do que slots, o script avisa e para em vez de substituir." },
    { "Automacao", "AUTOMACAO\n\n"
        .. "Iniciar e Parar ficam no Dashboard. Com 'Iniciar automaticamente' ligado e o script no autoexec, basta entrar no jogo.\n\n"
        .. "REJOIN: reentra no jogo guardando o que voce ja pegou. E usado quando vem um alvo.\n\n"
        .. "ROLLBACK: reentra desfazendo as acoes. E usado so quando o limite de spins acaba sem vir nenhum alvo da lista.\n\n"
        .. "Depois de qualquer reentrada o autoexec roda o script de novo e ele continua sozinho (por ate 5 minutos), sem repetir o que ja foi concluido. Um resultado so conta como salvo depois de conferido apos o rejoin." },
    { "Pity", "PITY\n\n"
        .. "A marcacao verde indica o personagem favorecido na selecao do jogo. O script procura essa tela e tenta mover a marcacao para o proximo objetivo pendente, so quando consegue confirmar que a marcacao mudou.\n\n"
        .. "Ele nao altera probabilidades nem garantias e nao le o contador do Pity. Eu nao tenho as regras exatas dos 50% e 100% do jogo: consulte a tela do jogo.\n\n"
        .. "Se a selecao nao funcionar, use 'Mapear Pity' na aba Pity e envie o resultado para o script ser ajustado." },
    { "Problemas", "PROBLEMAS\n\n"
        .. "Estado ERROR: leia o motivo no Dashboard.\n\n"
        .. "'recursos indisponiveis': o jogo ainda nao carregou o necessario (remote Roll ou a leitura do estilo). O script tenta 3 vezes (cerca de 2,5 min) antes de parar. Toque em INICIAR para tentar de novo.\n\n"
        .. "'slot ... nao encontrado': use 'Mapear slots' na aba Slots e envie o resultado.\n\n"
        .. "'nao consegui confirmar': o slot foi protegido; confira o personagem no jogo e use 'Liberar slots protegidos' para reutiliza-lo.\n\n"
        .. "Para saber se esta ativo: o Dashboard mostra o Estado e o botao S fica com a borda clara enquanto roda. Registros: console do executor, linhas [ScyFe]." },
}

local Help = newInstance("Frame", {
    Position = UDim2.fromOffset(0, HEADER_H),
    Size = UDim2.new(1, 0, 1, -HEADER_H),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 30,
}, Window)

local HelpTopics = newInstance("ScrollingFrame", {
    Size = UDim2.new(1, 0, 0, TAB_H),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollingDirection = Enum.ScrollingDirection.X,
    ScrollBarThickness = 0,
    ZIndex = 31,
}, Help)
padding(HelpTopics, 10, 10, 0, 0)
newInstance("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 2),
}, HelpTopics)

newInstance("Frame", {
    Position = UDim2.fromOffset(0, TAB_H),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = C.line,
    BorderSizePixel = 0,
    ZIndex = 31,
}, Help)

local HelpBody = newInstance("ScrollingFrame", {
    Position = UDim2.fromOffset(0, TAB_H + 1),
    Size = UDim2.new(1, 0, 1, -(TAB_H + 1)),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = C.line2,
    ZIndex = 31,
}, Help)
padding(HelpBody, 16, 16, 12, 16)

local HelpText = newInstance("TextLabel", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 12,
    TextColor3 = C.sub,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextWrapped = true,
    Text = "",
    ZIndex = 32,
}, HelpBody)

local helpTabs = {}
local function showHelpTopic(idx)
    HelpText.Text = HELP[idx][2]
    HelpBody.CanvasPosition = Vector2.new(0, 0)
    for i, t in pairs(helpTabs) do
        t.btn.TextColor3 = (i == idx) and C.text or C.sub
        t.bar.Visible = (i == idx)
    end
end

local function makeTabButton(parent, label, order, onClick)
    local btn = newInstance("TextButton", {
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = C.sub,
        Text = label,
        AutoButtonColor = false,
        LayoutOrder = order,
        ZIndex = 32,
    }, parent)
    padding(btn, 10, 10, 0, 0)
    local bar = newInstance("Frame", {
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 10, 1, 0),
        Size = UDim2.new(1, -20, 0, 2),
        BackgroundColor3 = C.text,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 33,
    }, btn)
    track(btn.MouseButton1Click:Connect(onClick))
    return { btn = btn, bar = bar }
end

for i, topic in ipairs(HELP) do
    helpTabs[i] = makeTabButton(HelpTopics, topic[1], i, function() showHelpTopic(i) end)
end

local currentPage = "dash"

local function setHelp(v)
    Help.Visible = v
    if v then
        TitleLabel.Text = "Ajuda"
        DescLabel.Text = "Como usar cada parte do script"
        HelpBtn.TextColor3 = C.text
        showHelpTopic(1)
    else
        HelpBtn.TextColor3 = C.sub
        TitleLabel.Text = Pages[currentPage].title
        DescLabel.Text = Pages[currentPage].desc
    end
end
track(HelpBtn.MouseButton1Click:Connect(function() setHelp(not Help.Visible) end))

-- ============================================================
-- Abas
-- ============================================================

local TAB_ORDER = { "dash", "targets", "slots", "auto", "pity", "config" }
local TAB_LABEL = {
    dash = "Dashboard", targets = "Alvos", slots = "Slots", auto = "Automacao", pity = "Pity", config = "Config",
}
local tabButtons = {}
local lastSlotScan = 0

local function showPage(key)
    currentPage = key
    for k, pg in pairs(Pages) do pg.frame.Visible = (k == key) end
    for k, t in pairs(tabButtons) do
        t.btn.TextColor3 = (k == key) and C.text or C.sub
        t.bar.Visible = (k == key)
    end
    if Help.Visible then setHelp(false) end
    TitleLabel.Text = Pages[key].title
    DescLabel.Text = Pages[key].desc
    Hooks.refresh()
end

for i, key in ipairs(TAB_ORDER) do
    tabButtons[key] = makeTabButton(TabBar, TAB_LABEL[key], i, function() showPage(key) end)
end

-- ============================================================
-- Atualizacao da GUI
-- ============================================================

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

task.spawn(function()
    while not superseded() do
        task.wait(0.4)
        if guiVisible or refreshPending then
            if guiVisible and currentPage == "slots" and os.clock() - lastSlotScan > 4 then
                lastSlotScan = os.clock()
                pcall(refreshSlotCache)
            end
            refreshNow()
        end
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
    Start = function() return startSession() end,
    Stop = function() stopSession("parado pela API") end,
    State = S,
    Machine = Machine,
    Gui = ScreenGui,
    Unload = unload,
}

pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "ScyFe Auto Rollback",
        Text = "Carregado. RightShift ou botao S abre/fecha.",
        Duration = 4,
    })
end)
log("v3 carregado. RightShift ou botao S abre/fecha o menu.")

startBackground()

local function shouldResume()
    local p = P()
    return p.resume == true and (os.time() - (tonumber(p.resumeAt) or 0)) < 300
end

setState("IDLE", "aguardando")

-- Codigos na inicializacao (independe da automacao de giro)
if S.autoCodes then
    task.spawn(function()
        if not superseded() then codesStartup() end
    end)
end

local resume = shouldResume()
if resume or (S.autoStart and not P().huntDone) then
    task.spawn(function()
        task.wait(1.5)
        if not superseded() and not Session.active then
            log(resume and "retomando apos reentrada" or "iniciando automaticamente")
            startSession()
        end
    end)
elseif S.autoStart and P().huntDone then
    setState("IDLE", "objetivos ja concluidos (use Resetar progresso para repetir)")
end
