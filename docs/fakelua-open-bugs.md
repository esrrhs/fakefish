# FakeLua 未修复 Bug 交接文档（供修复方使用）

> 最近复核：2026-10-03，runtime 验证（不信 commit message，只信运行时输出）
> 修复分支：`fix/open-bugs`（commit `c58ebff`），本机 `/usr/local` 已于 2026-10-03 安装最新构建
> 参考基准：PUC-Rio Lua 5.5（`/opt/homebrew/bin/lua`），所有复现脚本经参考 Lua 验证
> 目标仓库：https://github.com/esrrhs/fakelua
> 修复状态：**Bug 1 (P1-9) 与 Bug 2 (P1-5b) 均已完全修复并经三后端 runtime 严格验证通过**。
>
> 历史版本：本文件首版基线为 `598632f`（2026-10-02）。`b83f574` 相对该基线只多了 PR #23。
> 现已在 `fix/open-bugs` 分支完成完整修复：
> - **Bug 1 (P1-9) 已修复**：增加 `IsPureNativeNumericExp` 检查，不纯的数值表达式（如 `#t` 长度运算等需输出语句的表达式）不走单次提升，改为每轮循环重求值；纯局部变量循环（如 `while x < 10`）保持原生快速路径。
> - **Bug 2 (P1-5b) 已修复**：移植 PUC-Rio Lua 5.4 模式匹配器（`lua_pattern.cpp`），全面支持 `%.`、`%d+`、`.-`、`%b()`、`%f[]`、`%1` 捕获替换等完整 Lua 语义。

---

## Bug 1：while 条件中的 `#t` 被提升只求值一次（P1-9，**已修复**）

**严重度：高** —— 会导致服务器进程崩溃或死循环。

> ✅ **FakeFish 侧已改回标准写法**（commit 见 `git log --grep workaround`）。
> `server/world.lua` 金币雨循环恢复为 `while bi <= #bonus_food do ... table.remove(bonus_food, bi) ... end`，
> 不再手动维护长度 `n`。2026-10-04 用本机 `/usr/local` 构建（`c58ebff`）三后端复跑
> `repro_p19c.lua`，TCC/GCC/INTERP 均输出 `LEN OK iters=3`。下文保留供修复方追溯。

### 当前状态（b83f574，三后端 runtime 实测）

| 条件形态 | TCC | GCC | INTERP |
|----------|-----|-----|--------|
| `while i <= #t do`（长度运算） | ❌ 陈旧，死循环 | ❌ 陈旧，死循环 | ✅ 正确 |
| `while f() > 0 do`（普通函数调用，结果 T_DYNAMIC） | ✅ | ✅ | ✅ |
| `while t[i].x > 0 do`（表索引，T_DYNAMIC） | ✅ | ✅ | ✅ |
| `while f(n) > 0 do`（数值参数 spec 特化调用） | ✅ | ✅ | ✅ |

### 症状（残余问题）

`#t` 在能编译为原生 C 比较的 while 条件中时，长度被取到一个函数级临时变量，该变量只在进入循环前赋值一次。循环体内 `table.remove` 缩短表后，条件仍按陈旧长度判断：

- `t[i]` 读到越界 `nil`，随后访问字段抛出 `attempt to index a non-table value`（金币雨场景的原始崩溃形态）；
- 或循环永不终止（游标不动、持续 remove 时）。

标准 Lua 语义要求每轮循环重新求值整个条件。

### 已生效的部分修复（不要重复做）

`src/compile/c_gen.cpp:1041-1046` `TryCompileNativeBoolExpr` 比较分支新增类型门控：

```cpp
const auto left_type = e->Left() ? GetType(e->Left()) : T_DYNAMIC;
const auto right_type = e->Right() ? GetType(e->Right()) : T_DYNAMIC;
if ((left_type != T_INT && left_type != T_FLOAT) || (right_type != T_INT && right_type != T_FLOAT)) {
    return {};
}
```

