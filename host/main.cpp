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
        "server/db.lua",
        "server/auth.lua",
        "server/world.lua",
        "server/bot.lua",
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

    int code = 0;
    try {
        Call(s, static_cast<JITType>(jit_type), "Main.start", code, config_path);
    } catch (const std::exception &e) {
        std::cerr << "[FakeFish] Runtime exception during Main.start: " << e.what() << std::endl;
        return 1;
    }

    std::cout << "[FakeFish] Server exited with code: " << code << std::endl;
    return code;
}
