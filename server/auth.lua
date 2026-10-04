package "Auth"

local SALT = "fakefish_salt_2026"

function hash_password(password)
    if password == nil then password = "" end
    -- 使用 FakeLua 内置 crypto.sha256
    return crypto.sha256(password .. ":" .. SALT)
end

-- 用户名只允许字母/数字/下划线，杜绝 SQL 注入与特殊字符问题
local function is_valid_username(username)
    if username == nil or #username < 2 or #username > 20 then return false end
    if string.match(username, "^[%w_]+$") == nil then return false end
    return true
end

function handle_register(username, password)
    if not is_valid_username(username) then
        return false, "用户名需为2-20位字母、数字或下划线"
    end
    if password == nil or #password < 3 then
        return false, "密码至少需要3个字符"
    end

    local pwd_hash = hash_password(password)
    local ok, res = DB.register(username, pwd_hash, 100)
    return ok, res
end

function handle_login(username, password)
    if username == nil or #username == 0 then
        return false, "用户名不能为空"
    end
    if password == nil or #password == 0 then
        return false, "密码不能为空"
    end

    local ok, acc = DB.get_account(username)
    if not ok then
        return false, "账号不存在，请先注册"
    end

    local pwd_hash = hash_password(password)
    if acc.password_hash ~= pwd_hash then
        return false, "密码错误"
    end

    return true, acc
end