动态类型的函数调用、表索引因此回退到每轮重求值的慢速路径——这解释了为什么这两类形态已正确。**但该门控漏了 `#` 长度运算**：`#t` 被推断为 T_INT，门控放行，而它仍需在循环外输出一条求值语句。

### 根因（精确位置，行号基于 b83f574）

1. `src/compile/c_gen.cpp:1474` `CompileStmtWhile`：先尝试 `TryCompileNativeBoolExpr`，成功则生成原生 `while (cond) { ... }` 并返回。
2. `src/compile/c_gen.cpp:1041-1051`：比较两侧经 `TryCompileNativeExpr` 编译为 C 表达式；`i <= #t` 两侧均推断为 T_INT，门控通过。
3. `src/compile/c_gen.cpp:3021-3027` `CompileNumericExp` 处理 `UnOpKind::kNumberSign`：
   ```cpp
   if (op_kind == UnOpKind::kNumberSign) {
       const auto operand_cvar = CompileExp(e->Right());
       const auto ntmp = std::format("flua_native_{}", tmp_var_counter_++);
       func_temp_decls_ << "    int64_t " << ntmp << ";\n";
       Out() << GenTab() << std::format("FlLenInt(({}), {});\n", operand_cvar, ntmp);
       return ntmp;
   }
   ```
   `FlLenInt(...)` 是一条**语句**，编译条件时只输出在原生 while 循环**之外**，只执行一次；返回的临时变量在循环中永不更新。

生成的错误 C 代码等价于：
```c
int64_t flua_native_1;
FlLenInt(t, flua_native_1);                       // 只执行一次
while (i <= flua_native_1) { ... table.remove ... } // 长度永不更新
```

### 最小复现（已用 PUC-Rio Lua 5.5 对照验证，TCC/GCC 失败、INTERP 通过）

```lua
-- repro_p19c.lua
-- 参考 Lua：删除 3 次后 #t=0 循环结束，iters=3
-- TCC/GCC：条件长度陈旧（初始 3），remove 对空表 no-op，死循环到 iters>100
function main()
    local t = { 10, 20, 30 }
    local iters = 0
    while 1 <= #t do
        iters = iters + 1
        if iters > 100 then
            print("LEN BUG: stale #t bound, iters=" .. iters .. " actual #t=" .. #t)
            return 1
        end
        table.remove(t, 1)
    end
    if iters ~= 3 or #t ~= 0 then
        print("LEN wrong: iters=" .. iters .. " #t=" .. #t)
        return 1
    end
    print("LEN OK iters=" .. iters)
    return 0
end
```

实测输出（b83f574）：
```
TCC    -> LEN BUG: stale #t bound, iters=101 actual #t=0
GCC    -> LEN BUG: stale #t bound, iters=101 actual #t=0
INTERP -> LEN OK iters=3
Lua5.5 -> LEN OK iters=3
```

补充回归用例（参考 Lua 与 fakelua 三后端均通过，用于锁定已修好的调用/索引形态不回退）：
- 条件含普通函数调用：`while f() > 0 do ... end`（2 次迭代退出）；
- 条件含表索引：`while a[j].x > 0 do ... end`（3 次迭代退出）；
- 条件含 spec 特化数值函数调用：`while f(n) > 0 do ... end`（3 次迭代退出）。

> ⚠️ 首版文档里的 60 元素复现脚本自身有误：`i` 停在 3 持续 remove 时，参考 Lua 也是剩 2 个元素（`#t=2`）退出，并非文档当时声称的 40。当时 INTERP 输出 "wrong length: 2" 实为**正确行为**，TCC/GCC 的死循环才是 bug。请以本版最小复现为准。

### 建议修复方案

在 `TryCompileNativeBoolExpr`（c_gen.cpp:1041 比较分支）编译原生操作数**之前/同时**，确保操作数是「不需要输出语句、可直接展开为 C 表达式」的**纯表达式**：

