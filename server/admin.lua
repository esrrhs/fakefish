package "Admin"

-- 管理接口（全部经 hotfix_token 鉴权，token 未配置则一律拒绝）：
--   POST /api/admin/run  { "cmd": "<白名单名>" }
--     执行配置文件里登记的子进程（fakelua process.run，不走 shell、无拼接参数），
--     同步返回 stdout/stderr/退出码，带超时。服务端单线程，只适合秒级运维命令。
--   POST /api/admin/motd { "motd": "..." }
--     更新登录公告（逻辑在 Motd 模块，此处只做鉴权与入参校验）。
--
-- 配置示例：
--   admin:
--     enabled: true
--     run_timeout_ms: 3000
--     commands:
--       # 简单形式：字符串数组全平台共用
--       ping: ["echo", "fakefish-pong"]
--       # 映射形式：按平台选择 argv（Windows 无 shell 内建，须显式给出可执行文件）
--       ver:
--         unix: ["uname", "-s"]
--         windows: ["cmd.exe", "/d", "/s", "/c", "ver"]

local admin_token = nil
local commands = nil
local timeout_ms = nil

-- Windows 下 process.run 同样不经 shell：echo 是 shell 内建、系统里没有 echo.exe。
-- 系统环境变量 OS=Windows_NT 自 Windows NT 起默认存在，Unix 不会同名设置，用作平台判定。
local IS_WINDOWS = os.getenv("OS") == "Windows_NT"

-- 白名单 argv 两种形式：字符串数组（全平台共用）或 {unix={...}, windows={...}}。
local function resolve_command_argv(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry[1]) == "string" then return entry end
    local pick = IS_WINDOWS and entry["windows"] or entry["unix"]
    if type(pick) ~= "table" then return nil end
    return pick
end

function init(cfg, srv_cfg)
    commands = {}
    timeout_ms = 3000

    if srv_cfg ~= nil then
        admin_token = srv_cfg["hotfix_token"]
    end

    if cfg == nil then cfg = {} end
    if cfg["enabled"] == false then
        print("[Admin] disabled by config (admin.enabled=false)")
        return
    end

    local tm = tonumber(cfg["run_timeout_ms"])
    if tm ~= nil and tm == tm and tm > 0 then
        timeout_ms = math.floor(tm)
        if timeout_ms > 10000 then timeout_ms = 10000 end
    end

    local cmds = cfg["commands"]
    if type(cmds) == "table" then
        for name, entry in pairs(cmds) do
            local argv = resolve_command_argv(entry)
            if type(name) == "string" and type(argv) == "table" and #argv > 0 then
                local valid = true
                for i = 1, #argv do
                    if type(argv[i]) ~= "string" or argv[i] == "" then
                        valid = false
                        break
                    end
                end
                if valid then commands[name] = argv end
            end
        end
    end

    local ncmd = 0
    for _ in pairs(commands) do ncmd = ncmd + 1 end
    print("[Admin] admin API ready (timeout " .. tostring(timeout_ms)
          .. "ms, whitelisted commands=" .. tostring(ncmd) .. ")")
end

function check_token(t)
    if admin_token == nil or admin_token == "" then return false end
    if type(t) ~= "string" then return false end
    return t == admin_token
end

-- 执行白名单命令：cmd 必须精确命中配置名，argv 完全来自配置（客户端不能附加参数）。
-- 返回 ok(bool), 结果表或错误信息
function run(cmd)
    if type(cmd) ~= "string" or cmd == "" then
        return false, "cmd required"
    end
    local argv = commands[cmd]
    if argv == nil then
        return false, "unknown command: " .. cmd
    end

    -- 复制一份 argv（process.run 只读，但配置表是共享 upvalue，不传出引用）
    local argv_copy = {}
    for i = 1, #argv do argv_copy[i] = argv[i] end

    local ok, out, err, code = pcall(function()
        return process.run(argv_copy, { timeout_ms = timeout_ms })
    end)
    if not ok then
        return false, tostring(out)
    end
    return true, { stdout = out, stderr = err, code = code }
end
