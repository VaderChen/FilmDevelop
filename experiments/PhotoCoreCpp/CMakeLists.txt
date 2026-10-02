cmake_minimum_required(VERSION 3.20)
project(PhotoCoreCpp VERSION 0.1.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
option(PHOTOCORE_SANITIZE "啟用記憶體及未定義行為檢查" OFF)
option(PHOTOCORE_VULKAN_SMOKE "建置獨立 Vulkan unmix Smoke，不整合正式 CPU 流程" OFF)
option(PHOTOCORE_VULKAN_APP "建置 App 共用 C ABI 後端" OFF)
option(PHOTOCORE_VULKAN_FILM "建置獨立 Vulkan 底片／顯影／掃描常駐流程" OFF)
add_library(photocore src/core.cpp src/pfm.cpp)
target_include_directories(photocore PUBLIC include)
if(MSVC)
  target_compile_options(photocore PUBLIC /W4 /permissive- /fp:precise /utf-8)
else()
  target_compile_options(photocore PUBLIC -Wall -Wextra -Wpedantic -fno-fast-math -ffp-contract=off)
  if(PHOTOCORE_SANITIZE)
    target_compile_options(photocore PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(photocore PUBLIC -fsanitize=address,undefined)
  endif()
endif()

if(PHOTOCORE_VULKAN_FILM OR PHOTOCORE_VULKAN_APP)
  find_package(Vulkan REQUIRED)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_program(PHOTOCORE_GLSLANG NAMES glslangValidator glslang REQUIRED)
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/prepare_vulkan_recipe.py"
      "${CMAKE_CURRENT_SOURCE_DIR}/src/film.cpp" "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp"
    DEPENDS src/film.cpp tools/prepare_vulkan_recipe.py VERBATIM)
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv"
    COMMAND "${PHOTOCORE_GLSLANG}" -V --target-env vulkan1.1
      "${CMAKE_CURRENT_SOURCE_DIR}/vulkan/film.comp" -o "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv"
    DEPENDS vulkan/film.comp vulkan/optics.glsl vulkan/digital.glsl vulkan/camera.glsl vulkan/skin.glsl VERBATIM)
  # 共用產物只有一個生成目標，避免平行建置兩個執行檔時同時覆寫 shader／解析器。
  add_custom_target(photo_core_vulkan_generated DEPENDS
    "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv" "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp")
  add_executable(photo_core_vulkan_film vulkan/main.cpp vulkan/runtime.cpp vulkan/pipeline.cpp vulkan/optics.cpp vulkan/digital.cpp
    src/film_data.cpp "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp")
  target_include_directories(photo_core_vulkan_film PRIVATE src vulkan)
  target_include_directories(photo_core_vulkan_film SYSTEM PRIVATE third_party)
  target_link_libraries(photo_core_vulkan_film PRIVATE photocore Vulkan::Vulkan)
  add_dependencies(photo_core_vulkan_film photo_core_film_assets photo_core_vulkan_generated)
  add_test(NAME vulkan_film_help COMMAND photo_core_vulkan_film --help)
  add_test(NAME vulkan_film_cli_smoke COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/film_cli_smoke.py"
    $<TARGET_FILE:photo_core_vulkan_film>)
  add_executable(photo_core_vulkan_verify vulkan/verify.cpp vulkan/runtime.cpp vulkan/pipeline.cpp vulkan/optics.cpp vulkan/digital.cpp
    src/film_data.cpp "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp")
  target_include_directories(photo_core_vulkan_verify PRIVATE src vulkan)
  target_include_directories(photo_core_vulkan_verify SYSTEM PRIVATE third_party)
  target_link_libraries(photo_core_vulkan_verify PRIVATE photocore Vulkan::Vulkan)
  add_dependencies(photo_core_vulkan_verify photo_core_film_assets photo_core_vulkan_generated)
  add_test(NAME vulkan_core_invariants COMMAND photo_core_vulkan_verify)
  add_executable(photo_core_vulkan_lifetime verification/vulkan_lifetime.cpp)
  target_include_directories(photo_core_vulkan_lifetime PRIVATE vulkan)
  target_link_libraries(photo_core_vulkan_lifetime PRIVATE photocore Vulkan::Vulkan)
  add_dependencies(photo_core_vulkan_lifetime photo_core_vulkan_generated)
  add_test(NAME vulkan_resource_lifetime COMMAND photo_core_vulkan_lifetime
    "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv")
  add_executable(photo_core_vulkan_stage_benchmark vulkan/stage_benchmark.cpp vulkan/runtime.cpp
    vulkan/pipeline.cpp vulkan/optics.cpp vulkan/digital.cpp src/film_data.cpp "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp")
  target_include_directories(photo_core_vulkan_stage_benchmark PRIVATE src vulkan)
  target_include_directories(photo_core_vulkan_stage_benchmark SYSTEM PRIVATE third_party)
  target_link_libraries(photo_core_vulkan_stage_benchmark PRIVATE photocore_film Vulkan::Vulkan)
  add_dependencies(photo_core_vulkan_stage_benchmark photo_core_film_assets photo_core_vulkan_generated)
