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

local function parse_limit(query)
    local limit = 10
    if query ~= nil then
        local pos = string.find(query, "limit=")
        if pos ~= nil then
            local raw = string.sub(query, pos + 6)
            local num = string.match(raw, "^%d+")
            if num ~= nil then
                limit = tonumber(num) or 10
            end
        end
    end
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
        local limit = parse_limit(req["query"])
        local top = DB.get_top(limit)
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
