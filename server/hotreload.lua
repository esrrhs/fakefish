package "HotReload"

-- 热更（hotfix）编排模块
--
-- 原理：fakelua 的跨包调用在运行时按函数名查找（FakeluaCallByName），
-- 对同一 State 重新 CompileFile 会 Merge 替换同名函数地址，新调用即刻命中新版本。
-- 但静态 key 构造器生成的 spec 表其访问函数位于旧 .so：.so 卸载后这些 table 仍在堆上、
-- 却不可再被新代码索引，因此有状态模块在 restore 时用 pairs 遍历旧表、在新 .so 上下文
-- 整体重建（详见 World.hotfix_restore）。
--
-- 约束（fakelua 回调限制，见 docs/fakelua-pitfalls.md）：
-- WS on_event 是受限 C++ 上下文，只能入队；真正的编译在主循环 process() 里执行。

-- 可热更模块注册表（只读；新增可热更模块在此登记）
-- stateful=true 的模块必须实现 hotfix_save() 与 hotfix_restore(snap)
-- companions：热更本模块时必须同步迁移的模块（world 重建玩家表后，bot 持有的旧引用
-- 会变成指向已卸载代码的野指针，因此 world 的伴随模块是 bot）
local registry = {
    { name = "combat", file = "server/combat.lua", stateful = false },
    { name = "world",  file = "server/world.lua",  stateful = true, companions = { "bot" } },
    { name = "bot",    file = "server/bot.lua",    stateful = true  }
}

local admin_token = nil       -- hotfix 鉴权 token（config: server.hotfix_token）
local watch_enable = nil     -- 文件变更自动热更（config: server.hotfix_watch）
local pending = nil          -- 回调入队的 hotfix 请求，init() 中创建（必须为运行时 table）
local watch_snapshots = nil  -- name -> 上次文件内容
local frame_count = nil

-- 按名字查注册表项
local function find_entry(name)
    for i = 1, #registry do
        if registry[i].name == name then
            return registry[i]
        end
    end
    return nil
end

-- 读取文件全文，失败返回 nil
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- 状态快照：模块名 → 旧版 hotfix_save() 返回值
local function save_for(name)
    if name == "world" then
        return World.hotfix_save()
    elseif name == "bot" then
        return Bot.hotfix_save()
    end
    return nil
end

-- 状态接回：新版 hotfix_restore(snap)
local function restore_for(name, snap)
    if name == "world" then
        World.hotfix_restore(snap)
    elseif name == "bot" then
        Bot.hotfix_restore(snap)
    end
end

function init(cfg)
    pending = {}
    frame_count = 0
    if cfg == nil then cfg = {} end
    admin_token = cfg["hotfix_token"]
    watch_enable = cfg["hotfix_watch"]
    if watch_enable == nil then watch_enable = false end

    watch_snapshots = {}
    if watch_enable then
        for i = 1, #registry do
            watch_snapshots[registry[i].name] = read_file(registry[i].file)
        end
    end

    if admin_token == nil then
        print("[HotReload] hotfix_token not configured: all hotfix requests will be rejected")
    else
        print("[HotReload] Hotfix channel enabled (watch=" .. tostring(watch_enable) .. ")")
    end
end

-- 鉴权：未配置 token 时一律拒绝（安全默认）
function check_token(token)
    if admin_token == nil or token == nil then return false end
    return token == admin_token
end

-- WS 回调入口：仅做入队（不在 C++ 受限上下文中编译）
-- names 为 nil/空表 时热更全部可热更模块
function request(connid, names)
    local list = {}
    if type_of(names) ~= "table" then
        for i = 1, #registry do
            table.insert(list, registry[i].name)
        end
    else
        local n = #names
        for i = 1, n do
            if type_of(names[i]) == "string" then
                table.insert(list, names[i])
            end
        end
        if #list == 0 then
            for i = 1, #registry do
                table.insert(list, registry[i].name)
            end
        end
    end
    table.insert(pending, { connid = connid, modules = list })
end

