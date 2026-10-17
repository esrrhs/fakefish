#include "fakelua.h"
#include <iostream>
#include <string>
#include <vector>
#include <filesystem>

using namespace fakelua;

int main(int argc, char **argv) {
    std::string config_path = "config.yaml";
    std::string script_path = "server/main.lua";
    int jit_type = static_cast<int>(JIT_GCC);

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg.rfind("--config=", 0) == 0) {
            config_path = arg.substr(9);
        } else if (arg.rfind("--script=", 0) == 0) {
            script_path = arg.substr(9);
        } else if (arg.rfind("--jit=", 0) == 0) {
            jit_type = std::stoi(arg.substr(6));
        } else if (arg == "--help" || arg == "-h") {
            std::cout << "FakeFish Game Server\n"
                      << "Usage: " << argv[0] << " [options]\n"
                      << "Options:\n"
                      << "  --config=FILE   Path to configuration YAML (default: config.yaml)\n"
                      << "  --script=FILE   Path to entry Lua script (default: server/main.lua)\n"
                      << "  --jit=TYPE      JIT type (0=TCC, 1=GCC, 2=Interp, default: 1)\n"
                      << "  --help, -h      Show this help message\n";
            return 0;
        }
    }

    std::cout << "[FakeFish] Starting with config: " << config_path
              << ", script: " << script_path << std::endl;

    const FakeluaStateGuard guard;
    const auto s = guard.GetState();
    if (!s) {
        std::cerr << "[FakeFish] Failed to initialize FakeLua State!" << std::endl;
        return 1;
    }

    CompileConfig cfg;
    cfg.debug_mode = false;
    // TCC 后端必须保持关闭：事件回调由 DispatchEvent 按 JIT_TCC 优先派发，一旦 TCC
    // 副本存在，回调就会跑在另一份编译产物上，看不到主循环的文件级状态（feed 等
    // 依赖回调写状态的模块会静默失效）。禁用后回调与 update 共用 GCC 副本。
    cfg.disable_jit[JIT_TCC] = true;

    // 热更支持：注册原生函数 host.compile_file，供 Lua 在主循环中触发单模块重编译。
    // fakelua 单线程模型下与主循环同线程重入编译是安全的；重编译会 Merge 替换同名函数地址，
    // 跨包调用经 FakeluaCallByName 运行时按名查找，即刻命中新版本。
    RegisterNativeFunction(s, "host.compile_file", 1, false,
                           [cfg](State *state, CVar *args, int n) -> CVar {
                               // 4=String, 5=StringId（见 fakelua VarType，公共头未暴露）
                               if (n < 1 || (args[0].type_ != 4 && args[0].type_ != 5)) {
                                   return inter::NativeToFakeluaBool(state, false);
                               }
                               const std::string path = inter::FakeluaToNativeString(state, args[0]);
                               try {
                                   CompileFile(state, path, cfg);
                                   return inter::NativeToFakeluaBool(state, true);
                               } catch (const std::exception &e) {
                                   std::cerr << "[FakeFish] hotfix compile failed for " << path
                                             << ": " << e.what() << std::endl;
                                   return inter::NativeToFakeluaBool(state, false);
                               }
                           });

    // 按依赖顺序预编译各核心逻辑模块
    const std::vector<std::string> module_files = {
        "server/config.lua",
        "server/combat.lua",
        "server/store.lua",
        "server/db.lua",
        "server/auth.lua",
        "server/world.lua",
        "server/bot.lua",
        "server/ledger.lua",
        "server/audit.lua",
        "server/webhook.lua",
        "server/metrics.lua",
        "server/redis_store.lua",
        "server/feed.lua",
        "server/motd.lua",
        "server/backup.lua",
        "server/admin.lua",
        "server/hotreload.lua",
        "server/net_ws.lua",
        "server/http_static.lua",
        script_path
    };

    for (const auto &file : module_files) {
        try {
            CompileFile(s, file, cfg);
        } catch (const std::exception &e) {
            std::cerr << "[FakeFish] Failed to compile script " << file
                      << ": " << e.what() << std::endl;
            return 1;
        }
    }

    // ---- flua 式生命周期：init 一次 -> update 每帧 -> fini 一次 ----
    //
    // 为什么必须每帧一次顶层 Call：fakelua 没有 GC，frame arena 只在「顶层 Call 进入、
    // 重入计数归零」时重置。旧实现是单次 Call 进 Main.start 后由 Lua 自己跑
    // `while true do runtime.tick() end`，arena 永远不重置，每帧产生的临时 table /
    // 字符串无界堆积（实测约 475KB/s，稳态不存在）。改由本宿主驱动帧边界后，帧内临时
    // 对象每帧回收，跨帧状态必须存放到 C++ 堆（见 server/store.lua）。

    int init_code = 0;
    try {
        Call(s, static_cast<JITType>(jit_type), "Main.init", init_code, config_path);
    } catch (const std::exception &e) {
        std::cerr << "[FakeFish] Runtime exception during Main.init: " << e.what() << std::endl;
        return 1;
    }
    if (init_code != 0) {
        std::cerr << "[FakeFish] Main.init returned " << init_code << ", exit" << std::endl;
        return init_code;
    }

    int exit_code = 0;
    try {
        while (true) {
            int update_code = 0;
            Call(s, static_cast<JITType>(jit_type), "Main.update", update_code);
            if (update_code != 0) {
                exit_code = update_code;
                break;
            }
        }
    } catch (const std::exception &e) {
        std::cerr << "[FakeFish] Runtime exception during Main.update: " << e.what() << std::endl;
        exit_code = 1;
    }

    try {
        int fini_code = 0;
        Call(s, static_cast<JITType>(jit_type), "Main.fini", fini_code);
        if (fini_code != 0 && exit_code == 0) exit_code = fini_code;
    } catch (const std::exception &e) {
        std::cerr << "[FakeFish] Runtime exception during Main.fini: " << e.what() << std::endl;
        exit_code = 1;
    }

    std::cout << "[FakeFish] Server exited with code: " << exit_code << std::endl;
    return exit_code;
}
