package "Motd"

-- 登录公告（Message of the day）：
-- 文本持久化在 data/motd.txt（io.open 原子写：先写 .tmp 再 os.rename），
-- 启动时读入内存；登录成功时随 login_ok 下发，GET /api/motd 可匿名查询，
-- POST /api/admin/motd（hotfix_token 鉴权）更新。
-- 长度按 UTF-8 字符计（复用 Phase 16 的 utf8 模块，非法字节直接拒绝）。

local path = nil
local max_len = nil
local text = nil

local function ensure_dir(p)
    local dir = os.dirname(p)
    if dir ~= nil and dir ~= "" and dir ~= "." then
        os.mkdir(dir)
    end
end

function init(cfg)
    if cfg ~= nil and cfg["enabled"] == false then
        print("[Motd] disabled by config (motd.enabled=false)")
        return
    end

    path = (cfg and cfg["path"]) or "data/motd.txt"

    local ml = tonumber(cfg and cfg["max_len"])
    if ml == nil or ml ~= ml then ml = 200 end
    ml = math.floor(ml)
    if ml < 1 then ml = 1 end
    if ml > 1000 then ml = 1000 end
    max_len = ml

    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if type(content) == "string" then
            -- 去掉行尾换行（文件落盘自带结尾换行是正常写法）
            content = string.gsub(content, "[\r\n]+$", "")
            if content ~= "" then text = content end
        end
    end

    if text ~= nil then
        print("[Motd] loaded (" .. tostring(utf8.len(text)) .. " chars) from " .. path)
    else
        print("[Motd] no announcement at " .. path)
    end
end

function is_ready()
    return path ~= nil
end

function get()
    return text
end

function max_chars()
    return max_len
end

-- 校验并更新公告：t 为非空字符串则写入，为 nil 则清除；成功返回 true，
-- 失败返回 false, 原因字符串
function set(t)
    if path == nil then return false, "motd disabled" end

    if t == nil then
        text = nil
        pcall(function() os.remove(path) end)
        return true
    end

    if type(t) ~= "string" then return false, "motd must be a string" end

    -- 不允许 CR / 其他控制字符（换行/制表符除外）
    if string.find(t, "\r", 1, true) ~= nil then
        return false, "CR characters are not allowed"
    end
    local clean = string.gsub(t, "[\n\t]", "")
    if string.find(clean, "%c") ~= nil then
        return false, "control characters are not allowed"
    end

    local n = utf8.len(clean)
    if n == nil then return false, "invalid UTF-8 sequence" end
    if n < 1 then return false, "motd is empty" end
    if n > max_len then
        return false, "motd too long: " .. tostring(n) .. " > " .. tostring(max_len)
    end

    ensure_dir(path)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "cannot open temp file for write" end
    f:write(clean)
    f:write("\n")
    f:close()

    local ok, err = pcall(function() os.rename(tmp, path) end)
    if not ok then
        pcall(function() os.remove(tmp) end)
        return false, "rename failed: " .. tostring(err)
    end

    text = clean
    return true
end

-- ---- 帧边界持久化 ----
function persist()
    Store.set("motd.path", path)
    Store.set("motd.max_len", max_len)
    Store.set("motd.text", text)
end

function restore()
    path = Store.get("motd.path")
    max_len = Store.get("motd.max_len")
    text = Store.get("motd.text")
end