endif()
add_executable(photo_core_test src/main.cpp)
target_link_libraries(photo_core_test PRIVATE photocore)
if(MINGW)
  target_link_options(photo_core_test PRIVATE -municode)
endif()
add_executable(photo_core_verify verification/verify.cpp)
target_link_libraries(photo_core_verify PRIVATE photocore)
enable_testing()
add_test(NAME core_invariants COMMAND photo_core_verify)
add_test(NAME cli_help COMMAND photo_core_test --help)
add_test(NAME cli_bad_option COMMAND photo_core_test --invalid)
set_tests_properties(cli_bad_option PROPERTIES WILL_FAIL TRUE)

add_executable(photo_core_compare verification/compare.cpp verification/delta_e.cpp)
target_link_libraries(photo_core_compare PRIVATE photocore)
if(MINGW)
  target_link_options(photo_core_compare PRIVATE -municode)
endif()
add_test(NAME ciede2000_standard COMMAND photo_core_compare --self-test
  "${CMAKE_CURRENT_SOURCE_DIR}/verification/data/ciede2000.txt")

find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND AND NOT CMAKE_CROSSCOMPILING)
  add_test(NAME delta_e_image_smoke COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/delta_e_smoke.py" $<TARGET_FILE:photo_core_compare>)
  add_test(NAME pipeline_gate_smoke COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/pipeline_gate_smoke.py"
    $<TARGET_FILE:photo_core_test> $<TARGET_FILE:photo_core_compare>)
endif()

add_library(photocore_film src/film.cpp src/film_data.cpp src/film_image.cpp
  src/film_development.cpp src/film_spectral.cpp src/film_scanner.cpp src/film_optics.cpp src/film_digital.cpp)
target_link_libraries(photocore_film PUBLIC photocore)
target_include_directories(photocore_film SYSTEM PRIVATE third_party)
add_executable(photo_core_film src/film_main.cpp)
target_link_libraries(photo_core_film PRIVATE photocore_film)
if(MINGW)
  target_link_options(photo_core_film PRIVATE -municode)
endif()
add_custom_target(photo_core_film_assets
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/data" "$<TARGET_FILE_DIR:photo_core_film>/film-data"
  COMMENT "同步獨立 CPU 底片資料")
add_dependencies(photo_core_film photo_core_film_assets)
add_test(NAME film_cli_help COMMAND photo_core_film --help)
add_executable(photo_core_film_verify verification/film_verify.cpp)
target_include_directories(photo_core_film_verify PRIVATE src)
target_include_directories(photo_core_film_verify SYSTEM PRIVATE third_party)
target_link_libraries(photo_core_film_verify PRIVATE photocore_film)
add_test(NAME film_invariants COMMAND photo_core_film_verify)
if(Python3_Interpreter_FOUND AND NOT CMAKE_CROSSCOMPILING)
  add_test(NAME film_cli_smoke COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/film_cli_smoke.py"
    $<TARGET_FILE:photo_core_film>)
endif()

if(PHOTOCORE_VULKAN_SMOKE)
  find_package(Vulkan REQUIRED)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_program(PHOTOCORE_GLSLANG NAMES glslangValidator glslang REQUIRED)
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/spectral-smoke.cpp"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/prepare_vulkan_smoke.py"
      "${CMAKE_CURRENT_SOURCE_DIR}/src/film_spectral.cpp" "${CMAKE_CURRENT_BINARY_DIR}/spectral-smoke.cpp"
    DEPENDS src/film_spectral.cpp tools/prepare_vulkan_smoke.py VERBATIM)
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/unmix.comp.spv"
    COMMAND "${PHOTOCORE_GLSLANG}" -V --target-env vulkan1.1
      "${CMAKE_CURRENT_SOURCE_DIR}/vulkan_smoke/unmix.comp" -o "${CMAKE_CURRENT_BINARY_DIR}/unmix.comp.spv"
    DEPENDS vulkan_smoke/unmix.comp VERBATIM)
  add_executable(photo_core_vulkan_smoke vulkan_smoke/main.cpp vulkan_smoke/runtime.cpp
    "${CMAKE_CURRENT_BINARY_DIR}/spectral-smoke.cpp" verification/delta_e.cpp
    "${CMAKE_CURRENT_BINARY_DIR}/unmix.comp.spv")
  target_include_directories(photo_core_vulkan_smoke PRIVATE src verification vulkan_smoke)
  target_include_directories(photo_core_vulkan_smoke SYSTEM PRIVATE third_party)
  target_link_libraries(photo_core_vulkan_smoke PRIVATE photocore_film Vulkan::Vulkan)
  add_dependencies(photo_core_vulkan_smoke photo_core_film_assets)
  add_test(NAME vulkan_smoke_help COMMAND photo_core_vulkan_smoke --help)
  add_test(NAME vulkan_compute_smoke COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/vulkan_smoke_test.py" $<TARGET_FILE:photo_core_vulkan_smoke>)
endif()

if(PHOTOCORE_VULKAN_APP)
  set_target_properties(photocore PROPERTIES POSITION_INDEPENDENT_CODE ON)
  add_library(PhotoCompute SHARED ../../Vendor/PhotoCompute/src/PhotoCompute.cpp
    vulkan/runtime.cpp vulkan/pipeline.cpp vulkan/optics.cpp vulkan/digital.cpp src/film_data.cpp "${CMAKE_CURRENT_BINARY_DIR}/vulkan-recipe.cpp")
  target_include_directories(PhotoCompute PRIVATE src vulkan)
  target_include_directories(PhotoCompute SYSTEM PRIVATE third_party ${Vulkan_INCLUDE_DIRS})
  target_link_libraries(PhotoCompute PRIVATE photocore)
  if(APPLE)
    find_library(PHOTOCORE_MOLTENVK MoltenVK REQUIRED)
    target_link_libraries(PhotoCompute PRIVATE ${PHOTOCORE_MOLTENVK})
    target_compile_definitions(PhotoCompute PRIVATE PHOTOCORE_APP_MOLTENVK=1)
  else()
    target_link_libraries(PhotoCompute PRIVATE Vulkan::Vulkan)
  endif()
  add_dependencies(PhotoCompute photo_core_film_assets photo_core_vulkan_generated)
  add_executable(photo_compute_plan_verify verification/app_plan.cpp)
  target_include_directories(photo_compute_plan_verify PRIVATE ../../Vendor/PhotoCompute/src)
  target_include_directories(photo_compute_plan_verify SYSTEM PRIVATE third_party)
  target_link_libraries(photo_compute_plan_verify PRIVATE PhotoCompute)
  add_executable(photo_compute_semantics_verify verification/app_semantics.cpp)
  target_include_directories(photo_compute_semantics_verify PRIVATE src ../../engine/cpp ../../Vendor/PhotoCompute/src)
  target_include_directories(photo_compute_semantics_verify SYSTEM PRIVATE third_party)
  target_link_libraries(photo_compute_semantics_verify PRIVATE PhotoCompute photocore_film)
  add_test(NAME app_semantics COMMAND photo_compute_semantics_verify "${CMAKE_CURRENT_BINARY_DIR}/film-data" "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv" "${CMAKE_CURRENT_SOURCE_DIR}/../../desktop/internal/recipes/catalog.json")
  add_executable(photo_compute_styles_verify verification/app_styles.cpp)
  target_include_directories(photo_compute_styles_verify PRIVATE src ../../engine/cpp ../../Vendor/PhotoCompute/src)
  target_include_directories(photo_compute_styles_verify SYSTEM PRIVATE third_party)
  target_link_libraries(photo_compute_styles_verify PRIVATE PhotoCompute photocore_film)
  add_executable(photo_compute_optics_verify verification/app_optics.cpp)
  target_include_directories(photo_compute_optics_verify PRIVATE src ../../Vendor/PhotoCompute/src)
  target_include_directories(photo_compute_optics_verify SYSTEM PRIVATE third_party)
  target_link_libraries(photo_compute_optics_verify PRIVATE PhotoCompute photocore_film)
  add_test(NAME app_film_optics COMMAND photo_compute_optics_verify
    "${CMAKE_CURRENT_SOURCE_DIR}/data" "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv")
  add_test(NAME app_resident_compute_plan COMMAND photo_compute_plan_verify
    "${CMAKE_CURRENT_SOURCE_DIR}/data" "${CMAKE_CURRENT_BINARY_DIR}/film.comp.spv")
endif()
