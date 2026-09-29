# FakeFish

[![CI](https://github.com/esrrhs/fakefish/actions/workflows/ci.yml/badge.svg)](https://github.com/esrrhs/fakefish/actions/workflows/ci.yml)

用于验证 [esrrhs/fakelua](https://github.com/esrrhs/fakelua) 能力的 **demo 游戏**：在真实可玩场景里串起 FakeLua 的脚本运行时、`runtime.tick` 事件泵、WebSocket、HTTP、MySQL、JSON、定时器与配置解析等能力。

玩法是简易网页 2D PVP：**金币球 · 大鱼吃小鱼**。服务端为单线程 FakeLua 程序，全部玩法逻辑在后端；前端只做表现与输入上报。账号数据存 MySQL，客户端通过 WebSocket 与服务器通信。

> 本仓库是演示与能力验证项目，不是面向上线运营的完整游戏产品。

---

## 设计文档

### 1. 一句话玩法

玩家登录后，控制一个「金币球」在共享 2D 场地里移动。金币越多球越大；碰撞时大球吃掉小球，吞掉对方当前金币，小球以初始金币/大小随机位置复活。

### 2. 目标与非目标

| 目标 | 非目标（本期不做） |
|------|-------------------|
| 用可玩 demo 验证 FakeLua 端到端能力 | 商业化运营、完整内容生态 |
| 可登录/注册的轻量 PVP 沙盒 | 排行榜、公会、商城、皮肤 |
| 权威服务端：移动、碰撞、吃球、金币结算 | 客户端预测、插值物理权威 |
| MySQL 持久化账号与金币 | 多进程/多线程分片、跨服 |
| 单 HTML/JS 页面可玩 | 复杂 UI 框架、移动端 App |
| 配置文件启动（含 MySQL 等） | 热更、运维后台 |

### 3. 架构总览

```
┌─────────────┐   HTTP(静态页)    ┌──────────────────────────────┐
│  浏览器前端  │ ───────────────► │  FakeFish Server (单线程)     │
│  index.html │   WebSocket JSON │  FakeLua + net/http/mysql     │
│  + canvas   │ ◄─────────────── │  配置 → 主循环 runtime.tick() │
└─────────────┘                  └──────────────┬───────────────┘
                                                │ async mysql
                                                ▼
                                         ┌────────────┐
                                         │   MySQL    │
                                         │  accounts  │
                                         └────────────┘
```

- **单进程单线程**：一个 FakeLua `State`，主循环里反复 `runtime.tick()`，驱动 WS / HTTP / MySQL / timer。
- **权威后端**：前端只发送意图（如移动方向）；位置、半径、吃球、金币变更一律由服务器计算并广播。
- **依赖**：以 CPM/子模块等方式引入 `esrrhs/fakelua`，业务脚本用 FakeLua 子集编写（`package`、无 metatable 等约束）。

### 4. 核心玩法规则

| 规则 | 说明 |
|------|------|
| 数值 | 每个角色只有一个数值：**金币 `gold`** |
| 体型 | `radius = f(gold)`，例如 `radius = base_r + k * sqrt(gold)`（具体公式进配置） |
| 移动 | 玩家发送方向/目标；服务器按速度积分更新位置，限制在地图边界内 |
| 碰撞 | 两球圆心距 ≤ 半径差（或半径和的阈值）且大球金币严格更大 → 大吃小 |
| 吃球结算 | 大球 `gold += 小球.gold`；小球重置为 `initial_gold`，随机空位复活 |
| 平局 | 金币相等或体型接近时不互相吞噬（避免同体互杀抖动） |
| 下线 | 断开 WS 后角色离场；金币写回 MySQL |

### 5. 账号与数据

**表 `accounts`（草案）：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | BIGINT PK AI | 账号 ID |
| `username` | VARCHAR(32) UNIQUE | 登录名 |
| `password_hash` | VARCHAR(128) | 哈希后的密码（如 SHA256 + salt） |
| `gold` | BIGINT | 当前金币 |
| `best_gold` | BIGINT | 历史最高金币（排行依据） |
| `kills` / `deaths` | INT | 累计吞噬数 / 被吞数 |
| `created_at` / `updated_at` | DATETIME | 时间戳 |

- **注册**：用户名不存在则插入（仅允许字母/数字/下划线），初始 `gold = initial_gold`。
- **登录**：校验密码 → 建立会话 → 加载金币 → 在场景中生成球。
- **持久化**：吃球后可节流写库；断线/正常登出时强制写回。

### 6. 网络协议（WebSocket + JSON）

约定文本帧，每条消息为 JSON 对象，含 `type` 字段。

**C → S（客户端 → 服务器）**

| type | 字段 | 说明 |
|------|------|------|
| `register` | `username`, `password` | 注册 |
| `login` | `username`, `password` | 登录并进场 |
| `move` | `dx`, `dy` 或 `dir` | 移动意图（归一化方向） |
| `get_rank` | 可选 `limit`（默认 10，最大 20） | 请求历史最佳排行 |
| `ping` | 可选 `t` | 心跳 |

**S → C（服务器 → 客户端）**

| type | 字段 | 说明 |
|------|------|------|
| `login_ok` | `player_id`, `gold`, `map` | 登录成功 |
| `login_fail` / `register_fail` | `reason` | 失败原因 |
| `snapshot` | `players[]` | 全量或差分场景状态 |
| `player_join` / `player_leave` | `player_id`, … | 进出场 |
| `eat` | `eater_id`, `victim_id`, `gold` | 吃球事件（可驱动特效） |
| `you_died` | `gold`, `x`, `y` | 自己被吃后复活信息 |
| `rank` | `list[]` | 历史最佳排行（按 `best_gold` 降序，来自 MySQL） |
| `error` | `reason` | 通用错误 |

`players[]` 元素示例：`{ id, name, x, y, gold, r, bot? }`。前端据此画圆、标金币/昵称；`bot: true` 表示 AI 机器人。

### 7. 服务器模块划分（FakeLua）

| 模块 | 职责 |
|------|------|
| `main` | 读配置、初始化 MySQL/WS/HTTP、进入 tick 循环 |
| `config` | 解析 YAML/TOML/INI（fakelua 已有），暴露端口、地图、公式参数 |
| `db` | 账号查询/插入、金币与战绩（best_gold/kills/deaths）更新、历史排行查询 |
| `auth` | 注册登录、会话绑定 `connid ↔ player`、用户名字符集校验 |
| `world` | 玩家实体表、移动积分、边界 |
| `bot` | AI 机器人（觅食/追击/逃跑/游荡），复用 World 实体与 Combat 结算 |
| `combat` | 碰撞检测与吃球结算 |
| `net_ws` | WS 收发包、JSON 编解码、广播 |
| `http_static` | 可选：用 `http.server` 托管前端静态页 |

跨帧状态使用 FakeLua **container** / NativeObject（arena reset 后 Lua table 不可长期持有）。

### 8. 配置（示例）

```yaml
server:
  http_port: 8080          # 静态前端
  ws_port: 8081            # 游戏 WebSocket
  tick_ms: 50              # 逻辑帧间隔约 20Hz

mysql:
  host: 127.0.0.1
  port: 3306
  user: fakefish
  password: "changeme"
  db: fakefish

game:
  map_width: 2000
  map_height: 2000
  initial_gold: 100
  move_speed: 120          # 单位/秒
  radius_base: 12
  radius_k: 2.5            # r = base + k * sqrt(gold)
  eat_ratio: 1.05          # 大球半径需 >= 小球 * ratio 才可吃
```

启动：`./fakefish --config=config.yaml`（或由 `flua` 加载入口脚本）。

### 9. 前端表现

- 单页：登录/注册表单 + 全屏 Canvas。
- 连接 `ws://host:ws_port`，登录成功后进入游戏循环。
- 键盘 WASD / 方向键 → 发 `move`；按 `snapshot` 渲染所有球。
- 不做权威计算；被吃时根据 `you_died` 提示并继续操作复活后的球。

### 10. 技术约束（来自 FakeLua）

- 单线程 `State`；异步 IO 靠 `runtime.tick()`。
- 无 coroutine / metatable；模块用 `package "Name"`。
- 长期数据放 container / C++ NativeObject，不要依赖跨帧 Lua table。
- 网络：`net.ws_server`；库：`mysql.connect` / pool；配置：`yaml`/`toml`/`ini`；消息：`json`。

---

## 开发计划

### Phase 0 — 仓库与脚手架

- [x] GitHub 仓库重命名：`fake_game_server` → **`fakefish`**
- [x] 清空旧 C++/fake 多进程框架代码
- [x] 本设计文档与开发计划写入 README
- [x] 接入 `esrrhs/fakelua`（通过 Modern CMake `find_package(fakelua REQUIRED)`）
- [x] 最小可运行入口：宿主程序 `host/main.cpp` 加载配置与 `server/main.lua`，进入 `runtime.tick`
- [x] `.gitignore`、目录约定、`config.example.yaml`

**项目目录结构：**

```
fakefish/
  README.md
  config.example.yaml
  config.yaml             # 本地运行配置（自动被 git 忽略）
  docker-compose.yml      # 可选：一键拉起 MySQL 容器
  sql/schema.sql          # 数据库初始化表结构
  host/
    main.cpp              # C++ 宿主入口，初始化 FakeLua State 并启动脚本
  server/                 # 权威服务端 FakeLua 业务脚本
    main.lua              # 服务端主循环与模块编排
    config.lua            # YAML 配置解析与管理
    db.lua                # MySQL 连接池与内存回退存储
    auth.lua              # SHA256 密码哈希、用户注册与鉴权
    world.lua             # 实体状态、移动积分、边界与金币豆刷新
    bot.lua               # AI 机器人（觅食/追击/逃跑/游荡）
    combat.lua            # 质量/半径公式与大鱼吃小鱼碰撞判定
    net_ws.lua            # WebSocket 路由、事件分发与 20Hz 场景快照广播
    http_static.lua       # HTTP 静态前端文件托管
  web/                    # 纯原生 HTML5/Canvas 静态前端
    index.html            # 登录界面与全屏 Canvas 画布、HUD
    game.js               # WebSocket 客户端、相机跟随、平滑渲染
    style.css             # 暗色赛博霓虹风格 UI
  test_client.js          # 端到端 WebSocket 自动化测试
  test_combat.js          # 双客户端大鱼吃小鱼吃球与复活验证测试
  test_bots.js            # AI 机器人与历史排行验证测试
  CMakeLists.txt          # 工程构建配置（Modern CMake find_package）
```

### Phase 1 — 基础设施

- [x] MySQL schema + 连接/连接池封装（支持无 MySQL 环境自动降级内存模式）
- [x] 注册 / 登录（含 SHA256 密码哈希）
- [x] WebSocket 握手与 JSON 路由骨架
- [x] HTTP 托管 `web/`（自动解析 MIME 类型托管静态页）

### Phase 2 — 世界与玩法

- [x] 玩家进场：按金币算半径、随机出生点
- [x] 移动积分 + 地图边界 + 场景散落金币豆（自动拾取与补给）
- [x] 碰撞检测 + 吃球 + 复活重置
- [x] 状态广播（20Hz 场景全量快照与事件推送）
- [x] 金币回写 MySQL（吃球实时结算落盘 + 离场自动保存）

### Phase 3 — 前端可玩

- [x] 登录/注册 UI（表单弹窗、回车提交）
- [x] Canvas 渲染球、霓虹光晕、昵称、金币标签、排行榜 HUD
- [x] 输入监听（WASD / 方向键 / 鼠标跟随） → 上报 `move`；处理 `snapshot` / `eat` / `you_died`
- [x] 断线重连与被吃复活提示

### Phase 4 — 打磨

- [x] 参数调优（动态质量减速机制、动态半径缩放、金币豆拾取）
- [x] 基础反作弊：移动方向向量长度归一化（防止超速作弊）
- [x] Docker Compose（`docker-compose.yml`）一键启动 MySQL
- [x] 端到端自动化测试脚本（`test_client.js`, `test_combat.js`）

### Phase 5 — 世界生命感与竞技留存

- [x] AI 机器人（`server/bot.lua`）：配置 `game.bot_count` 控制数量，具备觅食、追击猎物、逃离威胁、随机游荡四种行为；金币达到 `bot_max_gold` 软上限后只游荡，避免一家独大
- [x] 机器人复用玩家实体管线：快照带 `bot: true` 标记，前端画布与排行榜显示 🤖 标识；机器人不落盘、不计战绩
- [x] 持久化历史排行：`accounts` 表新增 `best_gold` / `kills` / `deaths` 列；每次吃球/被吃/离场实时结算落盘
- [x] 新增 `get_rank` / `rank` 协议：异步查询 MySQL Top N（无 MySQL 时降级内存排行），前端「⭐ 历史最佳」面板每 10 秒刷新
- [x] 安全加固：用户名限制为 2-20 位字母/数字/下划线（杜绝 SQL 注入）
- [x] 端到端测试脚本（`test_bots.js`）并纳入 CI

### 里程碑验收

1. **M1**：空服启动 + 连上 MySQL / 内存降级 + WS 建立连接：**已通过**
2. **M2**：双客户端注册登录进场，实时移动与同步：**已通过**
3. **M3**：吃豆成长、大吃小吞噬结算、金币转移、小球复活、断线重登金币持久化：**已通过**
4. **M4**：浏览器访问 `http://127.0.0.1:8080` 开箱即玩：**已通过**
5. **M5**：机器人进场游走、历史排行跨会话持久化（MySQL）与内存降级排行：**已通过**

---

## 快速开始

### 1. 依赖准备

- **CMake** >= 3.20
- **C++23 编译器** (Clang / GCC)
- **fakelua** (系统安装于 `/usr/local` 或 CMake 搜索路径，提供 `fakelua::fakelua` 目标)
- **Node.js** (可选，仅运行自动化测试脚本时需要 `npm install ws`)

### 2. 数据库配置（可选）

如需使用 MySQL 持久化，可通过 Docker 一键启动：
```bash
docker compose up -d
```
> 若不启动 MySQL，服务器会自动降级为内存存储模式（In-Memory Store），完全不影响本地试玩与验证！

> ⚠️ Phase 5 起 `accounts` 表新增 `best_gold` / `kills` / `deaths` 列。已有旧库需手动迁移：
> ```sql
> ALTER TABLE accounts ADD COLUMN best_gold BIGINT NOT NULL DEFAULT 0, ADD COLUMN kills INT NOT NULL DEFAULT 0, ADD COLUMN deaths INT NOT NULL DEFAULT 0;
> ```

### 3. 构建

```bash
# 1. 复制配置文件
cp config.example.yaml config.yaml

# 2. 编译
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

### 4. 运行服务

```bash
./build/fakefish --config=config.yaml
```

服务端会启动：
- HTTP 服务：`http://127.0.0.1:8080`（托管前端）
- WebSocket 服务：`ws://127.0.0.1:8081`（游戏通信）

### 5. 开始游玩

打开现代浏览器访问：
```
http://127.0.0.1:8080
```
- 输入用户名、密码即可直接注册/登录进场。
- 使用 **WASD** 或 **方向键** 控制金币球移动。
- 拾取场景中的小金币豆增加金币和体型，体型大于其他玩家时可将其吞噬！

### 6. 运行自动化测试

```bash
npm install ws
node test_combat.js
node test_bots.js
```

---

## 许可与依赖

- 本仓库：[MIT License](LICENSE)
- 运行时与标准库：[esrrhs/fakelua](https://github.com/esrrhs/fakelua)
