# FakeLua 深坑清单（FakeFish 项目实战发现）

> 来源：FakeFish（github.com/esrrhs/fakefish）——一个用 FakeLua 实现的 2D PVP 游戏服务端 demo。
> 以下问题均在真实项目中实际踩中，复现可靠。源码行号基于 2026-09-29 的 master 分支
> （fakelua/src/native/...）。
> 每条含：症状 / 复现 / 根因 / 建议修复 / 当前 Workaround。
>
> **状态标记**：`✅ 已修复（FakeFish 已改回标准写法）` 表示上游已修、业务代码不再需要规避；
> 其余条目 Workaround 仍然有效。

| 编号 | 摘要 | 状态 |
|------|------|------|
| P0-1 | `conn:query` 回调传内联闭包被静默丢弃 | Workaround 仍需 |
| P0-2 | MySQL 查询失败时回调派发不一致 | Workaround 仍需 |
| P1-3 | 模块级标量全常量赋值被标 const | Workaround 仍需 |
| P1-4 | 连接池无租约语义 | Workaround 仍需 |
| P1-5 | `json.encode` 空 table 产出 `{}` | Workaround 仍需 |
| P1-5b | 字符串模式匹配走 ECMAScript | ✅ 已修复（fakelua `fix/open-bugs` / `c58ebff`） |
| P1-6 | C++ 派发回调上下文的静默限制 | Workaround 仍需 |
| P1-9 | 原生 while 条件里的 `#t` 只求值一次 | ✅ 已修复（同上） |
| P1-10 | 动态表赋值 `t[k] = f()` RHS 执行两次 | ✅ 已修复（fakelua `4e396e8`） |
| P2-7 | MySQL 结果表格式未文档化 | 仍存在 |
| P2-8 | `runtime.tick` 泵序与嵌套回调延迟 | 仍存在 |

---

## P0-1 `conn:query` 回调传内联闭包会被静默丢弃（最严重）

**症状**：SQL 正常执行，但 Lua 回调**永不触发**。无任何报错、无日志。写库成功掩盖了读库失败，极易把 bug 埋几个月。

**复现**：
```lua
conn:query("SELECT 1", function(c, err, result)
    print("never printed")  -- 永远不会执行
end)
```

**根因**：`native_mysql.cpp` 的 `ConnQuery`（约 246 行）对回调参数做 `CVarToString(a1)`，
再 `conn->SetResultCallback(cb_name)`；实际派发时 `mysql_connection.cpp` 的
`DispatchResult`（约 731 行）用 `GetVM().GetFunction(result_cb_)` **按函数名字符串查全局函数**。
闭包参数被 `CVarToString`（27 行，只处理 String/StringId，其余 `return {}`）转成空串，
`GetFunction("")` 查不到 → `if (func.Empty()) return;` 静默返回。

**建议修复**（任选其一）：
1. `ConnQuery` 入口校验：`a1` 不是 String/StringId 直接 `ThrowBadArgument`（最小改动，把静默失败变响亮报错）；
2. 正式支持闭包：把闭包注册到 State 上生成句柄名，派发时按句柄取回闭包调用（同时解决无法传上下文的问题）。

**Workaround**：所有回调必须是包内全局函数，传名字符串：`conn:query(sql, "DB.on_result")`。
副作用：回调拿不到闭包上下文，查询与请求的关联（如"这条 SELECT 是谁的"）无法表达，
只能靠单飞行查询 + 模块级状态或服务端缓存绕开（FakeFish 最终改成了服务端定时刷新缓存）。

---

## P0-2 MySQL 查询失败时回调派发不一致：部分错误路径完全没有回调

**症状**：连接未就绪时的 query 会走 `pending_result_err_ = "connection not ready"` 且回调收到 err；
但另一条路径**连回调都没有**。

**复现**：连接握手未完成（或已 teardown）时调用 `conn:query(...)`：
`mysql_connection.cpp` 的 `Query`（176 行）第一行
`if (close_pending_ || !mysql_) return;` —— **直接 return，不设置 pending_result_，回调丢失**。

**后果**：调用方等待一个永远不会来的回调；配合"必须在回调里 release 连接"的池用法即连接池耗尽
（见 P1-4）。FakeFish 实测：MySQL 配置了但进程启动 4 秒内连接尚未就绪时，首次 SELECT 无声消失。

