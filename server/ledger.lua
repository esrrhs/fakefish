package "Ledger"

-- SQLite 事件流水账本：进场(enter) / 完全击杀(kill) / 金币雨(feast)。
-- sqlite 模块全部同步操作，可安全用于 WS recv 回调上下文（game.enter 在该上下文 emit）。
-- db / stmt 为 NativeObject（userdata），存文件级 upvalue 不受 const 限制；
-- 热更只替换函数地址，预处理语句对象依然有效。

local db = nil
local insert_stmt = nil
local ready = nil        -- 运行时标记表 { ok = bool }（避免文件级 bool 常量问题，直接用 nil 判断）

local SCHEMA_SQL =
"CREATE TABLE IF NOT EXISTS events ("
.. "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
.. "  ts INTEGER NOT NULL,"
.. "  type TEXT NOT NULL,"
.. "  player_id INTEGER,"
.. "  name TEXT,"
.. "  detail TEXT"
.. ")"

-- 事件类型白名单（查询参数防注入：只允许这三类）
local known_types = { enter = true, kill = true, feast = true }

function init(cfg)
    if cfg == nil then cfg = {} end
    if cfg["enabled"] == false then
        print("[Ledger] disabled by config (ledger.enabled=false)")
        return
    end

    local path = cfg["path"] or "data/events.db"

    -- 确保数据目录存在（os.mkdir 对已存在目录返回 false，忽略即可）
    local dir = os.dirname(path)
    if dir ~= nil and dir ~= "" and dir ~= "." then
        os.mkdir(dir)
    end

    local ok, res = pcall(function() return sqlite.open(path) end)
    if not ok or res == nil then
        print("[Ledger] sqlite open failed, ledger disabled: " .. tostring(res))
        return
    end
    db = res

    -- WAL：允许多实例（如 test_persist 拉起的第二个服务器）并发读写同一账本；
    -- busy_timeout 让写锁竞争时等待而不是立刻报 database is locked
    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA busy_timeout=3000") end)

    local ok2, err2 = pcall(function() db:exec(SCHEMA_SQL) end)
    if not ok2 then
        print("[Ledger] schema init failed, ledger disabled: " .. tostring(err2))
        pcall(function() db:close() end)
        db = nil
        return
    end

    local ok3, stmt = pcall(function()
        return db:prepare("INSERT INTO events (ts, type, player_id, name, detail) VALUES (?, ?, ?, ?, ?)")
    end)
    if not ok3 or stmt == nil then
        print("[Ledger] prepare insert failed, ledger disabled: " .. tostring(stmt))
        pcall(function() db:close() end)
        db = nil
        return
    end
    insert_stmt = stmt

    -- 事件总线订阅（init 一次；函数热更后按名解析自动命中新版）
    event.on("game.enter", "Ledger.on_ev_enter")
    event.on("game.eat", "Ledger.on_ev_eat")
    event.on("game.feast", "Ledger.on_ev_feast")

    print("[Ledger] SQLite event ledger ready at " .. path)
end

function is_ready()
    return db ~= nil and insert_stmt ~= nil
end

-- 通用落账（event 处理器共用）。同步写入；失败仅打印，不影响游戏主链路。
local function record(ev_type, player_id, name, detail)
    if not is_ready() then return end
    local ok, err = pcall(function()
        insert_stmt:bind(os.time(), ev_type, player_id, name, detail)
        insert_stmt:step()
        insert_stmt:reset()
    end)
    if not ok then
        print("[Ledger] insert failed: " .. tostring(err))
    end
end

-- 进场：is_bot=1 记机器人，0 记真人玩家
function on_ev_enter(pid, name, is_bot)
    local who = "player"
    if is_bot == 1 then who = "bot" end
    record("enter", pid, name, who)
end

-- 吞噬：只把完全淘汰记为 kill（部分吞噬高频，不进账本）
function on_ev_eat(eater_id, victim_id, gold, kind)
    if kind ~= "full" then return end
    local nm = World.get_name_by_id(eater_id)
    local detail = nil
    local ok, enc = pcall(function()
        return json.encode({ victim = victim_id, gold = gold })
    end)
    if ok then detail = enc end
    record("kill", eater_id, nm, detail)
end

function on_ev_feast(x, y, count)
    local detail = nil
    local ok, enc = pcall(function()
        return json.encode({ x = x, y = y, count = count })
    end)
    if ok then detail = enc end
    record("feast", nil, nil, detail)
end

-- 查询最近事件（HTTP /api/events）。
-- kind 仅接受白名单值；limit 钳制为 1..100 整数。
-- 返回 1-based 行表，每行 { id, ts, type, player_id, name, detail }
function query_events(limit, kind)
    local out = {}
    if not is_ready() then return out end

    -- 入参是多态类型，直接 math.floor 会触发 fakelua
    -- "function call cannot be specialized as numeric" 代码生成错误，
    -- 先经 tonumber 固定为数值局部（与 http_static.parse_rank_limit 同款）
    local lim = tonumber(limit)
    if lim == nil or lim ~= lim then lim = 20 end
    lim = math.floor(lim)
    if lim < 1 then lim = 1 end
    if lim > 100 then lim = 100 end

    local use_kind = nil
    if kind ~= nil and known_types[tostring(kind)] == true then
        use_kind = tostring(kind)
    end

    local sql
    if use_kind ~= nil then
        -- type 为白名单常量拼接，安全；lim 为钳制后的整数
        sql = "SELECT id, ts, type, player_id, name, detail FROM events"
              .. " WHERE type = '" .. use_kind .. "' ORDER BY id DESC LIMIT " .. tostring(lim)
    else
        sql = "SELECT id, ts, type, player_id, name, detail FROM events"
              .. " ORDER BY id DESC LIMIT " .. tostring(lim)
    end

    local ok, rows = pcall(function() return db:exec(sql) end)
    if not ok or rows == nil then return out end

    -- db:exec 的 SELECT 结果：每行按列名索引（stmt:step 同款）
    for i = 1, #rows do
        local r = rows[i]
        table.insert(out, {
            id = tonumber(r["id"]) or 0,
            ts = tonumber(r["ts"]) or 0,
            type = tostring(r["type"]),
            player_id = tonumber(r["player_id"]),
            name = r["name"] ~= nil and tostring(r["name"]) or nil,
            detail = r["detail"] ~= nil and tostring(r["detail"]) or nil
        })
    end
    return out
end