- 纯：数值字面量、简单 local 变量引用、由纯子表达式组成的算术运算（C 变量在每轮原生 while 中自然重新读取，语义正确）；
- 不纯：`#`/字符串长度运算（`FlLenInt` 语句）、需要输出 `FlGetTable...`/调用语句的子表达式。

类型门控（T_INT/T_FLOAT）不能替代纯度判定，因为 `#t` 正是 T_INT 却不纯。实现上可递归检查 AST（参照文件内已有的 WalkSyntaxTree 用法），或在 `CompileNumericExp` 对 `kNumberSign` 提供「可内联表达式」变体（如直接展开 `FlLenInt` 的表达式形式），使长度求值进入 while 条件内部。

### 影响面排查（修复时确认，不要重复修）

- `repeat ... until cond`：条件位于 do-while 循环**体内**，语句每轮重新执行，无此 bug；
- `if cond`、数值 `for` 边界：单次求值符合 Lua 语义；
- 普通函数调用、表索引、spec 数值调用进入 while 条件：b83f574 已正确，需保持不回退；
- INTERP 后端：始终正确。

### 验收标准

1. 上述最小复现 TCC/GCC/INTERP 均输出 `LEN OK iters=3`，退出码 0。
2. 调用/表索引/spec 调用三个补充回归保持通过；纯局部变量条件（`while x < 10`）仍走原生快速路径（检查生成 C 代码仍为原生 `while`，防性能回退）。
3. 全量 `ctest` 三后端（CallAll：TCC/GCC/INTERP）通过，无新增警告。

---

## Bug 2：`string.find/match/gmatch/gsub` 走 ECMAScript 正则，不是 Lua 模式（P1-5b，**已修复**）

**严重度：中** —— 静默语义陷阱，不报错但匹配结果错误，可导致安全防护失效。

> ✅ **FakeFish 侧已改回标准写法**（2026-10-04）。以下业务代码不再规避：
> - `server/http_static.lua` 目录穿越防护：`string.find(path, "%.%.")`（原为 plain 子串 `".."`）；
> - `server/http_static.lua` `parse_limit`：`string.match(raw, "^%d+")`（原为 `"^[0-9]+"`）；
> - `server/world.lua` `trim_chat`：改用 Lua 字符类 `"^%s+"` / `"%s+$"`（原为 `"^[ \t\r\n]+"`）；
> - `server/auth.lua` 用户名校验：改用 `string.match(username, "^[%w_]+$")`（原为手写 `string.byte` 循环）。
>
> 本机三后端复跑 `repro_p15b2.lua`（17 项）均输出 `Lua-pattern ALL OK`；
> HTTP 层实测 `/../etc/passwd`、`/a/../b`、`/web/../config.yaml` 全部 403，`/index.html` 200。
> 下文保留供追溯。

### 当前状态（b83f574，三后端 runtime 实测）

未修复。`string.find("../etc/passwd", "%.%.")` 在 TCC/GCC/INTERP 上均返回 `nil, nil`（ECMAScript 下 `%` 为字面量、`.` 为任意字符），参考 Lua 5.5 返回 `1, 2`。

### 症状

fakelua 的模式串直接喂给 `boost::regex`（ECMAScript 语法），Lua 模式写法被静默改义：

- `string.find(path, "%.%.")` 想拦截 `../` 目录穿越：实际匹配「%任意%任意」，**防护从未生效**（FakeFish 已改用 plain 子串查找兜底）；
- `string.match(s, "^%d+")` 匹配行首字面量 `%d+` 而非数字；
- Lua 的 `*`/`+`/`-`/`?`、`%a`/`%s` 等字符类与 ECMAScript 的 `\d`/`\w`/`{n,m}` 语义完全不同。

### 最小复现（已用 PUC-Rio Lua 5.5 对照验证）

