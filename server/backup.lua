package "Backup"

-- 加密世界备份（fakelua 模块组合：compress.zstd + crypto.aes_cbc + base64 + crc32 + uuid
-- + random PCG + io/os 原子写）：
--   data（motd/统计/排行榜/事件/feed）
--     -> json.encode -> zstd_compress(level 3) -> AES-128-CBC（随机 IV，
--     fakelua crypto 绑定当前仅开放 AES-128，故 aes_key 必须 16 字节）
--     -> 信封 {magic,id,ts,reason,iv(base64),crc32(密文),body(base64)} -> json 落盘
--   校验顺序：信封 JSON -> base64 -> CRC32 密文完整性 -> AES 解密 -> zstd -> JSON。
--   任何字节被篡改都会在 CRC32 或解压阶段被检出；备份文件本身不含任何明文业务数据。
-- 恢复仅回写 MOTD（安全、可验证），账号/世界运行态不做覆盖。

local dir = nil
local key = nil
local keep = nil
local rng = nil

-- 定时自动备份（秒）：interval_s 为 nil/0 表示关闭；next_ts 为下次到期时间戳
local interval_s = nil
local next_ts = nil
local last_backup_ts = nil
local last_backup_name = nil

local MAGIC = "FKBK1"
local INNER_MAGIC = "FKBK"
local INNER_VERSION = 1