**建议修复**：`Query` 的所有提前 return 路径统一设置 `pending_result_err_` 并触发回调，
保证"只要 query 被调用，回调恰好被调用一次"。

---

## P1-3 模块级标量若"所有赋值都是编译期常量"会被 JIT 标成 const，多赋值点直接编译失败

**症状**：JIT 生成的 C 代码编译报错：
```
error: cannot assign to variable 'next_bot_id' with const-qualified type 'const int64_t'
note: variable 'next_bot_id' declared const here
    static const int64_t next_bot_id = 0;
```

**复现**：
```lua
package "Foo"
local next_bot_id = 0        -- 模块级常量初值
function init() next_bot_id = 800000 end      -- 常量赋值
function add() next_bot_id = next_bot_id + 1 end  -- 常量折叠后仍是常量
-- 三个赋值点全部是编译期可算的常量 → 被标记 const → 编译错误
```

**根因**：const 推断只看赋值是否为编译期常量，**不检查赋值点数量**。混合一个运行时赋值
（如 `x = cfg["w"] or 2000`）就不会 const 化（`local map_width = 2000` + init 里运行时赋值安然无恙），
行为非常反直觉。

**建议修复**：任一变量存在 ≥2 个赋值点时一律不标 const；或 const 化仅限"声明后从未再赋值"的变量。

**Workaround**：模块级可变标量一律 `local x = nil` 声明、在 init() 里赋运行时值。

---

## P1-4 连接池没有租约/自动归还语义，release 放错位置 = 永久泄漏

**症状**：`pool_size=2` 的池，两次写库后 `pool:acquire()` 永远返回 nil，之后所有 SQL 静默不执行。

**根因**：`mysql_connection_pool.cpp` 的 `Acquire`（52 行）标记 `entry.in_use = true`，唯一的归还途径是
`pool:release(conn)`。文档示例把 release 写在 query 回调里——而回调可能因 P0-1/P0-2 永不触发
（FakeFish 真实踩中：回调从不触发 → 连接永不归还 → 池耗尽）。

**附加坑**：query 飞行中同一连接再 query 会得到 "connection not ready" 错误
（`state_ != ConnState::Ready`），意味着"query 后立即 release"存在碰撞窗口。

**建议修复**：
1. 提供 `pool:with(fn)` 之类的租约 API 自动归还；或
2. query 派发时支持"用完自动归还"选项；或
3. 同连接飞行中再 query 改为排队而非报错。

**Workaround**：query 派发后立即 release（接受毫秒级碰撞窗口，碰撞时报错由回调日志兜底）。

---

## P1-5 `json.encode` 空 Lua table 产出 `{}`（对象）而非 `[]`（数组）

**症状**：协议里 `list` 字段为空时，客户端收到 `"list":{}`，JS 侧 `Array.isArray` 为 false，
按数组处理的代码全部崩掉。CI 双平台一个过一个不过，排查极其困惑（行为取决于缓存是否恰好非空）。

**复现**：
```lua
json.encode({ type = "rank", list = {} })  -- --> '{"type":"rank","list":{}}'
```

**建议修复**：`json.encode` 对**无字符串键的空 table** 编码为 `[]`（按"纯数组 table"启发式）；
或提供 `json.encode_array()` / `table.set_array_flag(t)` 元信息通道。

**Workaround**：客户端把非数组一律当空数组处理；服务端尽量避免编码空数组
（FakeFish 的 HTTP API 干脆手工拼 JSON 字符串）。

---

## P1-5b `string.find/match/gmatch/gsub` 走 ECMAScript 正则，不是 Lua 模式（静默语义陷阱）

**症状**：Lua 惯用的模式串完全变义，且**不报任何错**。真实案例：
`string.find(path, "%.%.")` 想拦截 `../` 目录穿越——ECMAScript 下 `%` 是字面量、`.` 是任意字符，
该正则实际匹配「%任意%任意」，**穿越防护从未生效**；`string.match(s, "^%d+")` 匹配的是
「行首字面量 %d+」而非数字。

**复现**：
```lua
string.find("../etc/passwd", "%.%.")          --> nil（ECMAScript 语义下不匹配，应为命中）
string.find("a.c", "a.c", 1, false)           --> 命中（. 当任意字符，Lua 模式下也命中但语义来源不同）
string.match("limit=15", "^%d+")              --> nil（想拿 "15"）
```

