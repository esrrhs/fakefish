# FakeLua Bug 报告（Phase 16 接入实测发现）

> 发现日期：2026-10-11
> fakelua 版本：`dafdac7cc129a4bb0e84b4ad0c17238e12ffc548`（2026-10-09，含 PR #27 math/tonumber/format/table.insert-remove 对齐）
> 安装前缀：`/Volumes/Extra/Migrated/flbuild/install`（`lib/libfakelua.2.0.0.dylib`，CLI `bin/flua`）
> 参考基准：PUC-Rio **Lua 5.4.9**（`/Users/zx/homebrew/bin/lua5.4`）
> 验证方式：`flua -jit_type=0|1|2`（0=TCC，1=GCC，2=INTERP）+ Lua 5.4.9 对照；最小复现脚本留存于 `/tmp/repro_m16/`
> 发现场景：fakefish（fakelua 游戏服务端 demo）Phase 16 全量接入 event/sqlite/http/net.udp/crypto/random/utf8/url/csv/redis 模块
> 目标仓库：https://github.com/esrrhs/fakelua
>
> 与旧报告 `docs/fakelua-open-bugs.md` 的关系：该文档中的 Bug 1/2（`#t` 陈旧提升、Lua 模式）在 `c58ebff` 已修复，本文件不重复。

---

## Bug 1（高）：参数数值特化的入口守卫无视 Lua 层 `type` 分支，非数值入参直接 abort

**严重度：高** —— 合法 Lua 代码在 TCC/GCC 后端运行时抛未捕获异常使进程 SIGABRT；FakeFish 线上等价路径（HTTP query 参数天然是字符串）可被一个普通请求触发。

### 症状（两个编译层、两种表现）

**表现 A（运行时，致命）**：函数参数多态（可能传 number 也可能传 string），函数体内先用 `type()` 做了守卫（守卫分支内重赋值或提前 return），随后对该变量做数值比较/算术。JIT 后端会在**函数入口**无条件插入数值类型检查，非数值入参时、Lua 守卫分支还没机会执行就抛出：

```
fakelua error: bad argument #1 (limit): attempt to perform arithmetic on non-numeric value
libc++abi: terminating due to uncaught exception of type fakelua::FakeluaException
退出码 134（SIGABRT）
```

**表现 B（预编译期，非致命但行为不一致）**：同一模式在 AOT CGen 阶段报：

```
fakelua error: Code generate failed, function call cannot be specialized as numeric at <file>:<line>
```

FakeFish 启动时每个模块文件连报两次该错误，宿主捕获后回退到 JIT 才跑起来——不做后端回退的嵌入方会直接启动失败。

### 最小复现（已用 Lua 5.4.9 对照；TCC/GCC 失败、INTERP 通过）

```lua
-- repro_narrow.lua（最小：不需要 math.floor，一次数值比较即触发）
function v(limit)
    if type(limit) ~= "number" then return 20 end
    if limit < 1 then return 1 end
    return limit
end

function main()
    print(v("abc"))   -- Lua 语义：守卫命中，返回 20
    print(v(2.9))     -- 返回 2.9
    return 0
end
```

实测（`flua -jit_type=N repro_narrow.lua`）：

| 后端 | 结果 |
|------|------|
| TCC (0) | ❌ abort，退出码 134，`bad argument #1 (limit): attempt to perform arithmetic on non-numeric value` |
| GCC (1) | ❌ 同上 |
| INTERP (2) | ✅ 输出 `20` / `2.9` |
| Lua 5.4.9 | ✅ 输出 `20` / `2.9` |

注意：**只要传了非数值参数就崩，与调用次数/调用点形态无关**（单参单调用 `v("abc")` 同样 abort）。

### 二分矩阵（`/tmp/repro_m16/`，均 TCC 实测）

| 编号 | 关键形态 | 结果 |
|------|----------|------|
| y4 | `type` 守卫 + 后续 `<` 比较，字符串入参 | ❌ abort |
| y7 | 守卫分支**提前 return**、比较不可达，字符串入参 | ❌ abort |
| y5 | 把 `type` 换成 fakelua 的 `type_of`，字符串入参 | ❌ abort |
| y3 | 同模式但只传数值 | ⚠️ 启动期报 "cannot be specialized as numeric"，回退后运行正确（退出 0） |
| w1/w3 | 只有守卫+`math.floor`、无后续比较，或全部数值入参 | ✅ |
| **y6** | 守卫后把值放进**新局部**：`local n = tonumber(limit); if n == nil then n = 20 end` | ✅ 输出 `20` / `2.9` |

