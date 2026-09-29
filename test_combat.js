// FakeFish 大鱼吃小鱼真实对抗与吞噬结算测试

async function runCombatVerification() {
    console.log("=== [Combat E2E Test] Starting Hunter vs Prey Eat & Respawn Test ===");

    const wsHunter = new WebSocket("ws://127.0.0.1:8081/");
    const wsPrey = new WebSocket("ws://127.0.0.1:8081/");

    let hunterId = null;
    let preyId = null;
    let eatEvent = null;
    let diedEvent = null;

    await new Promise((resolve) => {
        let count = 0;
        const check = () => { count++; if (count === 2) resolve(); };
        wsHunter.onopen = check;
        wsPrey.onopen = check;
    });

    const hName = "Hunter_" + Math.floor(Math.random() * 10000);
    const pName = "Prey_" + Math.floor(Math.random() * 10000);

    wsHunter.send(JSON.stringify({ type: "register", username: hName, password: "123" }));
    wsPrey.send(JSON.stringify({ type: "register", username: pName, password: "123" }));

    // 等待登录
    await new Promise((resolve) => {
        let logins = 0;
        wsHunter.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "login_ok") { hunterId = d.player_id; logins++; if (logins === 2) resolve(); }
        });
        wsPrey.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "login_ok") { preyId = d.player_id; logins++; if (logins === 2) resolve(); }
        });
    });

    console.log(`✔ Hunter (ID: ${hunterId}) and Prey (ID: ${preyId}) logged in.`);

    let hunter = null;
    let prey = null;
    let foods = [];

    wsHunter.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "snapshot") {
            if (d.foods) foods = d.foods;
            for (const p of d.players) {
                if (p.id === hunterId) hunter = p;
                if (p.id === preyId) prey = p;
            }
        } else if (d.type === "eat") {
            eatEvent = d;
            console.log(`🎯 [Server Event] EAT TRIGGERED! Eater: ${d.eater_id}, Victim: ${d.victim_id}, Gain: +${d.gold}`);
        }
    });

    wsPrey.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "you_died") {
            diedEvent = d;
            console.log(`💀 [Server Event] YOU_DIED TRIGGERED! Victim respawned with ${d.gold} gold at (${d.x}, ${d.y})`);
        }
    });

    // 阶段 1：猎人先吃金币球使体型 > 猎物 (100 -> 125, 半径 40.0 -> 42.96 > 40*1.05=42.0)
    console.log("Phase 1: Hunter collecting pellets to grow bigger...");
    const pelletChase = setInterval(() => {
        if (!hunter || foods.length === 0) return;
        if (hunter.gold >= 125) return;

        // 找最近的金币
        let nearest = null;
        let minDist = 999999;
        for (const f of foods) {
            const dist = Math.hypot(f.x - hunter.x, f.y - hunter.y);
            if (dist < minDist) {
                minDist = dist;
                nearest = f;
            }
        }
        if (nearest) {
            const dx = nearest.x - hunter.x;
            const dy = nearest.y - hunter.y;
            const dist = Math.hypot(dx, dy);
            if (dist > 1) {
                wsHunter.send(JSON.stringify({ type: "move", dx: dx / dist, dy: dy / dist }));
            }
        }
    }, 50);

    // 等待猎人体型超过猎物 (阈值 125 gold)
    const p1Start = Date.now();
    while (Date.now() - p1Start < 12000) {
        if (hunter && hunter.gold >= 125) {
            console.log(`✔ Hunter grew to ${hunter.gold} gold (radius: ${hunter.r}) > Prey (${prey ? prey.gold : 100} gold)`);
            break;
        }
        await new Promise(r => setTimeout(r, 100));
    }
    clearInterval(pelletChase);

    // 阶段 2：猎物保持不动（确保不吃球增重），猎人直扑猎物
    console.log("Phase 2: Hunter chasing Prey (Prey stays still at origin)...");
    const hunterChase = setInterval(() => {
        if (!hunter || !prey) return;
        const dx = prey.x - hunter.x;
        const dy = prey.y - hunter.y;
        const dist = Math.hypot(dx, dy);
        if (dist > 5) {
            wsHunter.send(JSON.stringify({ type: "move", dx: dx / dist, dy: dy / dist }));
        }
    }, 50);

    const p2Start = Date.now();
    let lastLog = Date.now();
    while (Date.now() - p2Start < 25000) {
        if (eatEvent && diedEvent) {
            console.log("✔ Phase 2 Complete: Hunter devoured Prey successfully!");
            break;
        }
        if (Date.now() - lastLog > 2000) {
            lastLog = Date.now();
            if (hunter && prey) {
                const dist = Math.hypot(hunter.x - prey.x, hunter.y - prey.y).toFixed(1);
                console.log(`  -> Hunter (${hunter.x}, ${hunter.y}, gold=${hunter.gold}, r=${hunter.r}) chasing Prey (${prey.x}, ${prey.y}, gold=${prey.gold}, r=${prey.r}), dist=${dist}`);
            }
        }
        await new Promise(r => setTimeout(r, 100));
    }

    clearInterval(hunterChase);
    wsHunter.close();
    wsPrey.close();

    if (!eatEvent || !diedEvent) {
        console.error("Combat eat not completed in timeout, will check status.");
        process.exit(1);
    }

    console.log("=== [Combat E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runCombatVerification().catch(err => {
    console.error("Combat verification error:", err);
    process.exit(1);
});