**根因**：`native_string.cpp` 直接把 pattern 喂给 `boost::regex`（进程级缓存，43-49 行），
无 Lua 模式翻译层；README 提过一句 ECMAScript 风格，极易漏看。

**建议修复**：要么实现 Lua 模式 → 正则的翻译层保持 Lua 兼容；要么在文档显著位置标注 +
对包含 `%` 转义的 pattern 给出一次性警告。

**Workaround**：需要字面量查找用 `string.find(s, sub, 1, true)`（plain 模式）；
字符类用 `[0-9]`、`[A-Za-z_]` 等 ECMAScript 写法；复杂校验手写 `string.byte` 循环。

---

## P1-6 C++ 派发回调上下文（ws on_event / mysql 回调）中的多重静默限制

fakelua 的 C++→Lua 回调运行在受限上下文，以下行为**均无报错或报错信息误导**：

1. **不能给模块级 local 赋值**（const 限制，见 P1-3 的运行时面）：混入运行时值的变量赋值
   在回调里也可能静默不生效（Linux 上实测：队列化消息整条丢失）。
2. **不能直接 `ws_server_obj:send()`**：在 Linux 上于 on_event 回调内调用 send 会**静默丢弃**
   （macOS 上正常）——平台相关，无任何诊断信息。
3. **只能改"运行时创建的 table"的内容/字段**：`p.pending_login_ok = {...}`（把回调里新建的
   table 挂到长生命周期 table 上）是可靠的；配合主循环统一 flush。

**建议修复**：
1. send 事件改为内部排队、由 runtime.tick 统一泵出（事件驱动改轮询驱动），从根上消除
   "回调里能不能 send"的问题；
2. 对 const/回调上下文限制给出**显式报错**而非静默丢弃；
3. 至少在文档中把"回调上下文允许/禁止的操作矩阵"写清楚。

**Workaround（FakeFish 固定模式）**：回调内只做"入队"（写运行时 table 字段），
主循环每帧 drain + 统一经玩家记录的 connid 发送。

---

## P1-9 原生 while 条件里的 `#t` 被求值一次并复用，循环内改表长会读到越界 nil

**症状**：形如
```lua
local i = 1
while i <= #t do
    ... table.remove(t, i) ...
end
```
的代码，条件中 `#t` 的结果是**陈旧值**：`table.remove` 缩短表后，循环仍按旧长度继续，
`local f = t[i]` 拿到 nil，随后 `f.x` 抛出 `attempt to index a non-table value`，整个服务器进程崩溃。
FakeFish Phase 8 金币雨上线后约 30s 必崩（机器人吃奖励豆路径），无客户端也复现。

**复现**（最小用例）：
```lua
local t = {}
for i = 1, 60 do table.insert(t, { v = i }) end
local i = 1
while i <= #t do
    if math.random() < 0.3 then table.remove(t, i)
    else i = i + 1 end
end
-- 一轮内即在 i = 真实长度+1 处拿到 nil
```
注意：循环**体内**单独求 `#t`（如 print）每次都是正确新值——只有 while **条件**里的长度是旧的。

**根因**：`src/compile/c_gen.cpp` 的 `CompileStmtWhile` 先走 `TryCompileNativeBoolExpr`。
条件能编成原生 C 比较时，其中的长度运算经 `CompileNumericExp` → `FlLenInt` 被取到一个
**函数级临时变量**（`func_temp_decls_` 声明，赋值语句在编译条件时只输出一次），
生成的 C 代码等价于：
```c
int64_t flen;
FlLenInt(t, flen);          // 只执行一次
while (i <= flen) { ... table.remove ... }   // flen 再不会更新
```
标准 Lua 语义要求每轮重新求值条件；CGen 错误地把带副作用的 `#t` 当成循环不变量。
这也使早先"`t[#t]=nil` swap-remove 会损坏表条目"的判断成为误诊——损坏表的其实是本 bug。

**建议修复**：原生 while 条件中包含函数调用 / `#` / 索引等可能被循环体改变的子表达式时，
禁止提升为函数级临时变量——改为在每轮循环开头（`while(1){ ... }` 路径里）重新求值。

**Workaround**：进入循环前把长度取进普通 local，并在每次删除后手动维护：
```lua
local n = #t
local i = 1
while i <= n do
    ... table.remove(t, i); n = n - 1 ...
end
```

---

## P1-10 动态表赋值 `t[k] = f()` 的 RHS 函数调用被编译并执行两次

