package "Feed"

-- 内存事件 feed：fakelua 原生 container.deque（NativeObject）支撑的有界环形缓冲。
-- 订阅事件总线 game.enter / game.eat / game.feast，保留最近 N 条预编码 JSON，
-- 经 GET /api/feed 对外查询。与 sqlite 账本的区别：纯内存、无落盘开销、热更不丢
-- （deque 是挂在 State 上的 NativeObject，重编译只换函数地址，对象身份保持）。
-- 注意：container 序列容器只能存标量/NativeObject，不能存 Lua table，
-- 因此条目统一存 json.encode 后的字符串。

local dq = nil
local capacity = nil

function init(cfg)
    if cfg ~= nil and cfg["enabled"] == false then
        print("[Feed] disabled by config (feed.enabled=false)")
        return
    end

    local cap = tonumber(cfg and cfg["capacity"])
    if cap == nil or cap ~= cap then cap = 50 end
    cap = math.floor(cap)
    if cap < 1 then cap = 1 end
    if cap > 200 then cap = 200 end
    capacity = cap

    dq = container.deque()

    -- init 只订阅一次；热更后函数按名解析自动命中新版本，无需重复 event.on
    event.on("game.enter", "Feed.on_ev_enter")
    event.on("game.eat", "Feed.on_ev_eat")
    event.on("game.feast", "Feed.on_ev_feast")

    print("[Feed] in-memory event feed ready (capacity=" .. tostring(capacity) .. ")")
end

function is_ready()
    return dq ~= nil
end

-- 压入一条 JSON 字符串并裁剪到容量上限
local function push(entry_json)
    if dq == nil then return end
    dq:push_back(entry_json)
    while dq:size() > capacity do
        dq:pop_front()
    end
end

-- 进场：pid / name / is_bot（0 真人，1 机器人）
function on_ev_enter(pid, name, is_bot)
    if dq == nil then return end
    local ok, s = pcall(function()
        return json.encode({
            ts = os.time(),
            type = "enter",
            player_id = pid,
            name = name,
            bot = (is_bot == 1)
        })
    end)
    if ok then push(s) end
end

-- 吞噬：只收完全击杀（full），partial 太高频
function on_ev_eat(eater_id, victim_id, gold, kind)
    if dq == nil then return end
    if kind ~= "full" then return end
    local ok, s = pcall(function()
        return json.encode({
            ts = os.time(),
            type = "kill",
            eater_id = eater_id,
            eater_name = World.get_name_by_id(eater_id),
            victim_id = victim_id,
            victim_name = World.get_name_by_id(victim_id),
            gold = gold
        })
    end)
    if ok then push(s) end
end

-- 金币雨
function on_ev_feast(x, y, count)
    if dq == nil then return end
    local ok, s = pcall(function()
        return json.encode({
            ts = os.time(),
            type = "feast",
            x = x,
            y = y,
            count = count
        })
    end)
    if ok then push(s) end
end

-- 查询最近 limit 条（旧→新），返回拼好的 JSON 响应体
function recent_json(limit)
    if dq == nil then
        return '{"code":0,"count":0,"capacity":0,"list":[]}'
    end

    local lim = tonumber(limit)
    if lim == nil or lim ~= lim then lim = 20 end
    lim = math.floor(lim)
    if lim < 1 then lim = 1 end
    if lim > 100 then lim = 100 end

    local all = dq:to_table()
    local total = #all
    local from = 1
    if total > lim then from = total - lim + 1 end

    local parts = {}
    for i = from, total do
        -- 条目本身就是 JSON 对象字符串，直接拼进数组
        parts[#parts + 1] = all[i]
    end
    return '{"code":0,"count":' .. tostring(total - from + 1)
        .. ',"total":' .. tostring(total)
        .. ',"capacity":' .. tostring(capacity)
        .. ',"list":[' .. table.concat(parts, ",") .. "]}"
end

-- ---- 热更支持 ----
-- deque 是 State 持有的 NativeObject，快照里原样交出、恢复时挂回 upvalue 即可；
-- 容量是普通数值一并保存。
-- 注意：快照表由旧 .so 代码构造，新代码只能用字符串键走哈希路径访问，
-- 不能写 snap.dq 静态键（spec 访问器在旧 .so，调用即崩，见 hotreload.lua 头注释）。

function hotfix_save()
    local s = {}
    s["dq"] = dq
    s["capacity"] = capacity
    return s
end

function hotfix_restore(s)
    if s == nil then return end
    dq = s["dq"]
    capacity = s["capacity"]
end
