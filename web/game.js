// FakeFish 前端客户端交互与渲染引擎

(function() {
    // 基础状态
    let ws = null;
    let localPlayerId = null;
    let myName = "";
    let mapInfo = { width: 2000, height: 2000 };
    let players = new Map(); // id -> { id, name, x, y, gold, r, color, targetX, targetY }
    let foods = []; // [ { x, y } ]
    let powerups = []; // [ { x, y, kind } ]
    let camera = { x: 1000, y: 1000 };
    let isConnected = false;
    let authMode = "login"; // 'login' or 'register'
    let zone = null; // { x, y, r, phase, holding, next_in }

    // DOM 元素
    const canvas = document.getElementById("game-canvas");
    const ctx = canvas.getContext("2d");
    const authModal = document.getElementById("auth-modal");
    const tabLogin = document.getElementById("tab-login");
    const tabRegister = document.getElementById("tab-register");
    const authUsernameInput = document.getElementById("auth-username");
    const authPasswordInput = document.getElementById("auth-password");
    const btnSubmit = document.getElementById("btn-submit");
    const authError = document.getElementById("auth-error");

    const hud = document.getElementById("hud");
    const hudName = document.getElementById("hud-name");
    const hudGold = document.getElementById("hud-gold");
    const hudRadius = document.getElementById("hud-radius");
    const hudPos = document.getElementById("hud-pos");
    const hudOnline = document.getElementById("hud-online");

    const leaderboard = document.getElementById("leaderboard");
    const leaderboardList = document.getElementById("leaderboard-list");
    const rankList = document.getElementById("rank-list");
    const notificationBox = document.getElementById("notification-box");
    const zoneHud = document.getElementById("zone-hud");
    const zoneHudDetail = document.getElementById("zone-hud-detail");
    const dangerVignette = document.getElementById("danger-vignette");

    const chatBox = document.getElementById("chat-box");
    const chatMessages = document.getElementById("chat-messages");
    const chatInput = document.getElementById("chat-input");
    const chatSendBtn = document.getElementById("chat-send");

    // 控制输入状态
    const keys = { w: false, a: false, s: false, d: false, ArrowUp: false, ArrowLeft: false, ArrowDown: false, ArrowRight: false };
    let mousePos = { active: false, x: 0, y: 0 };
    let lastMoveSentTime = 0;
    let lastDx = 0, lastDy = 0;

    // 飘字与粒子特效
    const floatingTexts = []; // { text, x, y, alpha, color, size }

    // 初始化画布尺寸
    function resizeCanvas() {
        canvas.width = window.innerWidth;
        canvas.height = window.innerHeight;
    }
    window.addEventListener("resize", resizeCanvas);
    resizeCanvas();

    // 消息通知 Toast
    function showToast(msg, type = "normal") {
        const toast = document.createElement("div");
        toast.className = "toast " + (type === "danger" ? "toast-danger" : type === "success" ? "toast-success" : "");
        toast.innerText = msg;
        notificationBox.appendChild(toast);
        setTimeout(() => toast.remove(), 3500);
    }

    // 漂浮文字 (比如 "+100 Gold" / "EAT!")
    function addFloatingText(text, x, y, color = "#fbbf24", size = 18) {
        floatingTexts.push({ text, x, y, alpha: 1.0, color, size, vy: -1.2 });
    }

    // 标签页切换
    tabLogin.addEventListener("click", () => {
        authMode = "login";
        tabLogin.classList.add("active");
        tabRegister.classList.remove("active");
        btnSubmit.innerText = "进入竞技场";
        authError.classList.add("hidden");
    });

    tabRegister.addEventListener("click", () => {
        authMode = "register";
        tabRegister.classList.add("active");
        tabLogin.classList.remove("active");
        btnSubmit.innerText = "注册并进场";
        authError.classList.add("hidden");
    });

    // 提交认证
    btnSubmit.addEventListener("click", handleAuthSubmit);
    authPasswordInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter") handleAuthSubmit();
    });

    function handleAuthSubmit() {
        const username = authUsernameInput.value.trim();
        const password = authPasswordInput.value.trim();

        if (!username || !password) {
            authError.innerText = "请输入用户名和密码";
            authError.classList.remove("hidden");
            return;
        }

        myName = username;
        authError.classList.add("hidden");
        btnSubmit.disabled = true;
        btnSubmit.innerText = "连接中...";

        connectWebSocket(username, password);
    }

    // 连接 WebSocket
    function connectWebSocket(username, password) {
        if (ws && ws.readyState === WebSocket.OPEN) {
            sendAuth(username, password);
            return;
        }

        const wsPort = window.location.port ? 8081 : 8081;
        const wsHost = window.location.hostname || "127.0.0.1";
        const wsUrl = `ws://${wsHost}:${wsPort}/`;

        ws = new WebSocket(wsUrl);

        ws.onopen = () => {
            isConnected = true;
            sendAuth(username, password);
        };

        ws.onmessage = (event) => {
            try {
                const msg = JSON.parse(event.data);
                handleServerMessage(msg);
            } catch (err) {
                console.error("Failed to parse message:", event.data, err);
            }
        };

        ws.onclose = () => {
            isConnected = false;
            btnSubmit.disabled = false;
            btnSubmit.innerText = authMode === "login" ? "进入竞技场" : "注册并进场";
            showToast("与服务器连接已断开", "danger");
            authModal.classList.remove("hidden");
            hud.classList.add("hidden");
            leaderboard.classList.add("hidden");
            zoneHud.classList.add("hidden");
            dangerVignette.classList.remove("active");
            chatBox.classList.add("hidden");
            setChatOpen(false);
            chatMessages.innerHTML = "";
            zone = null;
        };

        ws.onerror = (err) => {
            console.error("WebSocket error:", err);
            authError.innerText = "连接服务器失败，请确认服务已启动 (8081)";
            authError.classList.remove("hidden");
            btnSubmit.disabled = false;
            btnSubmit.innerText = authMode === "login" ? "进入竞技场" : "注册并进场";
        };
    }

    function sendAuth(username, password) {
        const payload = {
            type: authMode,
            username: username,
            password: password
        };
        ws.send(JSON.stringify(payload));
    }

    // 协议消息处理
    function handleServerMessage(msg) {
        switch (msg.type) {
            case "login_ok":
                localPlayerId = msg.player_id;
                if (msg.map) {
                    mapInfo.width = msg.map.width || 2000;
                    mapInfo.height = msg.map.height || 2000;
                }
                authModal.classList.add("hidden");
                hud.classList.remove("hidden");
                leaderboard.classList.remove("hidden");
                chatBox.classList.remove("hidden");
                chatOpen = false;
                hudName.innerText = myName;
                showToast(`欢迎进入竞技场，${myName}！`, "success");
                requestRank();
                if (ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({ type: "get_chat" }));
                }
                break;

            case "login_fail":
            case "register_fail":
                authError.innerText = msg.reason || "操作失败";
                authError.classList.remove("hidden");
                btnSubmit.disabled = false;
                btnSubmit.innerText = authMode === "login" ? "进入竞技场" : "注册并进场";
                break;

            case "rank":
                // 空 Lua table 可能被编码成 {}（对象），视为空数组
                renderRank(Array.isArray(msg.list) ? msg.list : []);
                break;

            case "snapshot":
                handleSnapshot(msg.players || [], msg.foods || [], msg.powerups || [], msg.zone);
                break;

            case "zone":
                handleZoneEvent(msg);
                break;

            case "eat":
                handleEatEvent(msg);
                addKillFeed(msg);
                break;

            case "you_died":
                showToast(`你被吞噬了！已在安全区复活 (金币重置为 ${msg.gold || 100})`, "danger");
                if (msg.x !== undefined && msg.y !== undefined) {
                    camera.x = msg.x;
                    camera.y = msg.y;
                }
                break;

            case "powerup":
                handlePowerupEvent(msg);
                break;

            case "feast":
                handleFeastEvent(msg);
                break;

            case "pong":
                break;

            case "chat":
                appendChatMessage(msg);
                break;

            case "chat_history":
                renderChatHistory(Array.isArray(msg.list) ? msg.list : []);
                break;
        }
    }

    // 处理快照（每个细胞一条，以 "id:cell" 为键）
    function handleSnapshot(playerList, foodList, powerupList, zoneInfo) {
        if (foodList && foodList.length > 0) {
            foods = foodList;
        }
        if (powerupList) {
            powerups = powerupList;
        }
        if (zoneInfo) {
            zone = zoneInfo;
            zoneHud.classList.remove("hidden");
        }
        const currentKeys = new Set();
        hudOnline.innerText = new Set(playerList.map(p => p.id)).size;

        for (const p of playerList) {
            const key = p.id + ":" + (p.cell || 1);
            currentKeys.add(key);
            let existing = players.get(key);
            if (!existing) {
                existing = {
                    id: p.id,
                    cell: p.cell || 1,
                    name: p.name || `Player_${p.id}`,
                    x: p.x,
                    y: p.y,
                    gold: p.gold,
                    r: p.r,
                    bot: !!p.bot,
                    fx: p.fx || null,
                    color: getPlayerColor(p.id)
                };
                players.set(key, existing);
            } else {
                existing.targetX = p.x;
                existing.targetY = p.y;
                existing.gold = p.gold;
                existing.r = p.r;
                if (p.name) existing.name = p.name;
                existing.bot = !!p.bot;
                existing.fx = p.fx || null;
            }
        }

        // 移除消失的细胞
        for (const key of players.keys()) {
            if (!currentKeys.has(key)) {
                players.delete(key);
            }
        }

        // 自己的 HUD：金币按全部细胞求和，体型/坐标取最大细胞
        let myGold = 0;
        let myBig = null;
        for (const c of players.values()) {
            if (c.id === localPlayerId) {
                myGold = myGold + c.gold;
                if (myBig === null || c.r > myBig.r) myBig = c;
            }
        }
        hudGold.innerText = myGold;
        if (myBig !== null) {
            hudRadius.innerText = Math.round(myBig.r);
            hudPos.innerText = `(${Math.round(myBig.x)}, ${Math.round(myBig.y)})`;
        }

        // 更新排行榜
        updateLeaderboard(playerList);

        updateZoneHud();
    }

    // 安全区 HUD 文本 + 圈外红雾
    function updateZoneHud() {
        if (!zone) return;
        let action;
        if (zone.holding) {
            action = "最终收缩保持中";
        } else {
            action = `下次收缩 ${zone.next_in}s`;
        }
        zoneHudDetail.innerText = `第 ${zone.phase} 阶段 · ${action}`;

        // 任一自身细胞在圈外即显示危险红雾
        let anyOutside = false;
        for (const c of players.values()) {
            if (c.id === localPlayerId) {
                const dx = c.x - zone.x;
                const dy = c.y - zone.y;
                if ((dx * dx + dy * dy) > zone.r * zone.r) {
                    anyOutside = true;
                }
            }
        }
        if (anyOutside) {
            dangerVignette.classList.add("active");
        } else {
            dangerVignette.classList.remove("active");
        }
    }

    // 安全区收缩/重置事件：公告横幅 + 场景飘字
    function handleZoneEvent(msg) {
        zone = msg;
        zoneHud.classList.remove("hidden");
        updateZoneHud();

        const banner = document.getElementById("world-event");
        banner.classList.remove("fade-out");
        if (msg.reset) {
            banner.innerHTML = `🌀 安全区已重置！新的一轮开始了`;
        } else if (msg.holding) {
            banner.innerHTML = `⚠️ 安全区收缩到极限！最终对决开始`;
        } else {
            banner.innerHTML = `⚠️ 安全区收缩！第 ${msg.phase} 阶段，快向中心靠拢`;
        }
        banner.classList.remove("hidden");
        clearTimeout(handleZoneEvent._t1);
        clearTimeout(handleZoneEvent._t2);
        handleZoneEvent._t1 = setTimeout(() => banner.classList.add("fade-out"), 5000);
        handleZoneEvent._t2 = setTimeout(() => banner.classList.add("hidden"), 6200);
    }

    function updateLeaderboard(list) {
        // 快照按细胞下发，先按玩家聚合全部细胞金币
        const agg = new Map();
        for (const p of list) {
            let a = agg.get(p.id);
            if (!a) {
                a = { id: p.id, name: p.name, gold: 0, bot: !!p.bot };
                agg.set(p.id, a);
            }
            a.gold = a.gold + (p.gold || 0);
            if (p.name) a.name = p.name;
            a.bot = !!p.bot;
        }
        const sorted = [...agg.values()].sort((a, b) => b.gold - a.gold).slice(0, 5);
        leaderboardList.innerHTML = "";
        sorted.forEach((item, idx) => {
            const li = document.createElement("li");
            const displayName = (item.bot ? "🤖 " : "") + (item.name || "玩家");
            li.innerHTML = `<span class="lb-name">${idx + 1}. ${escapeHtml(displayName)}</span><span class="lb-gold">${item.gold}</span>`;
            if (item.id === localPlayerId) {
                li.style.color = "#38bdf8";
                li.style.fontWeight = "bold";
            }
            leaderboardList.appendChild(li);
        });
    }

    // 历史最佳排行（MySQL 持久化，每 10 秒刷新）
    function requestRank() {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: "get_rank", limit: 10 }));
        }
    }

    function renderRank(list) {
        rankList.innerHTML = "";
        list.forEach((item, idx) => {
            const li = document.createElement("li");
            const stats = `${item.best_gold || 0} · ⚔${item.kills || 0}`;
            li.innerHTML = `<span class="lb-name">${idx + 1}. ${escapeHtml(item.name || "玩家")}</span><span class="lb-gold">${stats}</span>`;
            if (item.name === myName) {
                li.style.color = "#38bdf8";
                li.style.fontWeight = "bold";
            }
            rankList.appendChild(li);
        });
    }

    // 按玩家 id 找到其最大细胞（快照细胞键为 "id:cell"）
    function findBiggestCellById(id) {
        let found = null;
        for (const c of players.values()) {
            if (c.id === id && (found === null || c.r > found.r)) found = c;
        }
        return found;
    }

    // ---- 世界聊天 ----

    const CHAT_MAX_VISIBLE = 8;  // 面板最多同时显示条数
    let chatOpen = false;        // 输入框是否激活（激活时键盘不驱动移动）

    // 追加一条气泡到面板
    function appendChatMessage(msg) {
        const item = document.createElement("div");
        item.className = "chat-line";
        const name = document.createElement("span");
        name.className = "chat-name";
        name.innerText = (msg.name || "玩家") + ":";
        const text = document.createElement("span");
        text.className = "chat-text";
        text.innerText = msg.content || "";
        item.appendChild(name);
        item.appendChild(text);
        if (msg.name === myName) item.classList.add("chat-mine");
        chatMessages.appendChild(item);
        while (chatMessages.children.length > CHAT_MAX_VISIBLE) {
            chatMessages.removeChild(chatMessages.firstChild);
        }
        // 新消息短暂高亮面板（输入框关闭时也能注意到）
        chatBox.classList.add("chat-buzz");
        clearTimeout(appendChatMessage._t);
        appendChatMessage._t = setTimeout(() => chatBox.classList.remove("chat-buzz"), 600);
    }

    // 登录后渲染服务端下发的最近历史
    function renderChatHistory(list) {
        chatMessages.innerHTML = "";
        for (const m of list) {
            appendChatMessage({ name: m.name, content: m.content });
        }
    }

    // 打开/关闭聊天输入
    function setChatOpen(open) {
        chatOpen = open;
        if (open) {
            chatInput.value = "";
            chatInput.focus();
        } else {
            chatInput.blur();
            window.focus();
        }
    }

    // 发送当前输入内容
    function sendChat() {
        const text = chatInput.value.trim();
        if (text && ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: "chat", content: text }));
        }
        chatInput.value = "";
        if (chatOpen) setChatOpen(false);
    }

    function handleEatEvent(msg) {
        const eater = findBiggestCellById(msg.eater_id);
        const victim = findBiggestCellById(msg.victim_id);
        const goldGain = msg.gold || 0;

        if (eater) {
            addFloatingText(`+${goldGain} 金币!`, eater.x, eater.y - eater.r - 10, "#fbbf24", 20);
        }
        if (msg.eater_id === localPlayerId) {
            const what = msg.partial ? "对方一个细胞" : (msg.victim_name || (victim ? victim.name : "小球"));
            showToast(`你吃掉了 ${what}，获得 ${goldGain} 金币！`, "success");
        }
    }

    // 击杀播报：顶部居中事件流，保留最近 5 条，6 秒后淡出
    function addKillFeed(msg) {
        const killFeed = document.getElementById("kill-feed");
        killFeed.classList.remove("hidden");
        const entry = document.createElement("div");
        entry.className = "feed-entry";
        const eaterName = msg.eater_name || `Player_${msg.eater_id}`;
        const victimName = msg.victim_name || `Player_${msg.victim_id}`;
        entry.innerHTML = `<span class="feed-eater">${escapeHtml(eaterName)}</span>`
            + ` 🍽️ <span class="feed-victim">${escapeHtml(victimName)}</span>`
            + ` <span class="feed-gold">+${msg.gold || 0}</span>`;
        if (msg.eater_id === localPlayerId) entry.classList.add("feed-mine");
        killFeed.appendChild(entry);
        while (killFeed.children.length > 5) {
            killFeed.removeChild(killFeed.firstChild);
        }
        setTimeout(() => {
            entry.classList.add("feed-fade");
            setTimeout(() => entry.remove(), 800);
        }, 6000);
    }

    // 道具拾取事件
    const FX_META = {
        speed: { icon: "⚡", color: "#34d399", label: "加速" },
        shield: { icon: "🛡️", color: "#60a5fa", label: "护盾" },
        magnet: { icon: "🧲", color: "#f472b6", label: "磁铁" }
    };

    function handlePowerupEvent(msg) {
        const meta = FX_META[msg.kind] || { icon: "✨", color: "#fff", label: msg.kind };
        const who = msg.name || `Player_${msg.player_id}`;

        if (msg.player_id === localPlayerId) {
            showToast(`拾取道具：${meta.icon} ${meta.label}！`, "success");
        }

        const owner = players.get(msg.player_id);
        if (owner) {
            addFloatingText(`${meta.icon} ${meta.label}`, owner.x, owner.y - owner.r - 28, meta.color, 16);
        } else if (msg.player_id !== localPlayerId) {
            console.log(`[powerup] ${who} picked ${msg.kind}`);
        }
    }

    // 金币雨公告：横幅 + 场景飘字
    function handleFeastEvent(msg) {
        const banner = document.getElementById("world-event");
        banner.innerHTML = `💰 金币雨！地图 (${Math.round(msg.x)}, ${Math.round(msg.y)}) 附近散落 ${msg.count || 0} 枚金币豆`;
        banner.classList.remove("hidden");
        banner.classList.remove("fade-out");
        clearTimeout(handleFeastEvent._t1);
        clearTimeout(handleFeastEvent._t2);
        handleFeastEvent._t1 = setTimeout(() => banner.classList.add("fade-out"), 6000);
        handleFeastEvent._t2 = setTimeout(() => banner.classList.add("hidden"), 7200);
        if (msg.x !== undefined) {
            addFloatingText(`💰 金币雨！`, msg.x, msg.y - 40, "#fbbf24", 22);
        }
    }

    function getPlayerColor(id) {
        const colors = [
            "#38bdf8", "#ec4899", "#8b5cf6", "#10b981", 
            "#f59e0b", "#6366f1", "#14b8a6", "#ef4444"
        ];
        return colors[Math.abs(id) % colors.length];
    }

    function escapeHtml(str) {
        return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // 键盘与鼠标输入控制
    window.addEventListener("keydown", (e) => {
        if (keys.hasOwnProperty(e.key)) keys[e.key] = true;
        // 空格：分裂（按住不重复触发；阻止页面滚动）
        if (e.code === "Space" && !e.repeat && isConnected && localPlayerId
            && ws && ws.readyState === WebSocket.OPEN) {
            e.preventDefault();
            ws.send(JSON.stringify({ type: "split" }));
        }
    });

    window.addEventListener("keyup", (e) => {
        if (keys.hasOwnProperty(e.key)) keys[e.key] = false;
    });

    canvas.addEventListener("mousemove", (e) => {
        mousePos.active = true;
        mousePos.x = e.clientX;
        mousePos.y = e.clientY;
    });

    canvas.addEventListener("mouseleave", () => {
        mousePos.active = false;
    });

    // ---- 聊天事件绑定 ----

    chatSendBtn.addEventListener("click", sendChat);

    // 输入框内：Enter 发送、Esc 关闭
    chatInput.addEventListener("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
            e.preventDefault();
            sendChat();
        } else if (e.key === "Escape") {
            e.preventDefault();
            setChatOpen(false);
        }
    });

    // 聊天框未激活时：Enter 打开聊天（避免与移动键冲突）
    window.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !chatOpen && isConnected && localPlayerId) {
            const tag = document.activeElement && document.activeElement.tagName;
            if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "BUTTON") {
                e.preventDefault();
                setChatOpen(true);
            }
        }
    });

    // 快捷表情：事件委托读取 data-text，直接发送
    document.getElementById("chat-quick").addEventListener("click", (e) => {
        const btn = e.target.closest(".chat-emote");
        if (btn && btn.dataset.text) {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type: "chat", content: btn.dataset.text }));
            }
        }
    });

    // 定期向服务器发送移动意图
    function updateInput() {
        if (!isConnected || !localPlayerId) return;

        // 聊天输入激活时停止上报移动，避免按键被当成移动指令
        if (chatOpen) {
            if (lastDx ~= 0 || lastDy ~= 0) {
                lastDx = 0;
                lastDy = 0;
                ws.send(JSON.stringify({ type: "move", dx: 0, dy: 0 }));
            }
            return;
        }

        let dx = 0;
        let dy = 0;

        const up = keys.w || keys.ArrowUp;
        const down = keys.s || keys.ArrowDown;
        const left = keys.a || keys.ArrowLeft;
        const right = keys.d || keys.ArrowRight;

        if (up) dy -= 1;
        if (down) dy += 1;
        if (left) dx -= 1;
        if (right) dx += 1;

        // 如果键盘无输入，则采用鼠标方向
        if (dx === 0 && dy === 0 && mousePos.active) {
            const centerX = canvas.width / 2;
            const centerY = canvas.height / 2;
            const mx = mousePos.x - centerX;
            const my = mousePos.y - centerY;
            const dist = Math.hypot(mx, my);
            if (dist > 30) {
                dx = mx / dist;
                dy = my / dist;
            }
        } else if (dx !== 0 || dy !== 0) {
            const dist = Math.hypot(dx, dy);
            dx /= dist;
            dy /= dist;
        }

        const now = Date.now();
        // 如果方向发生变化或每 50ms 上报一次
        const dirChanged = (Math.abs(dx - lastDx) > 0.05 || Math.abs(dy - lastDy) > 0.05);
        if (dirChanged || (now - lastMoveSentTime >= 50)) {
            lastDx = dx;
            lastDy = dy;
            lastMoveSentTime = now;
            ws.send(JSON.stringify({
                type: "move",
                dx: Math.round(dx * 1000) / 1000,
                dy: Math.round(dy * 1000) / 1000
            }));
        }
    }

    // 维持心跳与历史排行刷新
    setInterval(() => {
        if (isConnected && ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: "ping" }));
        }
    }, 5000);

    setInterval(() => {
        if (isConnected && localPlayerId) {
            requestRank();
        }
    }, 10000);

    // 渲染主循环
    function renderLoop() {
        requestAnimationFrame(renderLoop);
        updateInput();

        // 平滑插值更新玩家坐标
        for (const p of players.values()) {
            if (p.targetX !== undefined) {
                p.x += (p.targetX - p.x) * 0.35;
                p.y += (p.targetY - p.y) * 0.35;
            }
        }

        // 摄像机平滑跟随本地玩家全部细胞的质心
        let sx = 0, sy = 0, sn = 0;
        for (const c of players.values()) {
            if (c.id === localPlayerId) {
                sx += c.x;
                sy += c.y;
                sn += 1;
            }
        }
        if (sn > 0) {
            camera.x += (sx / sn - camera.x) * 0.2;
            camera.y += (sy / sn - camera.y) * 0.2;
        }

        // 清屏
        ctx.clearRect(0, 0, canvas.width, canvas.height);

        ctx.save();
        // 移动画布到摄像机视角
        ctx.translate(canvas.width / 2 - camera.x, canvas.height / 2 - camera.y);

        // 1. 绘制网格背景
        drawGrid();

        // 2. 绘制地图边界
        drawBorders();

        // 2.5 绘制安全区与圈外危险区域
        drawZone();

        // 3. 绘制地面积分金币
        drawFoods();

        // 3.5 绘制道具
        drawPowerups();

        // 4. 绘制所有玩家小球（按金币由小到大排序，大球覆盖在上方）
        const sortedPlayers = Array.from(players.values()).sort((a, b) => a.gold - b.gold);
        for (const p of sortedPlayers) {
            drawPlayer(p, p.id === localPlayerId);
        }

        // 5. 绘制漂浮文字特效
        drawFloatingTexts();

        ctx.restore();
    }

    function drawZone() {
        if (!zone) return;
        ctx.save();

        // 圈外危险区域：巨矩形 + 安全圆，evenodd 填充只覆盖圆外部分
        ctx.beginPath();
        ctx.rect(-5000, -5000, 25000, 25000);
        ctx.arc(zone.x, zone.y, zone.r, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(239, 68, 68, 0.13)";
        ctx.fill("evenodd");

        // 安全区边界：收缩阶段青色、最终保持阶段红色脉动
        const pulse = zone.holding ? (0.55 + 0.45 * Math.sin(Date.now() / 250)) : 1;
        ctx.beginPath();
        ctx.arc(zone.x, zone.y, zone.r, 0, Math.PI * 2);
        ctx.strokeStyle = zone.holding ? `rgba(239,68,68,${pulse})` : "rgba(96,165,250,0.9)";
        ctx.lineWidth = 4;
        ctx.shadowColor = zone.holding ? "#ef4444" : "#60a5fa";
        ctx.shadowBlur = 16;
        ctx.stroke();

        ctx.restore();
    }

    function drawFoods() {
        ctx.save();
        for (const f of foods) {
            ctx.beginPath();
            ctx.arc(f.x, f.y, 6, 0, Math.PI * 2);
            ctx.fillStyle = "#fbbf24";
            ctx.shadowColor = "#f59e0b";
            ctx.shadowBlur = 8;
            ctx.fill();
        }
        ctx.restore();
    }

    function drawPowerups() {
        for (const pw of powerups) {
            const meta = FX_META[pw.kind] || { icon: "✨", color: "#fff" };
            ctx.save();
            // 旋转菱形底座
            ctx.translate(pw.x, pw.y);
            ctx.rotate(Date.now() / 600 % (Math.PI * 2));
            ctx.beginPath();
            ctx.moveTo(0, -13);
            ctx.lineTo(13, 0);
            ctx.lineTo(0, 13);
            ctx.lineTo(-13, 0);
            ctx.closePath();
            ctx.fillStyle = "rgba(15, 23, 42, 0.9)";
            ctx.strokeStyle = meta.color;
            ctx.lineWidth = 2.5;
            ctx.shadowColor = meta.color;
            ctx.shadowBlur = 14;
            ctx.fill();
            ctx.stroke();
            ctx.restore();

            // 图标（不随旋转）
            ctx.save();
            ctx.font = "14px sans-serif";
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.fillText(meta.icon, pw.x, pw.y + 1);
            ctx.restore();
        }
    }

    function drawGrid() {
        const gridSize = 60;
        const startX = Math.floor((camera.x - canvas.width / 2) / gridSize) * gridSize;
        const endX = startX + canvas.width + gridSize * 2;
        const startY = Math.floor((camera.y - canvas.height / 2) / gridSize) * gridSize;
        const endY = startY + canvas.height + gridSize * 2;

        ctx.strokeStyle = "rgba(255, 255, 255, 0.04)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        for (let x = startX; x <= endX; x += gridSize) {
            ctx.moveTo(x, startY);
            ctx.lineTo(x, endY);
        }
        for (let y = startY; y <= endY; y += gridSize) {
            ctx.moveTo(startX, y);
            ctx.lineTo(endX, y);
        }
        ctx.stroke();
    }

    function drawBorders() {
        ctx.strokeStyle = "#ef4444";
        ctx.lineWidth = 4;
        ctx.strokeRect(0, 0, mapInfo.width, mapInfo.height);

        // 边角装饰点
        ctx.fillStyle = "rgba(239, 68, 68, 0.1)";
        ctx.fillRect(-10, -10, mapInfo.width + 20, mapInfo.height + 20);
    }

    function drawPlayer(p, isMe) {
        ctx.save();
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);

        // 球体填充颜色渐变
        const gradient = ctx.createRadialGradient(
            p.x - p.r * 0.3, p.y - p.r * 0.3, p.r * 0.1,
            p.x, p.y, p.r
        );
        gradient.addColorStop(0, "#ffffff");
        gradient.addColorStop(0.3, p.color);
        gradient.addColorStop(1, shadeColor(p.color, -30));

        ctx.fillStyle = gradient;
        ctx.shadowColor = p.color;
        ctx.shadowBlur = isMe ? 20 : 10;
        ctx.fill();

        // 自身外发光光环
        if (isMe) {
            ctx.lineWidth = 3;
            ctx.strokeStyle = "#ffffff";
            ctx.stroke();
        }

        // 道具特效光环
        if (p.fx && FX_META[p.fx]) {
            ctx.beginPath();
            ctx.arc(p.x, p.y, p.r + 6, 0, Math.PI * 2);
            ctx.strokeStyle = FX_META[p.fx].color;
            ctx.lineWidth = 2;
            ctx.setLineDash([6, 4]);
            ctx.stroke();
            ctx.setLineDash([]);
        }

        ctx.shadowBlur = 0;

        // 绘制昵称
        ctx.fillStyle = "#ffffff";
        ctx.font = `bold ${Math.max(12, Math.min(18, p.r * 0.5))}px sans-serif`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(p.bot ? `🤖 ${p.name}` : p.name, p.x, p.y - p.r - 12);

        // 绘制球体中心的金币数值
        ctx.fillStyle = "#fbbf24";
        ctx.font = `bold ${Math.max(11, Math.min(16, p.r * 0.45))}px sans-serif`;
        ctx.fillText(`🪙 ${p.gold}`, p.x, p.y);

        ctx.restore();
    }

    function drawFloatingTexts() {
        for (let i = floatingTexts.length - 1; i >= 0; i--) {
            const ft = floatingTexts[i];
            ft.y += ft.vy;
            ft.alpha -= 0.02;
            if (ft.alpha <= 0) {
                floatingTexts.splice(i, 1);
                continue;
            }
            ctx.save();
            ctx.globalAlpha = Math.max(0, ft.alpha);
            ctx.fillStyle = ft.color;
            ctx.font = `bold ${ft.size}px sans-serif`;
            ctx.textAlign = "center";
            ctx.fillText(ft.text, ft.x, ft.y);
            ctx.restore();
        }
    }

    function shadeColor(color, percent) {
        let R = parseInt(color.substring(1, 3), 16);
        let G = parseInt(color.substring(3, 5), 16);
        let B = parseInt(color.substring(5, 7), 16);
        R = parseInt(R * (100 + percent) / 100);
        G = parseInt(G * (100 + percent) / 100);
        B = parseInt(B * (100 + percent) / 100);
        R = (R < 255) ? R : 255;
        G = (G < 255) ? G : 255;
        B = (B < 255) ? B : 255;
        return "#" + ((1 << 24) + (R << 16) + (G << 8) + B).toString(16).slice(1);
    }

    // 启动动画循环
    renderLoop();
})();
