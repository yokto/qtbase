# These values should be kept in sync with those in qtbase/.cmake.conf
cmake_minimum_required(VERSION 3.16...3.20)

###############################################
#
# Macros and functions for building Qt modules
#
###############################################

# Recursively reads the dependencies section from dependencies.yaml in ${repo_dir} and returns the
# list of dependencies, including transitive ones, in out_var.
#
# The returned dependencies are topologically sorted.
#
# Example output for qtimageformats:
# qtbase;qtshadertools;qtsvg;qtdeclarative;qttools
#
function(qt_internal_read_repo_dependencies out_var repo_dir)
    set(seen ${ARGN})
    set(dependencies "")
    set(in_dependencies_section FALSE)
    set(dependencies_file "${repo_dir}/dependencies.yaml")
    if(EXISTS "${dependencies_file}")
        file(STRINGS "${dependencies_file}" lines)
        foreach(line IN LISTS lines)
            if(line MATCHES "^([^ ]+):")
                if(CMAKE_MATCH_1 STREQUAL "dependencies")
                    set(in_dependencies_section TRUE)
                else()
                    set(in_dependencies_section FALSE)
                endif()
            elseif(in_dependencies_section AND line MATCHES "^  (.+):$")
                set(dependency "${CMAKE_MATCH_1}")
                set(dependency_repo_dir "${repo_dir}/${dependency}")
                string(REGEX MATCH "[^/]+$" dependency "${dependency}")
                if(NOT dependency IN_LIST seen)
                    qt_internal_read_repo_dependencies(subdeps "${dependency_repo_dir}"
                        ${seen} ${dependency})
                    list(APPEND dependencies ${subdeps} ${dependency})
                endif()
            endif()
        endforeach()
        list(REMOVE_DUPLICATES dependencies)
    endif()
    set(${out_var} "${dependencies}" PARENT_SCOPE)
endfunction()

set(QT_BACKUP_CMAKE_INSTALL_PREFIX_BEFORE_EXTRA_INCLUDE "${CMAKE_INSTALL_PREFIX}")

if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/QtBuildInternalsExtra.cmake")
    include(${CMAKE_CURRENT_LIST_DIR}/QtBuildInternalsExtra.cmake)
endif()

# The variables might have already been set in QtBuildInternalsExtra.cmake if the file is included
# while building a new module and not QtBase. In that case, stop overriding the value.
if(NOT INSTALL_CMAKE_NAMESPACE)
    set(INSTALL_CMAKE_NAMESPACE "Qt${PROJECT_VERSION_MAJOR}"
        CACHE STRING "CMake namespace [Qt${PROJECT_VERSION_MAJOR}]")
endif()
if(NOT QT_CMAKE_EXPORT_NAMESPACE)
    set(QT_CMAKE_EXPORT_NAMESPACE "Qt${PROJECT_VERSION_MAJOR}"
        CACHE STRING "CMake namespace used when exporting targets [Qt${PROJECT_VERSION_MAJOR}]")
endif()

macro(qt_set_up_build_internals_paths)
    # Set up the paths for the cmake modules located in the prefix dir. Prepend, so the paths are
    # least important compared to the source dir ones, but more important than command line
    # provided ones.
    set(QT_CMAKE_MODULE_PATH "${QT_BUILD_INTERNALS_PATH}/../${QT_CMAKE_EXPORT_NAMESPACE}")
    list(PREPEND CMAKE_MODULE_PATH "${QT_CMAKE_MODULE_PATH}")

    # Prepend the qtbase source cmake directory to CMAKE_MODULE_PATH,
    # so that if a change is done in cmake/QtBuild.cmake, it gets automatically picked up when
    # building qtdeclarative, rather than having to build qtbase first (which will copy
    # QtBuild.cmake to the build dir). This is similar to qmake non-prefix builds, where the
    # source qtbase/mkspecs directory is used.
    if(EXISTS "${QT_SOURCE_TREE}/cmake")
        list(PREPEND CMAKE_MODULE_PATH "${QT_SOURCE_TREE}/cmake")
    endif()

    # If the repo has its own cmake modules, include those in the module path.
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
        list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
    endif()

    # Find the cmake files when doing a standalone tests build.
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
        list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
    endif()
endmacro()

# Set up the build internal paths unless explicitly requested not to.
if(NOT QT_BUILD_INTERNALS_SKIP_CMAKE_MODULE_PATH_ADDITION)
    qt_set_up_build_internals_paths()
endif()

# Define some constants to check for certain platforms, etc.
# Needs to be loaded before qt_repo_build() to handle require() clauses before even starting a repo
# build.
include(QtPlatformSupport)

function(qt_build_internals_disable_pkg_config_if_needed)
    # pkg-config should not be used by default on Darwin and Windows platforms (and QNX), as defined
    # in the qtbase/configure.json. Unfortunately by the time the feature is evaluated there are
    # already a few find_package() calls that try to use the FindPkgConfig module.
    # Thus, we have to duplicate the condition logic here and disable pkg-config for those platforms
    # by default.
    # We also need to check if the pkg-config executable exists, to mirror the condition test in
    # configure.json. We do that by trying to find the executable ourselves, and not delegating to
    # the FindPkgConfig module because that has more unwanted side-effects.
    #
    # Note that on macOS, if the pkg-config feature is enabled by the user explicitly, we will also
    # tell CMake to consider paths like /usr/local (Homebrew) as system paths when looking for
    # packages.
    # We have to do that because disabling these paths but keeping pkg-config
    # enabled won't enable finding all system libraries via pkg-config alone, many libraries can
    # only be found via FooConfig.cmake files which means /usr/local should be in the system prefix
    # path.

    set(pkg_config_enabled ON)
    qt_build_internals_find_pkg_config_executable()

    if(APPLE OR WIN32 OR QNX OR ANDROID OR WASM OR (NOT PKG_CONFIG_EXECUTABLE))
        set(pkg_config_enabled OFF)
    endif()

    # Features won't have been evaluated yet if this is the first run, have to evaluate this here
    if(NOT "${FEATURE_pkg_config}" AND "${INPUT_pkg_config}"
       AND NOT "${INPUT_pkg_config}" STREQUAL "undefined")
        set(FEATURE_pkg_config ON)
    endif()

    # If user explicitly specified a value for the feature, honor it, even if it might break
    # the build.
    if(DEFINED FEATURE_pkg_config)
        if(FEATURE_pkg_config)
            set(pkg_config_enabled ON)
        else()
            set(pkg_config_enabled OFF)
        endif()
    endif()

    set(FEATURE_pkg_config "${pkg_config_enabled}" CACHE STRING "Using pkg-config")
    if(NOT pkg_config_enabled)
        qt_build_internals_disable_pkg_config()
    else()
        unset(PKG_CONFIG_EXECUTABLE CACHE)
    endif()
