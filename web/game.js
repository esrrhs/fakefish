// FakeFish 前端客户端交互与渲染引擎

(function() {
    // 基础状态
    let ws = null;
    let localPlayerId = null;
    let myName = "";
    let mapInfo = { width: 2000, height: 2000 };
    let players = new Map(); // id -> { id, name, x, y, gold, r, color, targetX, targetY }
    let foods = []; // [ { x, y } ]
    let camera = { x: 1000, y: 1000 };
    let isConnected = false;
    let authMode = "login"; // 'login' or 'register'

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
                hudName.innerText = myName;
                showToast(`欢迎进入竞技场，${myName}！`, "success");
                requestRank();
                break;

            case "login_fail":
            case "register_fail":
                authError.innerText = msg.reason || "操作失败";
                authError.classList.remove("hidden");
                btnSubmit.disabled = false;
                btnSubmit.innerText = authMode === "login" ? "进入竞技场" : "注册并进场";
                break;

            case "rank":
                renderRank(msg.list || []);
                break;

            case "snapshot":
                handleSnapshot(msg.players || [], msg.foods || []);
                break;

            case "eat":
                handleEatEvent(msg);
                break;

            case "you_died":
                showToast(`你被吞噬了！已在安全区复活 (金币重置为 ${msg.gold || 100})`, "danger");
                if (msg.x !== undefined && msg.y !== undefined) {
                    camera.x = msg.x;
                    camera.y = msg.y;
                }
                break;

            case "pong":
                break;
        }
    }

    // 处理快照
    function handleSnapshot(playerList, foodList) {
        if (foodList && foodList.length > 0) {
            foods = foodList;
        }
        const currentIds = new Set();
        hudOnline.innerText = playerList.length;

        for (const p of playerList) {
            currentIds.add(p.id);
            let existing = players.get(p.id);
            if (!existing) {
                existing = {
                    id: p.id,
                    name: p.name || `Player_${p.id}`,
                    x: p.x,
                    y: p.y,
                    gold: p.gold,
                    r: p.r,
                    bot: !!p.bot,
                    color: p.color || getPlayerColor(p.id)
                };
                players.set(p.id, existing);
            } else {
                existing.targetX = p.x;
                existing.targetY = p.y;
                existing.gold = p.gold;
                existing.r = p.r;
                if (p.name) existing.name = p.name;
                if (p.color) existing.color = p.color;
                existing.bot = !!p.bot;
            }

            // 更新自己 HUD
            if (p.id === localPlayerId) {
                hudGold.innerText = p.gold;
                hudRadius.innerText = Math.round(p.r);
                hudPos.innerText = `(${Math.round(p.x)}, ${Math.round(p.y)})`;
            }
        }

        // 移除下线玩家
        for (const id of players.keys()) {
            if (!currentIds.has(id)) {
                players.delete(id);
            }
        }

        // 更新排行榜
        updateLeaderboard(playerList);
    }

    function updateLeaderboard(list) {
        const sorted = [...list].sort((a, b) => (b.gold || 0) - (a.gold || 0)).slice(0, 5);
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
            li.innerHTML = `<span class="lb-name">${idx + 1}. ${escapeHtml(item.name || "玩家")}</span><span class="lb-gold">${item.best_gold || 0}</span>`;
            if (item.name === myName) {
                li.style.color = "#38bdf8";
                li.style.fontWeight = "bold";
            }
            rankList.appendChild(li);
        });
    }

    function handleEatEvent(msg) {
        const eater = players.get(msg.eater_id);
        const victim = players.get(msg.victim_id);
        const goldGain = msg.gold || 0;

        if (eater) {
            addFloatingText(`+${goldGain} 金币!`, eater.x, eater.y - eater.r - 10, "#fbbf24", 20);
        }
        if (msg.eater_id === localPlayerId) {
            showToast(`你吃掉了 ${victim ? victim.name : "小球"}，获得 ${goldGain} 金币！`, "success");
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

    // 定期向服务器发送移动意图
    function updateInput() {
        if (!isConnected || !localPlayerId) return;

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

        // 摄像机平滑跟随本地玩家
        const me = players.get(localPlayerId);
        if (me) {
            camera.x += (me.x - camera.x) * 0.2;
            camera.y += (me.y - camera.y) * 0.2;
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

        // 3. 绘制地面积分金币
        drawFoods();

        // 4. 绘制所有玩家小球（按金币由小到大排序，大球覆盖在上方）
        const sortedPlayers = Array.from(players.values()).sort((a, b) => a.gold - b.gold);
        for (const p of sortedPlayers) {
            drawPlayer(p, p.id === localPlayerId);
        }

        // 5. 绘制漂浮文字特效
        drawFloatingTexts();

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
