# Upstream globs must not compile filesystem metadata as C/C++ sources.
# Filter the build graph only: keep source files and filesystem metadata intact.
include_guard(GLOBAL)

function(photostyle_filter_native_sources directory)
    get_property(targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(target IN LISTS targets)
        get_target_property(sources "${target}" SOURCES)
        if(sources)
            list(FILTER sources EXCLUDE REGEX "(^|/)\\._[^/]*$")
            set_property(TARGET "${target}" PROPERTY SOURCES "${sources}")
        endif()
    endforeach()
    get_property(children DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    foreach(child IN LISTS children)
        photostyle_filter_native_sources("${child}")
    endforeach()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL
    photostyle_filter_native_sources "${CMAKE_SOURCE_DIR}")