endfunction()

# This is a copy of the first few lines in FindPkgConfig.cmake.
function(qt_build_internals_find_pkg_config_executable)
    # find pkg-config, use PKG_CONFIG if set
    if((NOT PKG_CONFIG_EXECUTABLE) AND (NOT "$ENV{PKG_CONFIG}" STREQUAL ""))
      set(PKG_CONFIG_EXECUTABLE "$ENV{PKG_CONFIG}" CACHE FILEPATH "pkg-config executable")
    endif()
    find_program(PKG_CONFIG_EXECUTABLE NAMES pkg-config DOC "pkg-config executable")
    mark_as_advanced(PKG_CONFIG_EXECUTABLE)
endfunction()

function(qt_build_internals_disable_pkg_config)
    # Disable pkg-config by setting an empty executable path. There's no documented way to
    # mark the package as not found, but we can force all pkg_check_modules calls to do nothing
    # by setting the variable to an empty value.
    set(PKG_CONFIG_EXECUTABLE "" CACHE STRING "Disabled pkg-config usage." FORCE)
endfunction()

if(NOT QT_BUILD_INTERNALS_SKIP_PKG_CONFIG_ADJUSTMENT)
    qt_build_internals_disable_pkg_config_if_needed()
endif()

macro(qt_build_internals_find_pkg_config)
    # Find package config once before any system prefix modifications.
    find_package(PkgConfig QUIET)
endmacro()

if(NOT QT_BUILD_INTERNALS_SKIP_FIND_PKG_CONFIG)
    qt_build_internals_find_pkg_config()
endif()

function(qt_build_internals_set_up_system_prefixes)
    if(APPLE AND NOT FEATURE_pkg_config)
        # Remove /usr/local and other paths like that which CMake considers as system prefixes on
        # darwin platforms. CMake considers them as system prefixes, but in qmake / Qt land we only
        # consider the SDK path as a system prefix.
        # 3rd party libraries in these locations should not be picked up when building Qt,
        # unless opted-in via the pkg-config feature, which in turn will disable this behavior.
        #
        # Note that we can't remove /usr as a system prefix path, because many programs won't be
        # found then (e.g. perl).
        set(QT_CMAKE_SYSTEM_PREFIX_PATH_BACKUP "${CMAKE_SYSTEM_PREFIX_PATH}" PARENT_SCOPE)
        set(QT_CMAKE_SYSTEM_FRAMEWORK_PATH_BACKUP "${CMAKE_SYSTEM_FRAMEWORK_PATH}" PARENT_SCOPE)

        list(REMOVE_ITEM CMAKE_SYSTEM_PREFIX_PATH
            "/usr/local" # Homebrew
            "/opt/homebrew" # Apple Silicon Homebrew
            "/usr/X11R6"
            "/usr/pkg"
            "/opt"
            "/sw" # Fink
            "/opt/local" # MacPorts
        )
        if(_CMAKE_INSTALL_DIR)
            list(REMOVE_ITEM CMAKE_SYSTEM_PREFIX_PATH "${_CMAKE_INSTALL_DIR}")
        endif()
        list(REMOVE_ITEM CMAKE_SYSTEM_FRAMEWORK_PATH "~/Library/Frameworks")
        set(CMAKE_SYSTEM_PREFIX_PATH "${CMAKE_SYSTEM_PREFIX_PATH}" PARENT_SCOPE)
        set(CMAKE_SYSTEM_FRAMEWORK_PATH "${CMAKE_SYSTEM_FRAMEWORK_PATH}" PARENT_SCOPE)

        # Also tell qt_find_package() not to use PATH when looking for packages.
        # We can't simply set CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH to OFF because that will break
        # find_program(), and for instance ccache won't be found.
        # That's why we set a different variable which is used by qt_find_package.
        set(QT_NO_USE_FIND_PACKAGE_SYSTEM_ENVIRONMENT_PATH "ON" PARENT_SCOPE)
    endif()
endfunction()

if(NOT QT_BUILD_INTERNALS_SKIP_SYSTEM_PREFIX_ADJUSTMENT)
    qt_build_internals_set_up_system_prefixes()
endif()

macro(qt_build_internals_set_up_private_api)
    # Check for the minimum CMake version.
    include(QtCMakeVersionHelpers)
    qt_internal_require_suitable_cmake_version()
    qt_internal_upgrade_cmake_policies()

    # Qt specific setup common for all modules:
    include(QtSetup)
    include(FeatureSummary)

    # Optionally include a repo specific Setup module.
    include(${PROJECT_NAME}Setup OPTIONAL)
    include(QtRepoSetup OPTIONAL)

    # Find Apple frameworks if needed.
    qt_find_apple_system_frameworks()

    # Decide whether tools will be built.
    qt_check_if_tools_will_be_built()
