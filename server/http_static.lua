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
function on_request(typ, connid, req)
    if typ ~= "request" then return end

    local path = req["path"] or "/"
    if path == "/" or path == "" then
        path = "/index.html"
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
