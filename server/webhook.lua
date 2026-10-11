package "Webhook"

-- 出站事件 Webhook：把完全击杀 / 金币雨事件异步 POST 到配置的 URL。
-- 基于 fakelua http.request（Boost.Beast，runtime.tick 驱动）。
-- url 留空 = 关闭；请求全程异步，回调仅记日志，绝不阻塞/影响游戏主链路。
-- 注意：fakelua 所有 native 异步回调只接受【具名包内函数名】字符串。

local hook_url = nil       -- 非空字符串即启用
local timeout_ms = nil
local events_on = nil      -- 运行时 table： { kill=true, feast=true }
local seq = nil            -- 自增序号（便于接收端去重/排序）

function init(cfg)
    seq = 0
    events_on = {}
    if cfg == nil then cfg = {} end

    hook_url = cfg["url"]
    if hook_url == nil or hook_url == "" then
        print("[Webhook] disabled (no webhook.url configured)")
        return
    end

    timeout_ms = cfg["timeout_ms"] or 3000

    -- events 支持 yaml 数组（- kill）或逗号分隔字符串；默认只推击杀
    local ev = cfg["events"]
    if type(ev) == "table" then
        for i = 1, #ev do
            events_on[tostring(ev[i])] = true
        end
    elseif type(ev) == "string" and ev ~= "" then
        for _, name in ipairs(string.split(ev, ",")) do
            local key = string.trim(name)
            if key ~= "" then events_on[key] = true end
        end
    else
        events_on["kill"] = true
    end

    event.on("game.eat", "Webhook.on_ev_eat")
    event.on("game.feast", "Webhook.on_ev_feast")
    print("[Webhook] enabled -> " .. hook_url .. " (timeout " .. tostring(timeout_ms) .. "ms)")
end

-- 发起一次 POST（主循环上下文调用：game.eat/feast 均在主循环 emit）
local function dispatch(ev_type, data_tbl)
    if hook_url == nil or hook_url == "" then return end
    seq = seq + 1
    local payload = nil
    local ok, enc = pcall(function()
        return json.encode({
            seq = seq,
            ts = os.time(),
            event = ev_type,
            data = data_tbl
        })
    end)
    if not ok then
        print("[Webhook] payload encode failed: " .. tostring(enc))
        return
    end
    payload = enc

    local req_ok, req_err = pcall(function()
        http.request({
            method = "POST",
            url = hook_url,
            headers = { ["Content-Type"] = "application/json" },
            body = payload,
            timeout_ms = timeout_ms
        }, "Webhook.on_result")
    end)
    if not req_ok then
        print("[Webhook] request launch failed: " .. tostring(req_err))
    end
end

-- 完全淘汰才外发（partial 吞噬太高频）
function on_ev_eat(eater_id, victim_id, gold, kind)
    if kind ~= "full" then return end
    if events_on["kill"] ~= true then return end
    dispatch("kill", {
        eater_id = eater_id,
        eater_name = World.get_name_by_id(eater_id),
        victim_id = victim_id,
        gold = gold
    })
end

function on_ev_feast(x, y, count)
    if events_on["feast"] ~= true then return end
    dispatch("feast", { x = x, y = y, count = count })
end

-- http.request 完成回调（C++ 派发上下文）：只记日志
function on_result(req, err, resp)
    if err ~= nil then
        print("[Webhook] delivery failed: " .. tostring(err))
    elseif resp ~= nil then
        print("[Webhook] delivered, status=" .. tostring(resp["status"]))
    end
end
