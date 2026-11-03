package "Config"

function load(path)
    if path == nil or path == "" then
        path = "config.yaml"
    end

    local f = io.open(path, "r")
    if not f then
        f = io.open("config.example.yaml", "r")
        if not f then
            print("[Config] Could not open config file: " .. path)
            return false
        end
        print("[Config] Loaded default fallback: config.example.yaml")
    else
        print("[Config] Loaded config file: " .. path)
    end

    local content = f:read("*a")
    f:close()

    local parsed = yaml.decode(content)
    if not parsed then
        print("[Config] YAML parse failed!")
        return false
    end

    -- 立刻落库：init 帧内各模块（DB.init 等）马上就要读配置，等帧末 persist 就晚了
    -- 不在文件级 local 上缓存：用 {} 初始化的文件级变量会被 fakelua 标成常量，
    -- 重新赋值会编译失败（cannot reassign file-level constant）。
    Store.set_json("config.data", parsed)
    return true
end

-- 配置在 init 帧解析后随 arena 一起消亡，因此落一份到 Store。运行期读取走
-- 「帧内缓存 + 首次访问解码」：同一帧内多次 get 只解码一次，跨帧自动重新解码。
-- frame_cache 以 nil 起声明（非 {}），因此允许每帧重赋值。
local frame_cache = nil

function get()
    if frame_cache == nil then
        frame_cache = Store.get_json("config.data")
        if frame_cache == nil then frame_cache = {} end
    end
    return frame_cache
end

function persist()
    -- 只回写「本帧真的解码过」的那份；未访问则无需 encode。
    if frame_cache ~= nil then
        Store.set_json("config.data", frame_cache)
    end
end

function restore()
    -- 清掉上一帧的帧内缓存；真正的解码推迟到本帧第一次 get
    frame_cache = nil
end

function get_server()
    local d = get()
    if d["server"] == nil then d["server"] = {} end
    return d["server"]
end

function get_mysql()
    local d = get()
    if d["mysql"] == nil then d["mysql"] = {} end
    return d["mysql"]
end

function get_game()
    local d = get()
    if d["game"] == nil then d["game"] = {} end
    return d["game"]
end