结论：fakelua 的类型推断**不做分支流敏感窄化**（branch narrowing），变量在 SSA 身份上被标记为"参与过数值运算的多态参数"；换一个由 `tonumber` 产出的新局部可以切断关联。

### 根因（源码位置，基于 dafdac7）

1. `src/compile/c_gen.cpp:723-739` `CGen::GenerateEntryDispatcher`：对推断出的 `math_param_indices` 中每个参数，在**函数入口**无条件生成硬守卫：
   ```cpp
   if (UNLIKELY({p}.type_ != VAR_INT && {p}.type_ != VAR_FLOAT)) {
       FakeluaThrowError(_S, "bad argument #N (name): attempt to perform arithmetic on non-numeric value");
   }
   ```
   守卫不看函数体内是否存在、以及能否到达相应数值运算；Lua 层的 `if type(x) ~= "number" then return end` 不能豁免入口检查，异常在任何 Lua 语句执行前抛出（堆栈只有 `FakeluaThrowError`，无上层 C++ 帧，即 JIT 生成代码直接调用）。
2. `src/compile/c_gen.cpp:3113-3124` `CompileNumericExp`：数值内建（如 `math.floor`）的参数是推断为 `T_DYNAMIC` 的函数调用/多态变量时直接 `ThrowError("function call cannot be specialized as numeric")`，而不是回退到动态变体——即表现 B 的来源。
3. 正确的特化语义应当是 **spec miss → deoptimize 到动态（INTERP 风格）变体**，而不是向用户进程抛错；INTERP 后端行为正确也印证了这一点。

### FakeFish 中的实际影响与规避

- `server/ledger.lua` 的 `query_events(limit, kind)`（HTTP `/api/events?limit=` 的 limit 来自 query string，恒为字符串）原写法：
  ```lua
  if type(limit) ~= "number" or limit ~= limit then limit = 20 end
  limit = math.floor(limit)
  ```
  启动期即命中表现 B（日志两条 ERROR）；若运行时收到 `?limit=abc` 类请求，TCC/GCC 路径会命中表现 A。
- 已按 y6 形态修复：`local lim = tonumber(limit); if lim == nil or lim ~= lim then lim = 20 end; lim = math.floor(lim)`（见 `server/ledger.lua:131-138`）。`server/http_static.lua` 的 `parse_rank_limit` 本来就是 `tonumber` 写法，故未踩中。
- 建议全局排查模式：函数参数参与 `<`/`>`/`+`/`math.*` 等数值运算、且依赖 `type()`/`type_of()` 守卫的，一律改为 `tonumber()` 落到新局部。

### 建议修复方案

1. 入口 dispatcher 的类型不匹配由硬抛错改为**去优化回退**（分派到该函数的动态类型变体），对齐 INTERP 后端行为；这是根治。
2. 类型推断增加分支窄化：`type(x) == "number"` 守卫的 then/else 分支内对 `x` 收窄类型，使守卫分支内的 return/重赋值能阻止入口守卫插入（至少对「守卫不通过则不可达数值运算」的控制流不插守卫）。
3. `CompileNumericExp`（c_gen.cpp:3118）对 `T_DYNAMIC` 操作数回退动态编译而非 ThrowError。

### 验收标准

1. 上述最小复现在 TCC/GCC/INTERP 均输出 `20` / `2.9`，退出码 0；Lua 5.4 对照一致。
2. `math.floor`/比较/算术对多态参数 + `type` 守卫的组合（含提前 return、NaN 自检 `x ~= x`）三后端均不产生 ERROR 日志。
3. 纯数值调用仍走特化快速路径（检查生成 C 代码保留入口 dispatcher），无性能回退；全量 ctest 三后端通过。

---

## Bug 2（中）：redis `SUBSCRIBE` 后续推送对已释放 `CmdOp` use-after-free

