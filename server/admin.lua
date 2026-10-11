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
--       ping: ["echo", "fakefish-pong"]

local admin_token = nil
local commands = nil
local timeout_ms = nil

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
        for name, argv in pairs(cmds) do
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