**现状**（抓生成的 `.c` 产物确认）：当右侧是函数调用、且写入的是动态 key 表字段时，
c_gen 会把 RHS 表达式生成两份**顺序执行**的代码——第一份结果从未使用，但其中的调用真实执行：

```c
flua_call_dead = FakeluaCallByName(_S, ..., "host.compile_file", 1, arg);  // 实际执行！
flua_call_used = FakeluaCallByName(_S, ..., "host.compile_file", 1, arg);
FlSetTable(t, key, FlUnboxMulti(flua_call_used, 0));
```

本地变量赋值 `local x = f()` 只有一次；`t[k] = g()` 形式的调用全部重复。
副作用型调用（重编译、写库、计数）会造成重复动作与翻倍开销；JIT 无法按"无副作用"前提消除。

**Workaround**：调用结果先入 local 中转，再写表：
```lua
local v = f()
t[k] = v
```

---

## P2-7 MySQL 结果表格式未文档化、行值全为字符串

**现状**（源码 `mysql_connection.cpp` `ResultsetToLua` 约 778 行确认，官方文档未写）：

- SELECT：`result[1]=true`；`result[2]`=列信息表（每项 `{[1]=列名,[2]=类型}`）；
  `result[3]`=行表，每行**按列位置（1 起）索引**，值全部是**字符串**（NULL 为 nil），数字需 `tonumber`。
- INSERT/UPDATE：`result[1]=false`；`result[4]=affected_rows`；`result[5]=last_insert_id`；`result[6]=info`。

**问题**：不用源码考古根本写不出正确的 SELECT 解析；布尔/整数列以字符串返回是隐性性能与易错点。

**建议修复**：按列类型返回 number/bool；文档补全结果表布局。

---

## P2-8 runtime.tick 的泵序与嵌套回调延迟

`native_runtime.cpp`：`RuntimeTick` 顺序固定为 timer → net → http → mysql → redis。
mysql 连接的泵 `TickMysqlConnection`（native_mysql.cpp 361 行）在 `conn->TickDepth() > 0` 时**直接跳过**，
即 mysql 回调里再发起的同连接查询要等下一轮 tick；net 回调里发起的查询最早也要到**下一帧**才有结果。
这是设计使然但完全无文档，容易写出"回调里发查询并期待同步拿结果"的错误代码。

**建议**：文档写清 tick 泵序与"回调里发起的 IO 最早何时可见"。

---

## 附：宿主集成侧的两个非 fakelua 坑（供参考，改 fakefish/CI 而非 fakelua）

- CI 在服务器**启动后**才 sed 修改 config.yaml 无效（配置启动时一次性读取）；
- macOS BSD sed 与 GNU sed 的 `-i` 语法不兼容，跨平台脚本须用 `sed -i.bak ... && rm -f *.bak`；
- `test_split.js` / `test_combat.js` 的若干断言**隐含依赖「世界无机器人」**：
  金币豆被吃掉后会移到新坐标，快照里的豆集合减少既可能是本玩家吃的、也可能是 bot 吃的，
  两者无法区分；细胞也可能被 bot 吞噬而损失金币。CI 已把 combat/split 放在 `bot_count: 0`
  环境跑；本地复现请沿用同一配置。`test_split.js` 现已按 `botsPresent` 自动放宽断言
  （有 bot 时只校验「分裂/合体成功 + 金币不减少」），无 bot 时仍走严格金币守恒。
- `test_combat.js` 的 Phase 2 追逐曾有约 10% 概率超时。**根因（2026-10-04 定位并修复）**：
  安全区（`zone_dps: 20` 圈外每秒扣金币）会把 Hunter 与 Prey 的金币都扣到 0，
  `calc_radius(0) = 15` 是半径下限，此时 `check_eat` 的两个条件同时失效——
  `r1 >= r2 * 1.05`（`15 >= 15.75` 为假）与 `g1 > g2`（`0 > 0` 为假）。
  **即使两球圆心重合也不可能触发吞噬**，测试只能耗尽 25s 超时。
  失败现场日志特征：双方 `gold=0, r=15` 且 `dist` 已小于 15（贴脸却不吞噬）。

  **修法**（`server/combat.lua`）：`check_eat` 新增可选参数 `tie_equal / id1 / id2`，
  双方金币相等且半径相等时按 `player_id` 小的一方吞噬（`server/world.lua` 传
  `eat_tie_equal` 配置项，默认 true）。要点：
  - **必须用 player_id 裁决，不能用坐标** —— 坐标每帧变化，用它裁决会让两个玩家互相反复吞噬。
  - 金币全程是整数（分裂用 `math.floor` 均分、增减均为整数），故 `g1 == g2` 判定可靠，无浮点误差。
  - 常规规则（`g1 > g2` / `g2 > g1`）行为完全未变，已用 588 组不等金币组合做新旧实现逐一对拍，零差异。
  - 效果：combat 测试 `bot_count: 3` 下 15/15 通过、`bot_count: 0` 下 10/10 通过（修前两者各约 1/10 失败）。