-- 展开实际要 touch 的模块：加入 companions，按 registry 顺序去重
local function expand_targets(names)
    local want = {}
    for j = 1, #names do
        want[names[j]] = true
    end
    for j = 1, #names do
        local entry = find_entry(names[j])
        if entry ~= nil and entry.companions ~= nil then
            for k = 1, #entry.companions do
                want[entry.companions[k]] = true
            end
        end
    end
    local ordered = {}
    for i = 1, #registry do
        if want[registry[i].name] then
            table.insert(ordered, registry[i].name)
        end
    end
    return ordered
end

-- 热更多个模块：先统一快照（任何编译前）→ 逐个编译 → 按序恢复。
-- 单个模块失败不阻断其他模块；编译失败的模块保持旧代码运行、不做 restore。
function reload(names)
    local results = {}

    -- 请求了但不在注册表里的模块：先记录失败
    local unknown = {}
    for j = 1, #names do
        if find_entry(names[j]) == nil then
            table.insert(unknown, names[j])
        end
    end

    local targets = expand_targets(names)

    -- 阶段 1：编译前快照
    local snaps = {}
    local save_failed = {}
    for i = 1, #targets do
        local name = targets[i]
        local entry = find_entry(name)
        if entry.stateful then
            local ok, s = pcall(function() return save_for(name) end)
            if ok then
                snaps[name] = s
            else
                save_failed[name] = tostring(s)
            end
        end
    end

    -- 阶段 2：编译（save 失败的模块跳过编译）
    -- 注意：必须先把调用结果存入 local 再写表——c_gen 对「t[k]=函数调用()」会把
    -- 调用表达式重复编译两次（执行两次！），local 中转则只调用一次
    local compile_ok = {}
    for i = 1, #targets do
        local name = targets[i]
        local entry = find_entry(name)
        if save_failed[name] ~= nil then
            compile_ok[name] = false
        else
            local compiled = host.compile_file(entry.file)
            compile_ok[name] = compiled
        end
    end

    -- 阶段 3：按序恢复
    local restore_err = {}
    for i = 1, #targets do
        local name = targets[i]
        local entry = find_entry(name)
        if entry.stateful and compile_ok[name] then
            local ok, err = pcall(function() restore_for(name, snaps[name]) end)
            if not ok then
                restore_err[name] = tostring(err)
            end
        end
    end

    for i = 1, #targets do
        local name = targets[i]
        local r = { module = name, ok = true }
        if save_failed[name] ~= nil then
            r.ok = false
            r.err = "save failed: " .. save_failed[name]
        elseif not compile_ok[name] then
            r.ok = false
            r.err = "compile failed, old code retained"
        elseif restore_err[name] ~= nil then
            r.ok = false
            r.err = "restore failed: " .. restore_err[name] .. " (code already updated)"
        end
        table.insert(results, r)
    end
    for i = 1, #unknown do
        table.insert(results, { module = unknown[i], ok = false, err = "unknown module" })
    end
    return results
end

-- 主循环每帧调用：drain hotfix 请求并执行；watch 模式下每秒检查文件变更
function process()
    frame_count = frame_count + 1

    local reqs = pending
    pending = {}
    local req_count = #reqs
    for i = 1, req_count do
        local req = reqs[i]
        print("[HotReload] hotfix request from connid=" .. tostring(req.connid)
              .. ", modules=" .. tostring(#req.modules))
        local results = reload(req.modules)
        World.enqueue_response(req.connid, { type = "hotfix_result", results = results })
    end

    if watch_enable and frame_count % 20 == 0 then
        local changed = {}
        for i = 1, #registry do
            local name = registry[i].name
            local cur = read_file(registry[i].file)
            if cur ~= nil and cur ~= watch_snapshots[name] then
                watch_snapshots[name] = cur
                table.insert(changed, name)
            end
        end
        local changed_count = #changed
        if changed_count > 0 then
            print("[HotReload] file change detected, auto hotfix: " .. tostring(changed_count) .. " module(s)")
            local results = reload(changed)
            for i = 1, #results do
                local r = results[i]
                print("[HotReload]  - " .. tostring(r.module) .. ": ok=" .. tostring(r.ok)
                      .. (r.err ~= nil and (" err=" .. tostring(r.err)) or ""))
            end
        end
    end
end

function type_of(v)
    return type(v)
end