```lua
-- repro_p15b2.lua
function main()
    local function check(name, got, want)
        if got ~= want then
            print(name .. " BUG: got=" .. tostring(got) .. " want=" .. tostring(want))
            return false
        end
        return true
    end

    local a, b = string.find("../etc/passwd", "%.%.")
    if not check("find ..", a, 1) then return 1 end
    if not check("find ..2", b, 2) then return 1 end
    if not check("find plain", string.find("a.b.c", ".", 1, true), 2) then return 1 end
    if not check("match %d+", string.match("limit=15", "%d+"), "15") then return 1 end
    if not check("match ^%d+", string.match("15abc", "^%d+"), "15") then return 1 end
    if not check("match %a+", string.match("abc123", "%a+"), "abc") then return 1 end
    if not check("lazy -", string.match("a12b", "a.-b"), "a12b") then return 1 end
    if not check("%s%a", string.match(" x", "^%s%a"), " x") then return 1 end
    if not check("set", string.match("x_1", "[%w_]+"), "x_1") then return 1 end
    local k, v = string.match("name=bob", "(%a+)=(%a+)")
    if not check("cap1", k, "name") then return 1 end
    if not check("cap2", v, "bob") then return 1 end

    local s, n = string.gsub("hello", "l", "L")
    if not check("gsub s", s, "heLLo") then return 1 end
    if not check("gsub n", n, 2) then return 1 end
    if not check("gsub %1", string.gsub("a=1,b=2", "(%w)=(%w)", "%2:%1"), "1:a,2:b") then return 1 end
    if not check("gsub table", string.gsub("$name$", "%$(%w+)%$", { name = "bob" }), "bob") then return 1 end

    local cnt, sum = 0, 0
    for num in string.gmatch("10,20,30", "%d+") do
        cnt = cnt + 1
        sum = sum + tonumber(num)
    end
    if not check("gmatch cnt", cnt, 3) then return 1 end
    if not check("gmatch sum", sum, 60) then return 1 end
    if not check("%b()", string.match("f(x(y)z)end", "%b()"), "(x(y)z)") then return 1 end

    print("Lua-pattern ALL OK")
    return 0
end
```

实测：fakelua 三后端均在第 1 项失败（`find .. BUG: got=nil want=1`）；Lua 5.5 全部通过。

> ⚠️ 首版文档复现的第 2 项有误：`string.match("limit=15", "^%d+")` 因字符串行首不是数字，参考 Lua 也返回 nil。正确写法是去掉行首锚或改用 `"15abc"`。请以本版为准。

### 根因（精确位置，行号基于 b83f574）

- `src/native/string/native_string.cpp` `GetCachedRegex`（约 52-76 行）：固定以 `boost::regex::ECMAScript | boost::regex::optimize` 编译 pattern，无 Lua 模式翻译层。
- 四个模式函数（`string.find` 约 1254 行、`match` 约 1322 行、`gmatch` 约 1372 行、`gsub` 约 1394 行）均取正则于 `GetCachedRegex`；`find` 的 `plain=true` 路径（约 1285-1295 行）是纯子串匹配，语义正确，保留。
- `string.charpattern` 的特判在 `src/compile/c_gen.cpp` 与 `src/interp/codegen.cpp`，修复后需确认语义仍为「匹配单个任意字节」。
- `src/native/README.md` 目前仅有「使用 ECMAScript」的文档警告，无行为修复。

### 建议修复方案（二选一，推荐方案 A）

**方案 A（推荐）：改为完整 Lua 5.4/5.5 模式语义。**