**严重度：中** —— 原生 redis 绑定的命令回调模型是一次性的，无法支撑 Pub/Sub；一旦使用 SUBSCRIBE/PSUBSCRIBE，第二条推送即悬垂指针写，属于堆内存破坏。

**验证状态：源码确认（`src/native/redis/native_redis.cpp`），未做运行时复现——本机无 redis-server/docker。** 以下机制分析可直接对照行号审阅。

### 机制

- `RedisConnection::Command`（native_redis.cpp:176-186）：每条命令 `new` 一个 `CmdOp{cb, reply, done}`，入队 `cmds_`，并把它的裸指针作为 hiredis 的 `privdata`：
  ```cpp
  auto *raw = op.get();
  cmds_.push_back(std::move(op));
  IssueArgv(std::move(parts), &RedisConnection::OnCommand, raw);
  ```
- `OnCommand`（native_redis.cpp:318-338）：hiredis 对该 context 的**每一条**回复（SUBSCRIBE 后包括每条消息推送）都回调同一个函数，无条件把 `priv` 当 `CmdOp*`：
  ```cpp
  auto *op = static_cast<CmdOp *>(priv);
  op->done = true;                 // 第二条推送起：写入已释放内存
  ...
  op->reply = CloneReply(reply);
  ```
- `Tick`（native_redis.cpp:203-215）：首条回复（订阅 ack）派发一次后清空 `cb`、`freeReplyObject` 并把该 op 从 `cmds_` 弹出销毁：
  ```cpp
  if (op && op->done && !op->cb.empty()) { DispatchCmd(*op); op->cb.clear(); }
  while (!cmds_.empty() && cmds_.front()->done && cmds_.front()->cb.empty()) {
      freeReplyObject(...); cmds_.pop_front();   // CmdOp 在此析构
  }
  ```
- 此后任意一条发布消息到达，hiredis 仍持原 privdata 调 `OnCommand` → `static_cast<CmdOp*>(悬垂指针)` → UAF 写 `done` 并 `CloneReply` 挂到悬垂对象，堆破坏/崩溃不可避免；消息本身也永远无法派发到 Lua。

### 建议修复方案

- 为订阅提供独立长生命周期对象：`redis.subscribe(channel, cb_name)` 注册一个不进 `cmds_` 一次性队列的订阅上下文（privdata 指向它），每条推送都回调具名 Lua 函数；`unsubscribe` 时注销并释放。hiredis 的订阅回复（`["message", channel, payload]`）与普通命令回复结构不同，需单独解析。
- 在修复前至少应在 `Command` 中拦截 `SUBSCRIBE/PSUBSCRIBE/UNSUBSCRIBE` 等命令并响亮报错，并在 `src/native/README*.md` 明确「command 为一次性 RPC，不支持 Pub/Sub」，避免使用者踩 UAF。

### FakeFish 规避

跨服聊天与排行镜像全部改用拉模式：`LPUSH/LTRIM/LRANGE`（聊天）与 `ZADD/ZREVRANGE`（排行），完全不使用 SUBSCRIBE/PUBLISH（见 `server/redis_store.lua`）。

---

## Bug 3（低）：`math.random` 不自动播种，每次进程启动随机序列完全相同

Lua 5.4 起伪随机数器在状态初始化时自动播种（参见 PUC-Rio Lua 5.4 手册对 `math.randomseed` 的说明）；fakelua 底层为 `std::rand()`，默认种子恒为 1，不显式 `math.randomseed` 则每次重启布局完全一致。

实测：

```lua
-- repro_random.lua
function main()
    print(math.random(1, 1000000), math.random(1, 1000000), math.random(1, 1000000))
    return 0
end
```

```
flua 进程 1：819122  956267  764553
flua 进程 2：819122  956267  764553     ← 完全相同
Lua 5.4 进程 1：314155  693151  926542
Lua 5.4 进程 2：555661  889208  397233  ← 自动播种
```

**影响**：游戏类应用每次重启食物/道具/出生点布局一模一样；安全场景（令牌、洗牌）更是禁忌。FakeFish 在 Phase 14 已显式 `math.randomseed(os.time())` 兜底，Phase 16 另用 `random.new()` PCG 多流绕开。

