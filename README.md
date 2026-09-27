# FakeFish

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
| `created_at` / `updated_at` | DATETIME | 时间戳 |

- **注册**：用户名不存在则插入，初始 `gold = initial_gold`。
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
| `error` | `reason` | 通用错误 |

`players[]` 元素示例：`{ id, name, x, y, gold, r }`。前端据此画圆、标金币/昵称。

### 7. 服务器模块划分（FakeLua）

| 模块 | 职责 |
|------|------|
| `main` | 读配置、初始化 MySQL/WS/HTTP、进入 tick 循环 |
| `config` | 解析 YAML/TOML/INI（fakelua 已有），暴露端口、地图、公式参数 |
| `db` | 账号查询/插入/更新金币 |
| `auth` | 注册登录、会话绑定 `connid ↔ player` |
| `world` | 玩家实体表、移动积分、边界 |
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

### Phase 0 — 仓库与脚手架（当前）

- [x] GitHub 仓库重命名：`fake_game_server` → **`fakefish`**
- [x] 清空旧 C++/fake 多进程框架代码
- [x] 本设计文档与开发计划写入 README
- [ ] 接入 `esrrhs/fakelua`（CPM / git submodule）
- [ ] 最小可运行入口：加载配置 → 打印 → `runtime.tick` 空循环
- [ ] `.gitignore`、目录约定、`config.example.yaml`

**建议目录：**

```
fakefish/
  README.md
  config.example.yaml
  sql/schema.sql
  server/                 # FakeLua 业务脚本
    main.lua
    config.lua
    db.lua
    auth.lua
    world.lua
    combat.lua
    net_ws.lua
  web/                    # 静态前端
    index.html
    game.js
    style.css
  third_party/fakelua/    # 或 CPM 拉取
  CMakeLists.txt          # 可选：包装 flua/自定义 host
```

### Phase 1 — 基础设施

- [ ] MySQL schema + 连接/连接池封装
- [ ] 注册 / 登录（含密码哈希）
- [ ] WebSocket 握手与 JSON 路由骨架
- [ ] HTTP 托管 `web/`（或开发期用任意静态服务器）

### Phase 2 — 世界与玩法

- [ ] 玩家进场：按金币算半径、随机出生点
- [ ] 移动积分 + 地图边界
- [ ] 碰撞检测 + 吃球 + 复活
- [ ] 状态广播（全量 snapshot 或增量）
- [ ] 金币回写 MySQL（节流 + 断线落盘）

### Phase 3 — 前端可玩

- [ ] 登录/注册 UI
- [ ] Canvas 渲染球、昵称、金币
- [ ] 输入 → `move`；处理 `snapshot` / `eat` / `you_died`
- [ ] 断线重连提示（可选）

### Phase 4 — 打磨

- [ ] 参数调优（速度、半径公式、地图大小）
- [ ] 基础反作弊：速度钳制、包频率限制
- [ ] README 运行说明、Docker Compose（MySQL + server，可选）
- [ ] 简单压测 / 多开浏览器互吃验证

### 里程碑验收

1. **M1**：空服启动 + 连上 MySQL + WS echo  
2. **M2**：两人登录进场，移动可见  
3. **M3**：大吃小、金币变化、复活、刷新页面金币仍在  
4. **M4**：陌生人打开 webpage 即可开玩（文档齐全）

---

## 快速开始（实现后）

```bash
# 1. 准备 MySQL，执行 sql/schema.sql
# 2. 复制并编辑配置
cp config.example.yaml config.yaml

# 3. 构建 / 运行（依赖 fakelua）
# cmake -S . -B build && cmake --build build --parallel
# ./build/fakefish --config=config.yaml

# 4. 浏览器打开 http://127.0.0.1:8080
```

（脚手架与可执行入口将在 Phase 0/1 落地。）

---

## 许可与依赖

- 本仓库：[MIT License](LICENSE)
- 运行时与标准库：[esrrhs/fakelua](https://github.com/esrrhs/fakelua)