- 首选移植 PUC-Rio Lua `lstrlib.c` 的模式匹配实现（`str_find_aux` / `singlematch` / `matchbalance` / `match_capture` 等，MIT 许可、自包含），天然支持正则无法表达的 `%b()`、`%f[set]`、惰性 `-`、位置捕获 `()`、gsub 替换串 `%0`-`%9`。
- 或实现「Lua 模式 → ECMAScript」翻译层，但 `%b`/`%f`/`-` 需自行补齐，出错面更大。
- **破坏性变更提示**：README 目前声明 ECMAScript，可能有现存代码依赖 `\d`/`\w`/`{n,m}`/`(?:...)`。建议新增独立 `regex` 模块继续暴露 ECMAScript，并在 CHANGELOG/README 标注。
- 需审计现有 `test/lua/string/` 下适配 ECMAScript 的断言，统一改以 PUC-Rio Lua 结果为准。

**方案 B（最小兜底）：** 保留 ECMAScript，但检测到 Lua 专有写法（如含 `%`）时响亮报错，而非静默按错误语义匹配。不满足 Lua 兼容，仅作退路。

### Lua 模式必须覆盖的语义清单（方案 A 验收依据）

- 字面量与转义：`%.` `%(` `%)` `%%` `%+` `%*` 等；
- 字符类：`%a %A %c %d %D %g %G %l %L %p %s %S %u %U %w %W %x %X`；
- 自定义集合：`[set]`、`[^set]`、区间、集合内嵌字符类；
- 量词：`*`（贪婪）、`+`、`-`（惰性）、`?`；锚点 `^`、`$`；
- 捕获：`()` 嵌套捕获、无组返回整匹配、find 位置捕获；
- `%bxy` 平衡匹配、`%f[set]` 前沿模式；
- `find` 的 `init` 与 `plain=true`；
- `gsub` 三种替换来源（字符串/表/函数）与替换串 `%0`-`%9`、`%%`。

### 验收标准

1. 上述复现三后端均输出 `Lua-pattern ALL OK`。
2. 按语义清单逐条覆盖，以 PUC-Rio Lua 同批用例输出为对照（可引入 Lua 官方测试套件模式用例）。
3. `string.charpattern` / `utf8.charpattern` 语义保持正确；现有适配 ECMAScript 的断言已审计更新；全量 `ctest` 三后端通过。

---

## 构建与测试方法

```bash
# 构建（与 CI 一致）
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(sysctl -n hw.logicalcpu)   # Linux 用 nproc

# 全量测试
ctest --test-dir build --output-on-failure
```

- 新增用例务必通过 `CallAll` 在 **TCC / GCC / INTERP 三种后端**下都验证。
- 快速手工验证单个 Lua 文件：`./build/cmd/flua /path/to/repro.lua`（默认入口 `main`，返回码即结果）。

## 附：本机验证材料（2026-10-03，b83f574）

- 复现脚本：`/tmp/repro_p19c.lua`（#t 最小复现）、`/tmp/repro_p19b.lua`（调用/索引回归组）、`/tmp/repro_p19d.lua`（spec 调用）、`/tmp/repro_p15b2.lua`（Lua 模式 17 项）。
- 三后端最小运行器：源码 `/tmp/repro_main3.cpp`，二进制 `/tmp/repro_run3`（动态链接 `/usr/local/lib/libfakelua.2.dylib`，2026-10-03 16:23 安装版）。
- 运行方式：
  ```bash
  cd /tmp
  lua  -e"dofile('repro_p19c.lua'); os.exit(main())"      # PUC-Rio 基准
  DYLD_LIBRARY_PATH=/usr/local/lib ./repro_run3 repro_p19c.lua
  ```
- FakeFish 侧 workaround（**已于 2026-10-04 全部移除**）：
  - `server/world.lua` 金币雨循环的手动长度 `n` → 已恢复 `while bi <= #bonus_food`；
  - `server/http_static.lua` / `world.lua` / `auth.lua` 的 ECMAScript 写法与 `string.byte` 循环 → 已恢复 Lua 模式。
- FakeFish 在 `c58ebff` 下的兼容性：重新构建 + 全量 E2E 回归（client / combat / api / gameplay /
  powerup / zone / split / feast / hotfix / bots）全部通过。
