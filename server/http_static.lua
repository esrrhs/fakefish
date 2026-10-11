package "HttpStatic"

local http_srv = nil
local web_dir = "web"
local mime_types = {
    [".html"] = "text/html; charset=utf-8",
    [".css"] = "text/css; charset=utf-8",
    [".js"] = "application/javascript; charset=utf-8",
    [".json"] = "application/json",
    [".png"] = "image/png",
    [".jpg"] = "image/jpeg",
    [".svg"] = "image/svg+xml"
}

function get_mime(path)
    local ext = os.extension(path)
    if ext ~= nil and mime_types[ext] ~= nil then
        return mime_types[ext]
    end
    return "text/plain; charset=utf-8"
end

function read_file(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- HTTP 请求派发函数（C++ 回调入口）
-- 注意：回调上下文只能读模块状态、构造新表，不能写模块级 upvalue
function on_request(typ, connid, req)
    if typ ~= "request" then return end
    return dispatch_request(req)
end

function dispatch_request(req)
    local path = req["path"] or "/"
    if path == "/" or path == "" then
        path = "/index.html"
    end

    -- JSON API 路由（"/api/stats" → action "stats"）
    local prefix = string.sub(path, 1, 5)
    if prefix == "/api/" then
        return handle_api(string.sub(path, 6), req)
    end

    -- 防止目录穿越
    if string.find(path, "%.%.") ~= nil then
        return {
            status = 403,
            body = "Forbidden"
        }
    end

    local local_file = web_dir .. path
    local content = read_file(local_file)

    if content ~= nil then
        local mime = get_mime(local_file)
        return {
            status = 200,
            headers = {
                ["Content-Type"] = mime,
                ["Cache-Control"] = "no-cache"
            },
            body = content
        }
    else
        return {
            status = 404,
            headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
            body = "404 Not Found: " .. path
        }
    end
end

-- ---- JSON API ----
-- 说明：返回的 JSON 为手工拼接。账号名已限制为 [A-Za-z0-9_]、机器人名为内置固定表，
-- 均不含需转义字符；且规避了 fakelua json.encode 空 table 产出 {} 而非 [] 的问题。

local function api_json(status, body)
    return {
        status = status,
        headers = {
            ["Content-Type"] = "application/json; charset=utf-8",
            ["Cache-Control"] = "no-cache",
            ["Access-Control-Allow-Origin"] = "*"
        },
        body = body
    }
end

-- 用 fakelua url 模块解析 query string（百分号解码 + 参数表）
local function parse_query(query)
    if query == nil or query == "" then return {} end
    local ok, params = pcall(function() return url.decode_query(query) end)
    if not ok or type(params) ~= "table" then return {} end
    return params
end

-- rank 的 limit：非数值/NaN 默认 10、小数向下取整、钳到 1-20
local function parse_rank_limit(params)
    local limit = tonumber(params["limit"])
    if limit == nil or limit ~= limit then limit = 10 end
    limit = math.floor(limit)
    if limit < 1 then limit = 1 end
    if limit > 20 then limit = 20 end
    return limit
end

local function handle_api(action, req)
    -- CORS 预检
    if req["method"] == "OPTIONS" then
        return {
            status = 204,
            headers = {
                ["Access-Control-Allow-Origin"] = "*",
                ["Access-Control-Allow-Methods"] = "GET, OPTIONS"
            },
            body = ""
        }
    end

    if action == "rank" or action == "rank/" then
        local params = parse_query(req["query"])
        local limit = parse_rank_limit(params)
        -- scope=global 取 Redis ZSET 镜像的跨服全局榜（Redis 未启用时自动回退本服榜）
        local top
        if params["scope"] == "global" then
            top = RedisStore.global_top(limit)
        else
            top = DB.get_top(limit)
        end
        local parts = {}
        for i = 1, #top do
            local e = top[i]
            table.insert(parts, '{"name":"' .. tostring(e.name)
                .. '","best_gold":' .. tostring(e.best_gold)
                .. ',"kills":' .. tostring(e.kills or 0) .. '}')
        end
        local body = '{"code":0,"count":' .. tostring(#top) .. ',"list":['
                      .. table.concat(parts, ",") .. "]}"

        return api_json(200, body)
    end

    if action == "stats" or action == "stats/" then
        local st = World.get_stats()
        local body = '{"code":0,"online":' .. tostring(st.online)
                     .. ',"bots":' .. tostring(st.bots)
                     .. ',"uptime_s":' .. tostring(st.uptime_s)
                     .. ',"map":{"width":' .. tostring(st.map_width)
                     .. ',"height":' .. tostring(st.map_height) .. "}}"
        return api_json(200, body)
    end

    if action == "rank.csv" then
        -- 排行榜 CSV 导出（fakelua csv.encode 自动处理逗号/引号转义）
        local params = parse_query(req["query"])
        local limit = parse_rank_limit(params)
        local top = DB.get_top(limit)
        local rows = { { "rank", "name", "best_gold", "kills" } }
        for i = 1, #top do
            local e = top[i]
            table.insert(rows, { i, tostring(e.name), e.best_gold, e.kills or 0 })
        end
        local ok, csv_body = pcall(function() return csv.encode(rows) end)
        if not ok then
            return api_json(500, '{"code":500,"msg":"csv encode failed"}')
        end
        return {
            status = 200,
            headers = {
                ["Content-Type"] = "text/csv; charset=utf-8",
                ["Cache-Control"] = "no-cache",
                ["Access-Control-Allow-Origin"] = "*"
            },
            body = csv_body
        }
    end

    if action == "events" or action == "events/" then
        -- SQLite 事件流水：?limit=1..100&type=enter|kill|feast
        -- detail 是入库时的内嵌 JSON 字符串，整条响应用 json.encode，
        -- 字符串中的引号会被正确转义，客户端可再对 detail 做一次 JSON.parse
        local params = parse_query(req["query"])
        local limit = tonumber(params["limit"])
        if limit == nil or limit ~= limit then limit = 20 end
        limit = math.floor(limit)
        if limit < 1 then limit = 1 end
        if limit > 100 then limit = 100 end

        local rows = Ledger.query_events(limit, params["type"])
        local body = json.encode({ code = 0, count = #rows, list = rows })
        return api_json(200, body)
    end

    return api_json(404, '{"code":404,"msg":"unknown api"}')
end

function init(cfg)
    if cfg == nil then cfg = {} end
    local port = cfg["http_port"] or 8080
    web_dir = cfg["web_dir"] or "web"

    local srv_cfg = {
        ip = "0.0.0.0",
        port = port
    }

    local ok, srv = pcall(function() return http.server(srv_cfg) end)
    if not ok or not srv then
        print("[HttpStatic] Failed to start HTTP static server on port " .. tostring(port) .. ": " .. tostring(srv))
        return false
    end

    http_srv = srv
    http_srv:dispatch("HttpStatic.on_request")

    print("[HttpStatic] HTTP server running on http://127.0.0.1:" .. tostring(port) .. " (serving " .. web_dir .. "/)")
    return true
end