**建议**：Lua 状态初始化时对齐 Lua 5.4 行为自动播种（时间 + 地址/线程熵），或在文档显著位置声明必须手动 seed。

---

## Bug 4（低）：未捕获的运行时错误以 `libc++abi terminate` / SIGABRT 收场，退出码与错误呈现不符合 Lua 惯例

标准 Lua 解释器遇到未捕获错误时打印 `lua: <msg>` + 栈回溯并以退出码 1 结束；fakelua（至少 `flua` CLI 与未兜底的嵌入路径）让 `FakeluaException` 穿透到 C++ 顶层，由 `libc++abi` 终止：

```
libc++abi: terminating due to uncaught exception of type fakelua::FakeluaException:
fakelua error: bad argument #1 (limit): attempt to perform arithmetic on non-numeric value
退出码 134（SIGABRT）
```

**影响**：嵌入方必须自己在每个 C++ 入口包 try/catch，否则单条坏消息/坏请求（如 WS 收到畸形 JSON、HTTP query 类型不符）就能杀死整个服务进程；监控侧也无法按退出码 1 区分"脚本错误"与"原生崩溃"。Lua 层 `pcall` 可以兜住这类错误（FakeFish 的 WS/HTTP 分发均已 pcall，实测有效），但顶层默认行为不应对宿主如此危险。

**建议**：CLI 顶层 catch `FakeluaException`，打印错误后 `exit(1)`；README 的嵌入示例给出顶层 try/catch 模板。（本 Bug 与 Bug 1 叠加放大危害，修复 Bug 1 后触发面大减，但默认收尾方式仍建议改。）

---

## 附：已文档化的语义分歧（非缺陷，但 Lua 迁移者必踩）

以下行为在 `src/native/README.zh.md` 等文档中有声明或属 package 模型的有意设计，**不建议按 bug 修**，列此供迁移评估，FakeFish 已全部按约束改写：

1. **文件级 `local x = <字面量>` 是 static const，函数内重赋值报编译错误**：
   `cannot reassign file-level constant 'x'`（`src/compile/type_inferencer.cpp:683`）。
   标准 Lua 中文件级 local 是普通 upvalue，可随意赋值。
2. **文件级字面表连字段写都禁止**：`local t = {}; function f() t.x = 1 end` 运行时抛
   `attempt to modify a const table`（`src/compile/c_runtime_header.h:688/980/1070`，初始化后打 `CONST_FLAG`；README.zh.md:419 已声明）。
3. **chunk 顶层只允许 local 定义与 function 定义**：文件作用域内直接 `x = 2` 报
   `unsupported file-level statement Assign`。
4. 规避模式统一为：`local state = nil` 声明、在 `init()` 运行时创建表/赋初值（FakeFish 的 peers/counters/state 均如此）。Lua 5.4 对照：上述三种写法全部合法。
5. `event.emit(event_name, ...)` **最多转发 4 个参数**（`src/native/event/native_event.h:11` 注释声明）；超过需打包成 table。
6. native 异步回调（`http.request`/`redis.command`/`net.udp_server` dispatch 等）只接受**包内具名函数名字符串**，不接受内联闭包；C++ 派发上下文里只能写运行时 table 字段。

## 附：本轮排查后确认「不是 bug」、无需上报的点

- `math.huge`（返回 `inf`）与 `math.maxinteger`（`9223372036854775807`）实测正确——FakeFish Phase 14 笔记中"fakelua 无 math.huge"的说法不成立，请勿据此提 issue。
- `json.decode` 非法输入抛错可被 Lua 层 `pcall` 正常捕获（FakeFish WS 畸形包实测，仅引擎日志有 ERROR，服务不中断）。
- sqlite（open/prepare/bind/step/exec 行表以列名索引）、`http.request`（headers 为 key-value map）、`net.udp_server`、`crypto.uuid/sha256`、`random.new/get_state/set_state`、`csv.encode`、`utf8.len/offset`、`url.decode_query` 在 Phase 16 全量 E2E 中行为正常。
- redis `ZREVRANGE ... WITHSCORES` 返回的 score 是字符串——这是 Redis 协议原生行为，非绑定 bug。
