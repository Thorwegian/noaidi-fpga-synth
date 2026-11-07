# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

# The following lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# The build's name, printed by the boot banner, `system` and the status bar: the branch and
# the short commit (`main@0572a5c`), plus -dirty for uncommitted changes. ESP-IDF's default
# PROJECT_VER is `git describe`, which names whatever tag is nearest in the clone, and the
# project has no releases (#201). Re-read whenever HEAD or the branch ref moves.
execute_process(COMMAND git rev-parse --abbrev-ref HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE GIT_BRANCH
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
execute_process(COMMAND git rev-parse --short HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE GIT_COMMIT
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
execute_process(COMMAND git status --porcelain --untracked-files=no
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE GIT_STATUS ERROR_QUIET)
execute_process(COMMAND git rev-parse --git-path HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE GIT_HEAD_FILE
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
execute_process(COMMAND git rev-parse --symbolic-full-name HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE GIT_REF
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(GIT_COMMIT)
    # esp_app_desc_t holds 31 characters of version, too few for a branch name and a
    # commit, so the descriptor carries the commit and the banner's full string is the
    # NOAIDI_BUILD compile definition (main/CMakeLists.txt).
    set(PROJECT_VER "${GIT_COMMIT}")
    set(NOAIDI_BUILD "${GIT_BRANCH}@${GIT_COMMIT}")
    if(GIT_STATUS)
        set(PROJECT_VER "${PROJECT_VER}-dirty")
        set(NOAIDI_BUILD "${NOAIDI_BUILD}-dirty")
    endif()
    # Reconfigure on a commit or a branch switch, not only when CMake happens to rerun.
    get_filename_component(GIT_HEAD_FILE "${GIT_HEAD_FILE}" ABSOLUTE BASE_DIR ${CMAKE_SOURCE_DIR})
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${GIT_HEAD_FILE}")
    if(GIT_REF AND NOT GIT_REF STREQUAL "HEAD")
        execute_process(COMMAND git rev-parse --git-path ${GIT_REF}
            WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE GIT_REF_FILE
            OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        get_filename_component(GIT_REF_FILE "${GIT_REF_FILE}" ABSOLUTE BASE_DIR ${CMAKE_SOURCE_DIR})
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${GIT_REF_FILE}")
    endif()
else()
    set(PROJECT_VER "unknown")
    set(NOAIDI_BUILD "unknown")
endif()
# "Trim" the build. Include the minimal set of components, main, and anything it depends on.
idf_build_set_property(MINIMAL_BUILD ON)
project(flex-app)
