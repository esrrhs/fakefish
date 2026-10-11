package "HttpStatic"

local http_srv = nil
local web_dir = "web"
local pbf_ready = nil

-- 小于该字节数的响应不做 gzip（压缩收益不抵开销）
local gzip_min_bytes = 128

-- /api/world.pbf 的 protobuf3 模式（运行时 load，与 encode 同 State 注册）
local PBF_SCHEMA = [[
syntax = "proto3";
message PlayerCell {
    int64 id = 1;
    int32 cell = 2;
    string name = 3;
    double x = 4;
    double y = 5;
    int64 gold = 6;
    double r = 7;
    bool bot = 8;
    string fx = 9;
}
message WorldSnapshot {
    repeated PlayerCell players = 1;
    int32 online = 2;
    int32 bots = 3;
    int64 ts = 4;
    int32 map_width = 5;
    int32 map_height = 6;
}
]]

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

-- 大小写不敏感取 header
local function header_get_ci(headers, name)
    if type(headers) ~= "table" then return nil end
    local want = string.lower(name)
    for k, v in pairs(headers) do
        if string.lower(tostring(k)) == want then return v end
    end
    return nil
end

-- 解析 Accept-Encoding 是否接受 gzip（支持 q=0 拒绝）
local function accepts_gzip(req)
    local ae = header_get_ci(req["headers"], "accept-encoding")
    if type(ae) ~= "string" then return false end
    for part in string.gmatch(ae, "[^,]+") do
        local token = string.trim(part)
        local name_part = token
        local q = 1.0
        local semi = string.find(token, ";", 1, true)
        if semi ~= nil then
            name_part = string.trim(string.sub(token, 1, semi - 1))
            local qv = string.match(string.sub(token, semi + 1), "q=([0-9%.]+)")
            local qn = tonumber(qv)
            if qn ~= nil then q = qn end
        end
        if string.lower(name_part) == "gzip" and q > 0 then return true end
    end
    return false
end

-- 出站 gzip 协商（fakelua compress.gzip_compress）：
-- 仅压缩 200、够大、非图片、客户端声明接受 gzip 的响应；任何异常静默回退原文
local function maybe_compress(req, resp)
    if type(resp) ~= "table" then return resp end
    if resp["status"] ~= 200 then return resp end
    local body = resp["body"]
    if type(body) ~= "string" or #body < gzip_min_bytes then return resp end
    local ct = header_get_ci(resp["headers"], "content-type")
    if type(ct) == "string" and string.sub(string.lower(ct), 1, 6) == "image/" then
        return resp
    end
    if not accepts_gzip(req) then return resp end

    local ok, z = pcall(function() return compress.gzip_compress(body) end)
    if not ok or type(z) ~= "string" or #z == 0 then return resp end

    if type(resp["headers"]) ~= "table" then
        resp["headers"] = {}
    end
    resp["headers"]["Content-Encoding"] = "gzip"
    resp["headers"]["Vary"] = "Accept-Encoding"
    resp["body"] = z
    return resp
end

-- HTTP 请求派发函数（C++ 回调入口）
-- 注意：回调上下文只能读模块状态、构造新表，不能写模块级 upvalue
function on_request(typ, connid, req)
    if typ ~= "request" then return end
    local resp = dispatch_request(req)
    return maybe_compress(req, resp)
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

-- 递归深比较（serialize 自检用）
local function deep_eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- serialize 模块二进制/text 往返自检
local function codec_selftest()
    local sample = {
        s = "hello世界",
        n = 42,
        f = 3.5,
        b = true,
        arr = { 1, 2, 3 },
        nested = { k = "v", n = 7 }
    }

    local ok_bin, bin = pcall(function() return serialize.encode(sample) end)
    if not ok_bin or type(bin) ~= "string" then
        return api_json(500, '{"code":500,"ok":false,"stage":"encode","msg":'
            .. json.encode({ tostring(bin) }) .. "}")
    end
    local ok_dec, back = pcall(function() return serialize.decode(bin) end)
    local bin_equal = ok_dec and deep_eq(sample, back) or false

    local ok_txt, txt = pcall(function() return serialize.text_encode(sample) end)
    local txt_equal = false
    local txt_len = 0
    if ok_txt and type(txt) == "string" then
        txt_len = #txt
        local ok_tdec, tback = pcall(function() return serialize.text_decode(txt) end)
        txt_equal = ok_tdec and deep_eq(sample, tback) or false
    end

    local all_ok = (bin_equal and txt_equal)
    return api_json(200, json.encode({
        code = 0,
        ok = all_ok,
        bin_equal = bin_equal,
        text_equal = txt_equal,
        bin_len = #bin,
        text_len = txt_len
    }))