endmacro()

# find all targets defined in $subdir by recursing through all added subdirectories
# populates $qt_repo_targets with a ;-list of non-UTILITY targets
macro(qt_build_internals_get_repo_targets subdir)
    get_directory_property(_targets DIRECTORY "${subdir}" BUILDSYSTEM_TARGETS)
    if(_targets)
        foreach(_target IN LISTS _targets)
            get_target_property(_type ${_target} TYPE)
            if(NOT (${_type} STREQUAL "UTILITY" OR ${_type} STREQUAL "INTERFACE"))
                list(APPEND qt_repo_targets "${_target}")
            endif()
        endforeach()
    endif()

    get_directory_property(_directories DIRECTORY "${subdir}" SUBDIRECTORIES)
    if (_directories)
        foreach(_directory IN LISTS _directories)
            qt_build_internals_get_repo_targets("${_directory}")
        endforeach()
    endif()
endmacro()

# add toplevel targets for each subdirectory, e.g. qtbase_src
function(qt_build_internals_add_toplevel_targets)
    set(qt_repo_target_all "")
    get_directory_property(directories DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" SUBDIRECTORIES)
    foreach(directory IN LISTS directories)
        set(qt_repo_targets "")
        get_filename_component(qt_repo_target_basename ${directory} NAME)
        qt_build_internals_get_repo_targets("${directory}")
        if (qt_repo_targets)
            set(qt_repo_target_name "${qt_repo_targets_name}_${qt_repo_target_basename}")
            message(DEBUG "${qt_repo_target_name} depends on ${qt_repo_targets}")
            add_custom_target("${qt_repo_target_name}"
                                DEPENDS ${qt_repo_targets}
                                COMMENT "Building everything in ${qt_repo_targets_name}/${qt_repo_target_basename}")
            list(APPEND qt_repo_target_all "${qt_repo_target_name}")
        endif()
    endforeach()
    if (qt_repo_target_all)
        add_custom_target("${qt_repo_targets_name}"
                            DEPENDS ${qt_repo_target_all}
                            COMMENT "Building everything in ${qt_repo_targets_name}")
    endif()
endfunction()

macro(qt_enable_cmake_languages)
    include(CheckLanguage)
    set(__qt_required_language_list C CXX)
    set(__qt_optional_language_list )

    # https://gitlab.kitware.com/cmake/cmake/-/issues/20545
    if(APPLE)
        list(APPEND __qt_optional_language_list OBJC OBJCXX)
    endif()

    foreach(__qt_lang ${__qt_required_language_list})
        enable_language(${__qt_lang})
    endforeach()

    foreach(__qt_lang ${__qt_optional_language_list})
        check_language(${__qt_lang})
        if(CMAKE_${__qt_lang}_COMPILER)
            enable_language(${__qt_lang})
        endif()
    endforeach()

    # The qtbase call is handled in qtbase/CMakeLists.txt.
    # This call is used for projects other than qtbase, including for other project's standalone
    # tests.
    # Because the function uses QT_FEATURE_foo values, it's important that find_package(Qt6Core) is
    # called before this function. but that's usually the case for Qt repos.
    if(NOT PROJECT_NAME STREQUAL "QtBase")
        qt_internal_set_up_config_optimizations_like_in_qmake()
    endif()
endmacro()

# Minimum setup required to have any CMakeList.txt build as as a standalone
# project after importing BuildInternals
macro(qt_prepare_standalone_project)
    qt_set_up_build_internals_paths()
    qt_build_internals_set_up_private_api()
    qt_enable_cmake_languages()
endmacro()

# Define a repo target set, and store accompanying information.
#
# A repo target set is a subset of targets in a Qt module repository. To build a repo target set,
# set QT_BUILD_SINGLE_REPO_TARGET_SET to the name of the repo target set.
#
# This function is to be called in the top-level project file of a repository,
# before qt_internal_prepare_single_repo_target_set_build()
#
# This function stores information in variables of the parent scope.
#
# Positional Arguments:
#   name - The name of this repo target set.
#
# Named Arguments:
#   DEPENDS - List of Qt6 COMPONENTS that are build dependencies of this repo target set.
function(qt_internal_define_repo_target_set name)
    set(oneValueArgs DEPENDS)
    set(prefix QT_REPO_TARGET_SET_)
    cmake_parse_arguments(${prefix}${name} "" ${oneValueArgs} "" ${ARGN})
    foreach(arg IN LISTS oneValueArgs)
        set(${prefix}${name}_${arg} ${${prefix}${name}_${arg}} PARENT_SCOPE)
    endforeach()
    set(QT_REPO_KNOWN_TARGET_SETS "${QT_REPO_KNOWN_TARGET_SETS};${name}" PARENT_SCOPE)
endfunction()

# Setup a single repo target set build if QT_BUILD_SINGLE_REPO_TARGET_SET is defined.
#
# This macro must be called in the top-level project file of the repository after all repo target
# sets have been defined.
macro(qt_internal_prepare_single_repo_target_set_build)
    if(DEFINED QT_BUILD_SINGLE_REPO_TARGET_SET)
        if(NOT QT_BUILD_SINGLE_REPO_TARGET_SET IN_LIST QT_REPO_KNOWN_TARGET_SETS)
            message(FATAL_ERROR
                "Repo target set '${QT_BUILD_SINGLE_REPO_TARGET_SET}' is undefined.")
        endif()
        message(STATUS
            "Preparing single repo target set build of ${QT_BUILD_SINGLE_REPO_TARGET_SET}")
        if (NOT "${QT_REPO_TARGET_SET_${QT_BUILD_SINGLE_REPO_TARGET_SET}_DEPENDS}" STREQUAL "")
            find_package(${INSTALL_CMAKE_NAMESPACE} ${PROJECT_VERSION} CONFIG REQUIRED
                COMPONENTS ${QT_REPO_TARGET_SET_${QT_BUILD_SINGLE_REPO_TARGET_SET}_DEPENDS})
        endif()
    endif()
endmacro()

macro(qt_build_repo_begin)
    qt_build_internals_set_up_private_api()
    qt_enable_cmake_languages()

    # Add global docs targets that will work both for per-repo builds, and super builds.
    if(NOT TARGET docs)
        add_custom_target(docs)
        add_custom_target(prepare_docs)
        add_custom_target(generate_docs)
        add_custom_target(html_docs)
        add_custom_target(qch_docs)
        add_custom_target(install_html_docs)
        add_custom_target(install_qch_docs)
        add_custom_target(install_docs)
        add_dependencies(html_docs generate_docs)
        add_dependencies(docs html_docs qch_docs)
        add_dependencies(install_docs install_html_docs install_qch_docs)
    endif()

    # Add global qt_plugins, qpa_plugins and qpa_default_plugins convenience custom targets.
    # Internal executables will add a dependency on the qpa_default_plugins target,
    # so that building and running a test ensures it won't fail at runtime due to a missing qpa
    # plugin.
    if(NOT TARGET qt_plugins)
        add_custom_target(qt_plugins)
        add_custom_target(qpa_plugins)
        add_custom_target(qpa_default_plugins)
    endif()

    string(TOLOWER ${PROJECT_NAME} project_name_lower)

    set(qt_repo_targets_name ${project_name_lower})
    set(qt_docs_target_name docs_${project_name_lower})
    set(qt_docs_prepare_target_name prepare_docs_${project_name_lower})
    set(qt_docs_generate_target_name generate_docs_${project_name_lower})
    set(qt_docs_html_target_name html_docs_${project_name_lower})
    set(qt_docs_qch_target_name qch_docs_${project_name_lower})
    set(qt_docs_install_html_target_name install_html_docs_${project_name_lower})
    set(qt_docs_install_qch_target_name install_qch_docs_${project_name_lower})
    set(qt_docs_install_target_name install_docs_${project_name_lower})

    add_custom_target(${qt_docs_target_name})
    add_custom_target(${qt_docs_prepare_target_name})
    add_custom_target(${qt_docs_generate_target_name})
    add_custom_target(${qt_docs_qch_target_name})
    add_custom_target(${qt_docs_html_target_name})
    add_custom_target(${qt_docs_install_html_target_name})
    add_custom_target(${qt_docs_install_qch_target_name})
    add_custom_target(${qt_docs_install_target_name})

    add_dependencies(${qt_docs_generate_target_name} ${qt_docs_prepare_target_name})
    add_dependencies(${qt_docs_html_target_name} ${qt_docs_generate_target_name})
    add_dependencies(${qt_docs_target_name} ${qt_docs_html_target_name} ${qt_docs_qch_target_name})
    add_dependencies(${qt_docs_install_target_name} ${qt_docs_install_html_target_name} ${qt_docs_install_qch_target_name})

    # Make top-level prepare_docs target depend on the repository-level prepare_docs_<repo> target.
    add_dependencies(prepare_docs ${qt_docs_prepare_target_name})

    # Make top-level install_*_docs targets depend on the repository-level install_*_docs targets.
    add_dependencies(install_html_docs ${qt_docs_install_html_target_name})
    add_dependencies(install_qch_docs ${qt_docs_install_qch_target_name})

    # Add host_tools meta target, so that developrs can easily build only tools and their
    # dependencies when working in qtbase.
    if(NOT TARGET host_tools)
        add_custom_target(host_tools)
        add_custom_target(bootstrap_tools)
    endif()

    # Add benchmark meta target. It's collection of all benchmarks added/registered by
    # 'qt_internal_add_benchmark' helper.
    if(NOT TARGET benchmark)
        add_custom_target(benchmark)
    endif()
endmacro()

macro(qt_build_repo_end)
    if(NOT QT_BUILD_STANDALONE_TESTS)
        # Delayed actions on some of the Qt targets:
        include(QtPostProcess)

        # Install the repo-specific cmake find modules.
        qt_path_join(__qt_repo_install_dir ${QT_CONFIG_INSTALL_DIR} ${INSTALL_CMAKE_NAMESPACE})
        qt_path_join(__qt_repo_build_dir ${QT_CONFIG_BUILD_DIR} ${INSTALL_CMAKE_NAMESPACE})

        if(NOT PROJECT_NAME STREQUAL "QtBase")
            if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
                qt_copy_or_install(DIRECTORY cmake/
                    DESTINATION "${__qt_repo_install_dir}"
                    FILES_MATCHING PATTERN "Find*.cmake"
                )
                if(QT_SUPERBUILD AND QT_WILL_INSTALL)
                    file(COPY cmake/
                         DESTINATION "${__qt_repo_build_dir}"
                         FILES_MATCHING PATTERN "Find*.cmake"
                    )
                endif()
            endif()
        endif()

        if(NOT QT_SUPERBUILD)
            qt_print_feature_summary()
        endif()
    endif()

    qt_build_internals_add_toplevel_targets()

    if(NOT QT_SUPERBUILD)
        qt_print_build_instructions()
    endif()
endmacro()

macro(qt_build_repo)
    qt_build_repo_begin(${ARGN})

    qt_build_repo_impl_find_package_tests()
    qt_build_repo_impl_src()
    qt_build_repo_impl_tools()
    qt_build_repo_impl_tests()

    qt_build_repo_end()

    qt_build_repo_impl_examples()
endmacro()

macro(qt_build_repo_impl_find_package_tests)
    # If testing is enabled, try to find the qtbase Test package.
    # Do this before adding src, because there might be test related conditions
    # in source.
    if (QT_BUILD_TESTS AND NOT QT_BUILD_STANDALONE_TESTS)
        find_package(Qt6 ${PROJECT_VERSION} CONFIG REQUIRED COMPONENTS Test)
    endif()
endmacro()

macro(qt_build_repo_impl_src)
    if(NOT QT_BUILD_STANDALONE_TESTS)
        if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/CMakeLists.txt")
            add_subdirectory(src)
        endif()
    endif()
endmacro()

macro(qt_build_repo_impl_tools)
    if(NOT QT_BUILD_STANDALONE_TESTS)
        if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tools/CMakeLists.txt")
            add_subdirectory(tools)
        endif()
    endif()
endmacro()

macro(qt_build_repo_impl_tests)
    if (QT_BUILD_TESTS AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt")
        add_subdirectory(tests)
        if(NOT QT_BUILD_TESTS_BY_DEFAULT)
            set_property(DIRECTORY tests PROPERTY EXCLUDE_FROM_ALL TRUE)
        endif()
    endif()
endmacro()

macro(qt_build_repo_impl_examples)
    if(QT_BUILD_EXAMPLES
            AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/examples/CMakeLists.txt"
            AND NOT QT_BUILD_STANDALONE_TESTS)
        add_subdirectory(examples)
    endif()
endmacro()

macro(qt_set_up_standalone_tests_build)
    # Remove this macro once all usages of it have been removed.
    # Standalone tests are not handled via the main repo project and qt_build_tests.
endmacro()

function(qt_get_standalone_tests_config_files_path out_var)
    set(path "${QT_CONFIG_INSTALL_DIR}/${INSTALL_CMAKE_NAMESPACE}BuildInternals/StandaloneTests")

    # QT_CONFIG_INSTALL_DIR is relative in prefix builds.
    if(QT_WILL_INSTALL)
        if(DEFINED CMAKE_STAGING_PREFIX)
            qt_path_join(path "${CMAKE_STAGING_PREFIX}" "${path}")
        else()
            qt_path_join(path "${CMAKE_INSTALL_PREFIX}" "${path}")
        endif()
    endif()

    set("${out_var}" "${path}" PARENT_SCOPE)
endfunction()

macro(qt_build_tests)
    if(QT_BUILD_STANDALONE_TESTS)
        # Find location of TestsConfig.cmake. These contain the modules that need to be
        # find_package'd when testing.
        qt_get_standalone_tests_config_files_path(_qt_build_tests_install_prefix)
        include("${_qt_build_tests_install_prefix}/${PROJECT_NAME}TestsConfig.cmake" OPTIONAL)

        # Of course we always need the test module as well.
        find_package(Qt6 ${PROJECT_VERSION} CONFIG REQUIRED COMPONENTS Test)

        # Set language standards after finding Core, because that's when the relevant
        # feature variables are available, and the call in QtSetup is too early when building
        # standalone tests, because Core was not find_package()'d yet.
        qt_set_language_standards()

        if(NOT QT_SUPERBUILD)
            # Set up fake standalone tests install prefix, so we don't pollute the Qt install
            # prefix. For super builds it needs to be done in qt5/CMakeLists.txt.
            qt_set_up_fake_standalone_tests_install_prefix()
        endif()
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/auto/CMakeLists.txt")
        add_subdirectory(auto)
    endif()
    if(NOT QT_BUILD_MINIMAL_STATIC_TESTS)
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/benchmarks/CMakeLists.txt" AND QT_BUILD_BENCHMARKS)
            add_subdirectory(benchmarks)
        endif()
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/manual/CMakeLists.txt" AND QT_BUILD_MANUAL_TESTS)
            add_subdirectory(manual)
        endif()
    endif()
endmacro()

function(qt_compute_relative_path_from_cmake_config_dir_to_prefix)
    # Compute the reverse relative path from the CMake config dir to the install prefix.
    # This is used in QtBuildInternalsExtras to create a relocatable relative install prefix path.
    # This path is used for finding syncqt and other things, regardless of initial install prefix
    # (e.g installed Qt was archived and unpacked to a different path on a different machine).
    #
    # This is meant to be called only once when configuring qtbase.
    #
    # Similar code exists in Qt6CoreConfigExtras.cmake.in and src/corelib/CMakeLists.txt which
    # might not be needed anymore.
    if(QT_WILL_INSTALL)
        get_filename_component(clean_config_prefix
                               "${CMAKE_INSTALL_PREFIX}/${QT_CONFIG_INSTALL_DIR}" ABSOLUTE)
    else()
        get_filename_component(clean_config_prefix "${QT_CONFIG_BUILD_DIR}" ABSOLUTE)
    endif()
    file(RELATIVE_PATH
         qt_path_from_cmake_config_dir_to_prefix
         "${clean_config_prefix}" "${CMAKE_INSTALL_PREFIX}")
     set(qt_path_from_cmake_config_dir_to_prefix "${qt_path_from_cmake_config_dir_to_prefix}"
         PARENT_SCOPE)
endfunction()

function(qt_get_relocatable_install_prefix out_var)
    # We need to compute it only once while building qtbase. Afterwards it's loaded from
    # QtBuildInternalsExtras.cmake.
    if(QT_BUILD_INTERNALS_RELOCATABLE_INSTALL_PREFIX)
        return()
    endif()
    # The QtBuildInternalsExtras value is dynamically computed, whereas the initial qtbase
    # configuration uses an absolute path.
    set(${out_var} "${CMAKE_INSTALL_PREFIX}" PARENT_SCOPE)
endfunction()

function(qt_set_up_fake_standalone_tests_install_prefix)
    # Set a fake local (non-cache) CMAKE_INSTALL_PREFIX.
    # Needed for standalone tests, we don't want to accidentally install a test into the Qt prefix.
    # Allow opt-out, if a user knows what they're doing.
    if(QT_NO_FAKE_STANDALONE_TESTS_INSTALL_PREFIX)
        return()
    endif()
    set(new_install_prefix "${CMAKE_BINARY_DIR}/fake_prefix")

    # It's IMPORTANT that this is not a cache variable. Otherwise
    # qt_get_standalone_tests_confg_files_path() will not work on re-configuration.
    message(STATUS
            "Setting local standalone test install prefix (non-cached) to '${new_install_prefix}'.")
    set(CMAKE_INSTALL_PREFIX "${new_install_prefix}" PARENT_SCOPE)

    # We also need to clear the staging prefix if it's set, otherwise CMake will modify any computed
    # rpaths containing the staging prefix to point to the new fake prefix, which is not what we
    # want. This replacement is done in cmComputeLinkInformation::GetRPath().
    #
    # By clearing the staging prefix for the standalone tests, any detected link time
    # rpaths will be embedded as-is, which will point to the place where Qt was installed (aka
    # the staging prefix).
    if(DEFINED CMAKE_STAGING_PREFIX)
        message(STATUS "Clearing local standalone test staging prefix (non-cached).")
        set(CMAKE_STAGING_PREFIX "" PARENT_SCOPE)
    endif()
endfunction()

# Mean to be called when configuring examples as part of the main build tree, as well as for CMake
# tests (tests that call CMake to try and build CMake applications).
macro(qt_internal_set_up_build_dir_package_paths)
    list(APPEND CMAKE_PREFIX_PATH "${QT_BUILD_DIR}")
    # Make sure the CMake config files do not recreate the already-existing targets
    set(QT_NO_CREATE_TARGETS TRUE)
    set(BACKUP_CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ${CMAKE_FIND_ROOT_PATH_MODE_PACKAGE})
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE "BOTH")
endmacro()

macro(qt_examples_build_begin)
    set(options EXTERNAL_BUILD)
    set(singleOpts "")
    set(multiOpts DEPENDS)

    cmake_parse_arguments(arg "${options}" "${singleOpts}" "${multiOpts}" ${ARGN})

    # FIXME: Support prefix builds as well
    if(arg_EXTERNAL_BUILD AND NOT QT_WILL_INSTALL)
        # Examples will be built using ExternalProject.
        # We always depend on all plugins so as to prevent opportunities for
        # weird errors associated with loading out-of-date plugins from
        # unrelated Qt modules.
        # We also depend on all targets from this repo's src and tools subdirectories
        # to ensure that we've built anything that a find_package() call within
        # an example might use. Projects can add further dependencies if needed,
        # but that should rarely be necessary.
        set(QT_EXAMPLE_DEPENDENCIES qt_plugins ${arg_DEPENDS})

        if(TARGET ${qt_repo_targets_name}_src)
            list(APPEND QT_EXAMPLE_DEPENDENCIES ${qt_repo_targets_name}_src)
        endif()

        if(TARGET ${qt_repo_targets_name}_tools)
            list(APPEND QT_EXAMPLE_DEPENDENCIES ${qt_repo_targets_name}_tools)
        endif()

        set(QT_EXAMPLE_BASE_DIR ${CMAKE_CURRENT_SOURCE_DIR})
        set(QT_IS_EXTERNAL_EXAMPLES_BUILD TRUE)

        string(TOLOWER ${PROJECT_NAME} project_name_lower)
        if(NOT TARGET examples)
            if(QT_BUILD_EXAMPLES_BY_DEFAULT)
                add_custom_target(examples ALL)
            else()
                add_custom_target(examples)
            endif()
        endif()
        if(NOT TARGET examples_${project_name_lower})
            add_custom_target(examples_${project_name_lower})
            add_dependencies(examples examples_${project_name_lower})
        endif()

        include(ExternalProject)
    else()
        # This repo has not yet been updated to build examples in a separate
        # build from this main build, or we can't use that arrangement yet.
        # Build them directly as part of the main build instead for backward
        # compatibility.
        if(NOT BUILD_SHARED_LIBS)
            # Ordinarily, it would be an error to call return() from within a
            # macro(), but in this case we specifically want to return from the
            # caller's scope if we are doing a static build and the project
            # isn't building examples in a separate build from the main build.
            # Configuring static builds requires tools that are not available
            # until build time.
            return()
        endif()

        if(NOT QT_BUILD_EXAMPLES_BY_DEFAULT)
            set_directory_properties(PROPERTIES EXCLUDE_FROM_ALL TRUE)
        endif()
    endif()

    # Examples that are built as part of the Qt build need to use the CMake config files from the
    # build dir, because they are not installed yet in a prefix build.
    # Appending to CMAKE_PREFIX_PATH helps find the initial Qt6Config.cmake.
    # Appending to QT_EXAMPLES_CMAKE_PREFIX_PATH helps find components of Qt6, because those
    # find_package calls use NO_DEFAULT_PATH, and thus CMAKE_PREFIX_PATH is ignored.
    qt_internal_set_up_build_dir_package_paths()
    list(APPEND QT_EXAMPLES_CMAKE_PREFIX_PATH "${QT_BUILD_DIR}")

    # Because CMAKE_INSTALL_RPATH is empty by default in the repo project, examples need to have
    # it set here, so they can run when installed.
    # This means that installed examples are not relocatable at the moment. We would need to
    # annotate where each example is installed to, to be able to derive a relative rpath, and it
    # seems there's no way to query such information from CMake itself.
    set(CMAKE_INSTALL_RPATH "${_default_install_rpath}")
    set(QT_DISABLE_QT_ADD_PLUGIN_COMPATIBILITY TRUE)
endmacro()

macro(qt_examples_build_end)
    # We use AUTOMOC/UIC/RCC in the examples. When the examples are part of the
    # main build rather than being built in their own separate project, make
    # sure we do not fail on a fresh Qt build (e.g. the moc binary won't exist
    # yet because it is created at build time).

    # This function gets all targets below this directory (excluding custom targets and aliases)
    function(get_all_targets _result _dir)
        get_property(_subdirs DIRECTORY "${_dir}" PROPERTY SUBDIRECTORIES)
        foreach(_subdir IN LISTS _subdirs)
            get_all_targets(${_result} "${_subdir}")
        endforeach()
        get_property(_sub_targets DIRECTORY "${_dir}" PROPERTY BUILDSYSTEM_TARGETS)
        set(_real_targets "")
        if(_sub_targets)
            foreach(__target IN LISTS _sub_targets)
                get_target_property(target_type ${__target} TYPE)
                if(NOT target_type STREQUAL "UTILITY" AND NOT target_type STREQUAL "ALIAS")
                    list(APPEND _real_targets ${__target})
                endif()
            endforeach()
        endif()
        set(${_result} ${${_result}} ${_real_targets} PARENT_SCOPE)
    endfunction()

    get_all_targets(targets "${CMAKE_CURRENT_SOURCE_DIR}")

    foreach(target ${targets})
        qt_autogen_tools(${target} ENABLE_AUTOGEN_TOOLS "moc" "rcc")
        if(TARGET Qt::Widgets)
            qt_autogen_tools(${target} ENABLE_AUTOGEN_TOOLS "uic")
        endif()
    endforeach()

    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ${BACKUP_CMAKE_FIND_ROOT_PATH_MODE_PACKAGE})
