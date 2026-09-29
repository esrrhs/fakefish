cmake_minimum_required(VERSION 3.20 FATAL_ERROR)

project(fakefish CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 查找系统已安装的 fakelua
find_package(fakelua REQUIRED)

add_executable(fakefish host/main.cpp)

# 链接目标（推荐使用命名空间目标 fakelua::fakelua）
# 链接后会自动带上 include 目录和依赖参数
target_link_libraries(fakefish PRIVATE fakelua::fakelua)

# 开启导出动态符号（以便 Lua JIT 代码回调宿主 C 函数）
set_target_properties(fakefish PROPERTIES ENABLE_EXPORTS ON)
