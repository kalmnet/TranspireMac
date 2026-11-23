cmake_minimum_required(VERSION 3.20)
project(Transpire LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
include(FetchContent)
set(YSFX_PLUGIN OFF CACHE BOOL "" FORCE)
FetchContent_Declare(ysfx GIT_REPOSITORY https://github.com/JoepVanlier/ysfx.git
    GIT_TAG 5c3452fee62583aa3d1b7e877d0c758c4024af89)
FetchContent_MakeAvailable(ysfx)
add_library(Transpire MODULE Transpire.mm)
set_target_properties(Transpire PROPERTIES PREFIX "" BUNDLE TRUE BUNDLE_EXTENSION vst
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
target_compile_options(Transpire PRIVATE -fobjc-arc)
target_link_libraries(Transpire PRIVATE ysfx::ysfx "-framework Cocoa")