- `test_hotfix.js` 的 world 热更往返本机实测 **6.2-6.8s**（重编译 world 137 函数 + bot 19 函数，
  每文件跑 TCC + GCC 两轮 JIT），超时阈值原为 10s、余量仅 1.5 倍，共享 CI runner 降速即误报。
  已放宽至 30s。
- **Windows 上 `process.run` 不能用 `cmd.exe /c` 跑带空格的一条命令**（2026-10-12 定位，Windows CI 红灯）：
  fakelua 的 `QuoteWinArg`（`native_process.cpp:279`）对**每个**参数无条件套一层双引号，
  拼出的命令行是 `"cmd.exe" "/d" "/c" "echo fakefish-pong"`，`/c` 之后实际是
  ` "echo fakefish-pong"`（`/c` 与命令串之间有个空格）。
  cmd 提取命令的「规则二」会看 `/c` 之后的**首字符**是不是引号——首字符是空格，
  于是前导引号被原样保留、只剥掉尾部引号，整条命令被当成单个文件名，报
  `'"echo fakefish-pong' is not recognized`，exit=1。
  **两个直觉修法都无效**：去掉 `/s` 没用（`/s` 的作用恰恰是强制走规则二）；
  拆成 `["cmd.exe","/d","/c","echo","fakefish-pong"]` 也不行（echo 会把带引号的参数原样打印）。
  **可行解**：改用 PowerShell（`powershell.exe -NoProfile -NonInteractive -Command "Write-Output ..."`），
  它走标准 C 运行时 argv 解析，正好与 process.run 的加引号方式匹配；
  代价是冷启动 1-2s，故 `run_timeout_ms` 从 3000 放宽到 8000。
  排查提示：这类失败里 `stderr` 是 cmd.exe 自己吐的文案，说明平台分支已选对、
  `os.getenv("OS")` 判定有效、可执行文件也已成功启动——问题一定在 argv 传递，别再去查平台判定。
- **Windows 上 hotfix 重编译的耗时不能用 Unix 基线**（2026-10-12，CI run 38205227815 前一次）：
  admin ping 修好后 Windows job 一路推进到最后一个套件，停在
  `[3/4] Combat hotfix applied` 之后 `FAIL: hotfix_result timeout`，恰好卡在 30s 边界。
  `test_hotfix.js` 的 30s 默认值是按 Unix 定的（本机往返实测 6.2-6.8s）；
  Windows 上 fakelua 按上游约定 -O0 构建且 JIT 走 gcc 子进程，
  重编译 world(137 函数) + bot(19 函数) 慢得多，30s 必然误报。
  `test_hotfix.js` 早已预留 `HOTFIX_TIMEOUT_MS` 变量，Windows job 侧设 `120000` 即可
  （与同文件就绪窗口放宽到 120s 是同一类做法）。Linux/macOS 保持默认 30s。

---

## 附：FakeLua 脚本编写约束（非 bug，属语言子集限制，写测试/工具脚本时容易踩）

- **表构造器不接受尾随逗号**：`local t = { "a", }` 报 `syntax error, unexpected }`。
  标准 Lua 接受，fakelua 拒绝。
- **文件级只允许 local / function 定义**：`for ... in` 等语句出现在文件级报
  `SemanticAnalysis check failed, unsupported file-level statement ForIn`。
  验证脚本须把逻辑包进 `function main()`，再用 `flua` / `repro_run3` 调用入口。
- 复现/验证脚本建议以 PUC-Rio Lua（`/opt/homebrew/bin/lua`）跑一遍作基准，再用
  `/tmp/repro_run3`（TCC/GCC/INTERP 三后端）验证，两边输出一致才算通过。
