package "Store"

-- 跨帧 / 跨上下文共享状态的唯一入口。
--
-- 为什么需要它：fakelua 没有 GC，frame arena 在每次顶层 Call 进入时被重置，
-- 因此 VarTable（Lua 表）里的一切跨帧即失效；而文件级 local 只在「被跨包调用
-- 命中同一份 JIT 副本」时才共享，一旦走 TCC 副本就是另一个实例（回调会静默丢状态）。
--
-- 唯一可靠的地方是 State 持有的全局 NativeObject：它的 kv 落在 C++ 堆
-- （NativeField），跨帧持久，且 get_global_obj 在事件回调里拿到的也是同一个对象。
--
-- 取值必须走字符串键 r["k"] 而不是静态键 r.k：静态键要经 spec 访问器，
-- 热更后旧 .so 的访问器可能已失效（见 hotreload.lua 头注释）。
--
-- ---- 什么必须入库，什么可以留在文件级（spike M2~M5 实测） ----
-- 判据是「值的来源」，不是「变量声明在哪里」：
--   * 编译期字面量（数字 / 字符串 / 文件级 table 构造）→ 静态区，跨帧安全，
--     且 fakelua 直接把它们当常量，重新赋值会编译期报
--     "cannot reassign file-level constant"。例：mime_types、powerup_kinds、
--     known_types、SCHEMA_SQL、MAGIC、SYSTEM_CHAT_NAME。
--   * 数字 / 布尔 → 值语义，跨帧安全（world 的全部配置标量属于此类）。
--   * 运行期字符串（json/yaml 解码所得、字符串拼接、从运行期 table 取出）
--     → 帧 arena，**跨帧内容变垃圾**。典型事故：HttpStatic.web_dir 被
--     cfg["web_dir"] 赋值后拼出错误路径，静态资源全 404。
--   * 运行期 table / container / NativeObject 句柄 → 帧 arena，**跨帧悬垂**，
--     指针非 nil 但内存已失效，轻则读到脏数据，重则在 ForEachKV 里段错误。
-- 后两类一律走本文件入库；给每个模块写 persist()/restore() 时按这条判据过一遍。

local ROOT_KEY = "fakefish_root"

-- 幂等：key 已存在时直接返回已有对象，因此每帧调用都是同一个根。
function root()
    return new_global_obj(ROOT_KEY, "fakefish_root")
end

function get(k)
    return root()[k]
end

function set(k, v)
    local r = root()
    r[k] = v
end

function has(k)
    return root()[k] ~= nil
end

function clear(k)
    local r = root()
    r[k] = nil
end

-- ---- JSON 桥接：Lua 表状态跨帧的唯一低成本通道 ----
-- container 明确拒绝存 Lua table（native_container.cpp: PersistValue 抛异常），
-- 所以结构化的世界状态只能编码成字符串存进根容器，每帧解码回帧内 table。
-- 帧内 table 由 arena 分配、帧末随 arena 一起回收，这正是消除泄漏的关键。

function get_json(k)
    local raw = get(k)
    if raw == nil then return nil end
    if type(raw) ~= "string" then return nil end
    local ok, val = pcall(function() return json.decode(raw) end)
    if not ok then return nil end
    return val
end

function set_json(k, tbl)
    if tbl == nil then
        clear(k)
        return false
    end
    local ok, raw = pcall(function() return json.encode(tbl) end)
    if not ok then return false end
    set(k, raw)
    return true
end