function init(cfg)
    if cfg == nil then cfg = {} end
    if cfg["enabled"] == false then
        print("[Backup] disabled by config (backup.enabled=false)")
        return
    end

    dir = cfg["dir"] or "data/backups"

    local k = cfg["aes_key"]
    if type(k) ~= "string" or #k ~= 16 then
        print("[Backup] aes_key missing or not exactly 16 bytes (AES-128), backup disabled")
        dir = nil
        return
    end
    key = k

    local kp = tonumber(cfg["keep"])
    if kp == nil or kp ~= kp then kp = 10 end
    kp = math.floor(kp)
    if kp < 1 then kp = 1 end
    if kp > 50 then kp = 50 end
    keep = kp

    os.mkdir(dir)

    -- IV 随机源（PCG，os.time + os.clock 混合播种；IV 无需保密，只需不可预测）
    local seed = math.floor(os.time() + os.clock() * 1000000)
    rng = random.new(seed)

    print("[Backup] encrypted backup vault ready at " .. dir
          .. " (AES-" .. tostring(#key * 8) .. ", keep=" .. tostring(keep) .. ")")

    -- 定时备份周期（默认 0=关闭；钳到 1..86400 秒）
    local iv = tonumber(cfg["interval_s"])
    if iv ~= nil and iv == iv and iv > 0 then
        iv = math.floor(iv)
        if iv > 86400 then iv = 86400 end
        if iv >= 1 then
            interval_s = iv
            next_ts = os.time() + iv
            print("[Backup] scheduled backup every " .. tostring(iv) .. "s")
        end
    end
end

function is_ready()
    return dir ~= nil and key ~= nil
end

-- ---- 定时自动备份调度 ----

-- 动态调整备份周期（0=关闭，允许 1..86400 秒）；调整后倒计时重新开始
function set_interval(sec)
    if not is_ready() then return false, "backup disabled" end
    local v = tonumber(sec)
    if v == nil or v ~= v then return false, "interval_s must be a number" end
    v = math.floor(v)
    if v < 0 or v > 86400 then return false, "interval_s out of range (0..86400)" end
    interval_s = v
    if v > 0 then
        next_ts = os.time() + v
    else
        next_ts = nil
    end
    return true, schedule_status()
end

-- 主循环每秒调用：到期返回 true 并顺延一个周期；
-- 停机/卡住错过多个周期也只补一次，避免恢复后备份风暴
function pop_due()
    if not is_ready() then return false end
    if interval_s == nil or interval_s <= 0 or next_ts == nil then return false end
    if os.time() < next_ts then return false end
    next_ts = os.time() + interval_s
    return true
end

-- 调度与最近备份状态（HTTP status 动作/健康探针用）
function schedule_status()
    local enabled = false
    if interval_s ~= nil and interval_s > 0 then enabled = true end
    local next_in = nil
    if next_ts ~= nil then
        next_in = next_ts - os.time()
        if next_in < 0 then next_in = 0 end
    end
    return {
        enabled = enabled,
        interval_s = interval_s or 0,
        next_in_s = next_in,
        last_ts = last_backup_ts,
        last_name = last_backup_name
    }
end

local function random_iv()
    local parts = {}
    for i = 1, 16 do
        parts[i] = string.char(rng:int(0, 255))
    end
    return table.concat(parts, "")
end

-- 生成一份 16 字节 IV（备份前调用，测试/复用入口）
function new_iv()
    return random_iv()
end

-- 采集当前世界可备份数据（全部走既有只读接口）
local function collect_data()
    local feed_list = nil
    local okf, fj = pcall(function() return json.decode(Feed.recent_json(100)) end)
    if okf and type(fj) == "table" then feed_list = fj["list"] end

    return {
        motd = Motd.get(),
        stats = World.get_stats(),
        rank = DB.get_top(100),
        events = Ledger.query_events(100, nil),
        feed = feed_list
    }
end

-- 原子写文件（先 .tmp 再 rename，同 Motd 模式）
local function atomic_write(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false, "cannot open temp file: " .. tmp end
    f:write(content)
    f:close()
    local ok, err = pcall(function() os.rename(tmp, path) end)
    if not ok then
        pcall(function() os.remove(tmp) end)
        return false, "rename failed: " .. tostring(err)
    end
    return true
end

-- 信封文件名（只允许由服务端生成的形态）
local function name_for(ts, id)
    -- 文件名含完整 uuid：API 返回的完整 id 与其前 8 位短 id 都能唯一定位
    return "backup-" .. tostring(ts) .. "-" .. tostring(id) .. ".fkbk"
end

-- 把外部传入的 id/name 解析成目录内的实际文件名（拒绝任何路径穿越）
local function resolve_name(v)
    if type(v) ~= "string" or v == "" then return nil end
    if string.find(v, "/", 1, true) ~= nil or string.find(v, "\\", 1, true) ~= nil
        or string.find(v, "..", 1, true) ~= nil then
        return nil
    end
    if string.sub(v, -5) == ".fkbk" then return v end
    -- 当作 id（完整 uuid 或 8 位短 id）：扫描唯一匹配
    local files = os.listdir(dir)
    if type(files) ~= "table" then return nil end
    local hit = nil
    for i = 1, #files do
        local fn = files[i]
        if type(fn) == "string" and string.sub(fn, -5) == ".fkbk"
            and string.find(fn, v, 1, true) ~= nil then
            if hit ~= nil then return nil end  -- 非唯一匹配，拒绝歧义
            hit = fn
        end
    end
    return hit
end

local function read_envelope_file(name)
    local path = os.join(dir, name)
    local f = io.open(path, "rb")
    if not f then return nil, "file not found: " .. name end
    local content = f:read("*a")
    f:close()
    local ok, env = pcall(function() return json.decode(content) end)
    if not ok or type(env) ~= "table" then
        return nil, "envelope json corrupt: " .. name
    end
    if env["magic"] ~= MAGIC or type(env["id"]) ~= "string" or type(env["body"]) ~= "string" then
        return nil, "envelope fields invalid: " .. name
    end
    env["_name"] = name
    env["_size"] = #content
    return env
end

-- 完整校验并解密，返回 true, inner(data 表) 或 false, 错误阶段描述
local function open_envelope(env)
    local iv_b64 = env["iv"]
    local body_b64 = env["body"]
    if type(iv_b64) ~= "string" then return false, "iv missing" end

    local ok_iv, iv = pcall(function() return crypto.base64_decode(iv_b64) end)
    if not ok_iv or type(iv) ~= "string" or #iv ~= 16 then
        return false, "iv invalid"
    end
    local ok_b, ct = pcall(function() return crypto.base64_decode(body_b64) end)
    if not ok_b or type(ct) ~= "string" or #ct == 0 then
        return false, "body base64 invalid"
    end

    local crc = tonumber(env["crc"])
    if crc == nil or crypto.crc32(ct) ~= crc then
        return false, "crc32 mismatch (ciphertext tampered or truncated)"
    end

    local ok_d, packed = pcall(function() return crypto.aes_decrypt_cbc(ct, key, iv) end)
    if not ok_d or type(packed) ~= "string" then
        return false, "AES decrypt failed (wrong key or tampered payload)"
    end

    local ok_z, raw = pcall(function() return compress.zstd_decompress(packed) end)
    if not ok_z or type(raw) ~= "string" then
        return false, "zstd decompress failed"
    end

    local ok_j, inner = pcall(function() return json.decode(raw) end)
    if not ok_j or type(inner) ~= "table" then
        return false, "inner json invalid"
    end
    if inner["magic"] ~= INNER_MAGIC or tonumber(inner["version"]) ~= INNER_VERSION then
        return false, "inner magic/version unsupported"
    end
    if inner["id"] ~= env["id"] then
        return false, "envelope/inner id mismatch"
    end
    return true, inner
end

-- 创建备份。reason 可选字符串（<=200 字符）；actor 用于审计。
-- 返回 true, 元数据表；失败 false, 原因
function create(reason, actor)
    if not is_ready() then return false, "backup disabled" end
    if reason ~= nil then
        if type(reason) ~= "string" then return false, "reason must be a string" end
        if #reason > 200 then reason = string.sub(reason, 1, 200) end
    else
        reason = ""
    end

    local id = crypto.uuid()
    local ts = os.time()

    local payload = {
        magic = INNER_MAGIC,
        version = INNER_VERSION,
        id = id,
        ts = ts,
        reason = reason,
        data = collect_data()
    }

    local raw = json.encode(payload)

    local ok_z, packed = pcall(function() return compress.zstd_compress(raw, 3) end)
    if not ok_z or type(packed) ~= "string" then
        return false, "zstd compress failed: " .. tostring(packed)
    end

    local iv = random_iv()
    local ok_e, ct = pcall(function() return crypto.aes_encrypt_cbc(packed, key, iv) end)
    if not ok_e or type(ct) ~= "string" then
        return false, "AES encrypt failed: " .. tostring(ct)
    end

    local name = name_for(ts, id)
    local path = os.join(dir, name)
    local env = {
        magic = MAGIC,
        id = id,
        ts = ts,
        reason = reason,
        iv = crypto.base64_encode(iv),
        crc = crypto.crc32(ct),
        body = crypto.base64_encode(ct)
    }

    local okw, werr = atomic_write(path, json.encode(env))
    if not okw then return false, werr end

    prune()
    last_backup_ts = ts
    last_backup_name = name
    pcall(function() Audit.record("backup.create", name, reason, actor) end)
    pcall(function() log.info("[backup] created " .. name .. " (" .. tostring(#ct) .. " bytes ciphertext)") end)
    print("[Backup] created " .. name)
    return true, { id = id, name = name, ts = ts, cipher_bytes = #ct }
end

-- 列出备份（新→旧），只读信封头，不做解密；坏文件标 corrupt=true
-- fakelua 的关系运算符对字符串按算术处理（字符串参与 > 会抛
-- "attempt to perform arithmetic on non-numeric value"，不能依赖 Lua 的字符串字典序），
-- 故同秒备份的 tiebreak 用逐字节数值比较
local function name_greater(x, y)
    local nx = #x
    local ny = #y
    local n = math.min(nx, ny)
    local i = 1
    while i <= n do
        local bx = string.byte(x, i)
        local by = string.byte(y, i)
        if bx ~= by then return bx > by end
        i = i + 1
    end
    return nx > ny
end

function list_backups()
    local out = {}
    if not is_ready() then return out end
    local files = os.listdir(dir)
    if type(files) ~= "table" then return out end

    for i = 1, #files do
        local fn = files[i]
        if type(fn) == "string" and string.sub(fn, -5) == ".fkbk" then
            local env, err = read_envelope_file(fn)
            if env ~= nil then
                table.insert(out, {
                    name = fn,
                    id = env["id"],
                    ts = tonumber(env["ts"]) or 0,
                    reason = env["reason"],
                    size = env["_size"],
                    corrupt = false
                })
            else
                -- 损坏/不可解析条目没有 ts，排序时按 0 处理沉底
                table.insert(out, { name = fn, ts = 0, corrupt = true, error = err })
            end
        end
    end

    table.sort(out, function(a, b)
        local ta = a["ts"] or 0
        local tb = b["ts"] or 0
        if ta == tb then
            return name_greater(tostring(a["name"]), tostring(b["name"]))
        end
        return ta > tb
    end)
    return out
end

-- 检查单个备份（校验+解密），返回 true, 摘要表 或 false, 原因
function inspect(v)
    if not is_ready() then return false, "backup disabled" end
    local name = resolve_name(v)
    if name == nil then return false, "backup not found or ambiguous id" end

    local env, err = read_envelope_file(name)
    if env == nil then return false, err end

    local ok, inner = open_envelope(env)
    if not ok then return false, inner end

    local d = inner["data"]
    if type(d) ~= "table" then return false, "inner data missing" end

    local summary = {
        name = name,
        id = inner["id"],
        ts = tonumber(inner["ts"]) or 0,
        reason = inner["reason"],
        size = env["_size"],
        motd = d["motd"],
        rank_count = type(d["rank"]) == "table" and #d["rank"] or 0,
        events_count = type(d["events"]) == "table" and #d["events"] or 0,
        feed_count = type(d["feed"]) == "table" and #d["feed"] or 0,
        stats = d["stats"]
    }
    return true, summary
end

-- 从备份恢复（当前仅回写 MOTD）。返回 true, 恢复结果 或 false, 原因
function restore(v, actor)
    if not is_ready() then return false, "backup disabled" end
    local name = resolve_name(v)
    if name == nil then return false, "backup not found or ambiguous id" end

    local env, err = read_envelope_file(name)
    if env == nil then return false, err end

    local ok, inner = open_envelope(env)
    if not ok then return false, "backup verification failed: " .. inner end

    local d = inner["data"]
    if type(d) ~= "table" then return false, "inner data missing" end

    local restored = {}
    if d["motd"] == nil or type(d["motd"]) == "string" then
        local mok, merr = Motd.set(d["motd"])
        if not mok then
            return false, "motd restore rejected: " .. tostring(merr)
        end
        restored[#restored + 1] = "motd"
    end

    pcall(function()
        Audit.record("backup.restore", name, "restored=" .. table.concat(restored, ","), actor)
    end)
    pcall(function() log.warn("[backup] restored from " .. name .. " by " .. tostring(actor)) end)
    print("[Backup] restored {" .. table.concat(restored, ",") .. "} from " .. name)
    return true, { name = name, restored = restored, motd = d["motd"] }
end

-- 手动删除一份备份（文件名解析失败/文件不存在都报错）
function delete(v, actor)
    if not is_ready() then return false, "backup disabled" end
    local name = resolve_name(v)
    if name == nil then return false, "backup not found or ambiguous id" end
    local path = os.join(dir, name)
    if not os.isfile(path) then return false, "file not found: " .. name end
    local ok, err = pcall(function() os.remove(path) end)
    if not ok then return false, "remove failed: " .. tostring(err) end
    pcall(function() Audit.record("backup.delete", name, nil, actor) end)
    print("[Backup] deleted " .. name)
    return true, { name = name }
end

-- 保留份数维护：超出 keep 的最旧备份自动删除
function prune()
    if not is_ready() then return end
    local all = list_backups()
    local n = #all
    if n <= keep then return end
    for i = keep + 1, n do
        if all[i]["corrupt"] ~= true then
            pcall(function() os.remove(os.join(dir, all[i]["name"])) end)
        else
            pcall(function() os.remove(os.join(dir, all[i]["name"])) end)
        end
    end
end

-- ---- 热更支持 ----
function hotfix_save()
    local s = {}
    s["dir"] = dir
    s["key"] = key
    s["keep"] = keep
    s["rng"] = rng
    s["interval_s"] = interval_s
    s["next_ts"] = next_ts
    s["last_backup_ts"] = last_backup_ts
    s["last_backup_name"] = last_backup_name
    return s
end

function hotfix_restore(s)
    if s == nil then return end
    dir = s["dir"]
    key = s["key"]
    keep = s["keep"]
    rng = s["rng"]
    interval_s = s["interval_s"]
    next_ts = s["next_ts"]
    last_backup_ts = s["last_backup_ts"]
    last_backup_name = s["last_backup_name"]
end
