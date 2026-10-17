package "Config"

local config_data = {}

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

    config_data = parsed
    -- 立刻落库：init 帧内各模块（DB.init 等）马上就要读配置，等帧末 persist 就晚了
    Store.set_json("config.data", parsed)
    return true
end

-- 配置在 init 帧解析后随 arena 一起消亡，因此落一份到 Store。运行期读取走
-- 「帧内缓存 + 首次访问解码」：同一帧内多次 get 只解码一次，跨帧自动重新解码。
local frame_cache = nil

function get()
    if frame_cache == nil then
        frame_cache = Store.get_json("config.data")
        if frame_cache == nil then frame_cache = {} end
    end
    return frame_cache
end

function persist()
    -- 只回写「本帧真的解码过」的那份。config_data 是文件级 local，跨帧后是一个
    -- 悬垂但非 nil 的指针，拿它做 ~= nil 判断会误判为真，随后 encode 一张已经
    -- 被 arena 回收的表直接段错误（第一帧就崩在这里）。
    if frame_cache ~= nil then
        Store.set_json("config.data", frame_cache)
    end
end

function restore()
    -- 清掉上一帧的悬垂指针与帧内缓存；真正的解码推迟到本帧第一次 get
    config_data = nil
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