end

-- 管理接口分发（POST + hotfix_token 鉴权）
local function handle_admin(what, req)
    if req["method"] ~= "POST" then
        return api_json(405, '{"code":405,"msg":"POST required"}')
    end

    local ok_body, params = pcall(function() return json.decode(req["body"] or "") end)
    if not ok_body or type(params) ~= "table" then
        return api_json(400, '{"code":400,"msg":"invalid JSON body"}')
    end
    if not Admin.check_token(params["token"]) then
        return api_json(403, '{"code":403,"msg":"bad token"}')
    end

    if what == "run" then
        local rok, res = Admin.run(params["cmd"])
        if not rok then
            return api_json(400, json.encode({ code = 400, msg = res }))
        end
        return api_json(200, json.encode({
            code = 0,
            stdout = res.stdout,
            stderr = res.stderr,
            exit = res.code
        }))
    end

    if what == "motd" then
        local m = params["motd"]
        if m ~= nil and type(m) ~= "string" then
            return api_json(400, '{"code":400,"msg":"motd must be a string"}')
        end
        local ok_set, err_set = Motd.set(m)
        if not ok_set then
            return api_json(400, json.encode({ code = 400, msg = err_set }))
        end
        return api_json(200, '{"code":0}')
    end

    return api_json(404, '{"code":404,"msg":"unknown admin action"}')
end

-- protobuf3 二进制世界快照
local function world_snapshot_pbf()
    if pbf_ready ~= true then
        return api_json(503, '{"code":503,"msg":"protobuf schema not loaded"}')
    end

    local players = World.get_snapshot()
    local st = World.get_stats()
    local cells = {}
    for i = 1, #players do
        local e = players[i]
        local cell = {
            id = e.id,
            cell = e.cell,
            name = e.name,
            x = e.x,
            y = e.y,
            gold = e.gold,
            r = e.r
        }
        if e.bot then cell.bot = true end
        if e.fx ~= nil then cell.fx = e.fx end
        cells[i] = cell
    end

    local ok_enc, bin = pcall(function()
        return protobuf.encode("WorldSnapshot", {
            players = cells,
            online = st.online,
            bots = st.bots,
            ts = os.time(),
            map_width = st.map_width,
            map_height = st.map_height
        })
    end)
    if not ok_enc or type(bin) ~= "string" then
        return api_json(500, '{"code":500,"msg":"protobuf encode failed"}')
    end

    return {
        status = 200,
        headers = {
            ["Content-Type"] = "application/x-protobuf",
            ["Cache-Control"] = "no-cache",
            ["Access-Control-Allow-Origin"] = "*"
        },
        body = bin
    }
end

local function handle_api(action, req)
    -- CORS 预检
    if req["method"] == "OPTIONS" then
        return {
            status = 204,
            headers = {
                ["Access-Control-Allow-Origin"] = "*",
                ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
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

    if action == "feed" or action == "feed/" then
        -- 原生 deque 内存事件 feed：?limit=1..100
        local params = parse_query(req["query"])
        return api_json(200, Feed.recent_json(params["limit"]))
    end

    if action == "world.pbf" then
        -- protobuf3 二进制世界快照
        return world_snapshot_pbf()
    end

    if action == "motd" or action == "motd/" then
        local m = Motd.get()
        local body
        if m == nil then
            body = '{"code":0,"motd":null}'
        else
            body = '{"code":0,"motd":' .. json.encode(m) .. "}"
        end
        return api_json(200, body)
    end

    if action == "codec/selftest" then
        -- serialize 二进制/text 编解码往返自检
        return codec_selftest()
    end

    if action == "admin/run" then
        return handle_admin("run", req)
    end

    if action == "admin/motd" then
        return handle_admin("motd", req)
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

    -- 加载 /api/world.pbf 的 protobuf3 模式（失败不阻断主服务，端点返回 503）
    local ok_pb, pb_res = pcall(function() return protobuf.load(PBF_SCHEMA) end)
    if ok_pb and pb_res == "ok" then
        pbf_ready = true
        print("[HttpStatic] protobuf WorldSnapshot schema loaded")
    else
        pbf_ready = false
        print("[HttpStatic] WARNING: protobuf schema load failed: " .. tostring(pb_res))
    end

    print("[HttpStatic] HTTP server running on http://127.0.0.1:" .. tostring(port) .. " (serving " .. web_dir .. "/)")
    return true
end