endmacro()

function(qt_internal_add_example subdir)
    # FIXME: Support building examples externally for prefix builds as well.

    if(NOT QT_IS_EXTERNAL_EXAMPLES_BUILD)
        # Use old non-external approach
        add_subdirectory(${subdir} ${ARGN})
        return()
    endif()

    set(options "")
    set(singleOpts NAME)
    set(multiOpts "")

    cmake_parse_arguments(PARSE_ARGV 1 arg "${options}" "${singleOpts}" "${multiOpts}")

    if(NOT arg_NAME)
        file(RELATIVE_PATH rel_path ${QT_EXAMPLE_BASE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/${subdir})
        string(REPLACE "/" "_" arg_NAME "${rel_path}")
    endif()

    if(QtBase_BINARY_DIR)
        # Always use the copy in the build directory, even for prefix builds.
        # We may build examples without installing, so we can't use the
        # install or staging area.
        set(qt_cmake_dir ${QtBase_BINARY_DIR}/lib/cmake/${QT_CMAKE_EXPORT_NAMESPACE})
    else()
        # This is a per-repo build that isn't the qtbase repo, so we know that
        # qtbase was found via find_package() and Qt6_DIR must be set
        set(qt_cmake_dir ${${QT_CMAKE_EXPORT_NAMESPACE}_DIR})
    endif()

    set(vars_to_pass_if_defined)
    set(var_defs)
    if(QT_HOST_PATH OR CMAKE_CROSSCOMPILING)
        # Android NDK forces CMAKE_FIND_ROOT_PATH_MODE_PACKAGE to ONLY, so we
        # can't rely on this setting here making it through to the example
        # project.
        # TODO: We should probably leave CMAKE_FIND_ROOT_PATH_MODE_PACKAGE
        #       alone. It may be a leftover from earlier methods that are no
        #       longer used or that no longer need this.
        list(APPEND var_defs
            -DCMAKE_TOOLCHAIN_FILE:FILEPATH=${qt_cmake_dir}/qt.toolchain.cmake
            -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE:STRING=BOTH
        )
    else()
        get_filename_component(prefix_dir ${qt_cmake_dir}/../../.. ABSOLUTE)
        list(PREPEND CMAKE_PREFIX_PATH ${prefix_dir})

        # Setting CMAKE_SYSTEM_NAME affects CMAKE_CROSSCOMPILING, even if it is
        # set to the same as the host, so it should only be set if it is different.
        # See https://gitlab.kitware.com/cmake/cmake/-/issues/21744
        if(NOT DEFINED CMAKE_TOOLCHAIN_FILE AND
           NOT CMAKE_SYSTEM_NAME STREQUAL CMAKE_HOST_SYSTEM_NAME)
            list(APPEND vars_to_pass_if_defined CMAKE_SYSTEM_NAME:STRING)
        endif()
    endif()

    list(APPEND vars_to_pass_if_defined
        CMAKE_BUILD_TYPE:STRING
        CMAKE_PREFIX_PATH:STRING
        CMAKE_FIND_ROOT_PATH:STRING
        CMAKE_FIND_ROOT_PATH_MODE_PACKAGE:STRING
        BUILD_SHARED_LIBS:BOOL
        CMAKE_OSX_ARCHITECTURES:STRING
        CMAKE_OSX_DEPLOYMENT_TARGET:STRING
        CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED:BOOL
        CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH:BOOL
        CMAKE_C_COMPILER_LAUNCHER:STRING
        CMAKE_CXX_COMPILER_LAUNCHER:STRING
        CMAKE_OBJC_COMPILER_LAUNCHER:STRING
        CMAKE_OBJCXX_COMPILER_LAUNCHER:STRING
    )

    foreach(var_with_type IN LISTS vars_to_pass_if_defined)
        string(REPLACE ":" ";" key_as_list "${var_with_type}")
        list(GET key_as_list 0 var)
        if(NOT DEFINED ${var})
            continue()
        endif()

        # Preserve lists
        string(REPLACE ";" "$<SEMICOLON>" varForGenex "${${var}}")

        list(APPEND var_defs -D${var_with_type}=${varForGenex})
    endforeach()


    set(deps "")
    list(REMOVE_DUPLICATES QT_EXAMPLE_DEPENDENCIES)
    foreach(dep IN LISTS QT_EXAMPLE_DEPENDENCIES)
        if(TARGET ${dep})
            list(APPEND deps ${dep})
        endif()
    endforeach()

    set(independent_args)
    cmake_policy(PUSH)
    if(POLICY CMP0114)
        set(independent_args INDEPENDENT TRUE)
        cmake_policy(SET CMP0114 NEW)
    endif()

    # The USES_TERMINAL_BUILD setting forces the build step to the console pool
    # when using Ninja. This has two benefits:
    #
    #   - You see build output as it is generated instead of at the end of the
    #     build step.
    #   - Only one task can use the console pool at a time, so it effectively
    #     serializes all example build steps, thereby preventing CPU
    #     over-commitment.
    #
    # If the loss of interactivity is not so important, one can allow CPU
    # over-commitment for Ninja builds. This may result in better throughput,
    # but is not allowed by default because it can make a machine almost
    # unusable while a compilation is running.
    set(terminal_args USES_TERMINAL_BUILD TRUE)
    if(CMAKE_GENERATOR MATCHES "Ninja")
        option(QT_BUILD_EXAMPLES_WITH_CPU_OVERCOMMIT
            "Allow CPU over-commitment when building examples (Ninja only)"
        )
        if(QT_BUILD_EXAMPLES_WITH_CPU_OVERCOMMIT)
            set(terminal_args)
        endif()
    endif()

    ExternalProject_Add(${arg_NAME}
        EXCLUDE_FROM_ALL TRUE
        SOURCE_DIR       ${CMAKE_CURRENT_SOURCE_DIR}/${subdir}
        INSTALL_COMMAND  ""
        TEST_COMMAND     ""
        DEPENDS          ${deps}
        CMAKE_CACHE_ARGS ${var_defs}
        ${terminal_args}
    )

    # Force configure step to re-run after we configure the main project
    set(reconfigure_check_file ${CMAKE_CURRENT_BINARY_DIR}/reconfigure_${arg_NAME}.txt)
    file(TOUCH ${reconfigure_check_file})
    ExternalProject_Add_Step(${arg_NAME} reconfigure-check
        DEPENDERS configure
        DEPENDS   ${reconfigure_check_file}
        ${independent_args}
    )

    # Create an apk external project step and custom target that invokes the apk target
    # within the external project.
    # Make the global apk target depend on that custom target.
    if(ANDROID)
        ExternalProject_Add_Step(${arg_NAME} apk
            COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target apk
            DEPENDEES configure
            EXCLUDE_FROM_MAIN YES
            ${terminal_args}
        )
        ExternalProject_Add_StepTargets(${arg_NAME} apk)

        if(TARGET apk)
            add_dependencies(apk ${arg_NAME}-apk)
        endif()
    endif()

    cmake_policy(POP)

    string(TOLOWER ${PROJECT_NAME} project_name_lower)
    add_dependencies(examples_${project_name_lower} ${arg_NAME})

endfunction()

if ("STANDALONE_TEST" IN_LIST Qt6BuildInternals_FIND_COMPONENTS)
    include(${CMAKE_CURRENT_LIST_DIR}/QtStandaloneTestTemplateProject/Main.cmake)
    if (NOT PROJECT_VERSION_MAJOR)
        get_property(_qt_major_version TARGET ${QT_CMAKE_EXPORT_NAMESPACE}::Core PROPERTY INTERFACE_QT_MAJOR_VERSION)
        set(PROJECT_VERSION ${Qt${_qt_major_version}Core_VERSION})

        string(REPLACE "." ";" _qt_core_version_list ${PROJECT_VERSION})
        list(GET _qt_core_version_list 0 PROJECT_VERSION_MAJOR)
        list(GET _qt_core_version_list 1 PROJECT_VERSION_MINOR)
        list(GET _qt_core_version_list 2 PROJECT_VERSION_PATCH)
    endif()
endif()

function(qt_internal_static_link_order_test)
    # The CMake versions greater than 3.21 take care about the resource object files order in a
    # linker line, it's expected that all object files are located at the beginning of the linker
    # line.
    # No need to run the test.
    # TODO: This check is added before the actual release of CMake 3.21. So need to check if the
    # target version meets the expectations.
    if(CMAKE_VERSION VERSION_LESS 3.21)
        __qt_internal_check_link_order_matters(link_order_matters)
        if(link_order_matters)
            set(summary_message "no")
        else()
            set(summary_message "yes")
        endif()
    else()
        set(summary_message "yes")
    endif()
    qt_configure_add_summary_entry(TYPE "message"
        ARGS "Linker can resolve circular dependencies"
        MESSAGE "${summary_message}"
    )
endfunction()

function(qt_internal_check_cmp0099_available)
    # Don't care about CMP0099 in CMake versions greater than or equal to 3.21
    if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.21)
        return()
    endif()

    __qt_internal_check_cmp0099_available(result)
    if(result)
        set(summary_message "yes")
    else()
        set(summary_message "no")
    endif()
    qt_configure_add_summary_entry(TYPE "message"
        ARGS "CMake policy CMP0099 is supported"
        MESSAGE "${summary_message}"
    )
endfunction()

function(qt_internal_run_common_config_tests)
    qt_configure_add_summary_section(NAME "Common build options")
    qt_internal_static_link_order_test()
    qt_internal_check_cmp0099_available()
    qt_configure_end_summary_section()
endfunction()
