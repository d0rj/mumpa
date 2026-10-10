# Patch only pinned upstream translation units in the build directory. The pub
# cache, generated plugin registrar and all other plugin sources stay original.
function(mumpa_overlay_webview_source relative_source expected_sha before_file after_file)
  set(plugin_target flutter_inappwebview_windows_plugin)
  if(NOT TARGET ${plugin_target})
    message(FATAL_ERROR "Mumpa WebView shutdown patch: plugin target is missing")
  endif()
  get_target_property(plugin_source_dir ${plugin_target} SOURCE_DIR)
  set(original "${plugin_source_dir}/${relative_source}")
  file(SHA256 "${original}" actual_sha)
  if(NOT actual_sha STREQUAL expected_sha)
    message(FATAL_ERROR
      "Mumpa WebView shutdown patch: upstream source changed (${relative_source}); review the patch before updating its SHA256")
  endif()

  file(READ "${original}" source)
  file(READ "${before_file}" before)
  file(READ "${after_file}" after)
  # Hash checks are over original bytes (including CRLF); substitution uses LF.
  string(REPLACE "\r\n" "\n" source "${source}")
  string(REPLACE "\r\n" "\n" before "${before}")
  string(REPLACE "\r\n" "\n" after "${after}")
  string(FIND "${source}" "${before}" match_position)
  if(match_position EQUAL -1)
    message(FATAL_ERROR "Mumpa WebView shutdown patch: expected destructor not found (${relative_source})")
  endif()
  string(REPLACE "${before}" "${after}" patched "${source}")
  # A second occurrence would mean the intended replacement was not unique.
  string(LENGTH "${before}" before_length)
  math(EXPR after_match "${match_position} + ${before_length}")
  string(SUBSTRING "${source}" ${after_match} -1 remaining)
  string(FIND "${remaining}" "${before}" duplicate_position)
  if(NOT duplicate_position EQUAL -1)
    message(FATAL_ERROR "Mumpa WebView shutdown patch: ambiguous destructor (${relative_source})")
  endif()

  if(relative_source STREQUAL "in_app_webview/in_app_webview_manager.cpp")
    # The generated translation unit is outside the original source directory.
    # Resolve its original quoted includes from the plugin's Windows root.
    string(REPLACE "#include \"../" "#include \"" patched "${patched}")
    string(REPLACE "#include \"in_app_webview_manager.h\""
      "#include \"in_app_webview/in_app_webview_manager.h\"" patched "${patched}")
    string(REPLACE "#include <windows.graphics.capture.h>"
      "#include <windows.graphics.capture.h>\n#include <winrt/Windows.Foundation.h>\n#include <winrt/Windows.System.h>"
      patched "${patched}")
  elseif(relative_source STREQUAL "flutter_inappwebview_windows_plugin.cpp")
    get_filename_component(patch_dir "${before_file}" DIRECTORY)
    set(constructor_before_file "${patch_dir}/plugin_constructor.before.cpp")
    set(constructor_after_file "${patch_dir}/plugin_constructor.after.cpp")
    set(shutdown_hook_file "${patch_dir}/plugin_shutdown_hook.cpp")
    file(READ "${constructor_before_file}" constructor_before)
    file(READ "${constructor_after_file}" constructor_after)
    file(READ "${shutdown_hook_file}" shutdown_hook)
    string(REPLACE "\r\n" "\n" constructor_before "${constructor_before}")
    string(REPLACE "\r\n" "\n" constructor_after "${constructor_after}")
    string(REPLACE "\r\n" "\n" shutdown_hook "${shutdown_hook}")
    string(FIND "${patched}" "${constructor_before}" constructor_position)
    if(constructor_position EQUAL -1)
      message(FATAL_ERROR "Mumpa WebView shutdown patch: expected constructor not found")
    endif()
    string(LENGTH "${constructor_before}" constructor_length)
    math(EXPR constructor_end "${constructor_position} + ${constructor_length}")
    string(SUBSTRING "${patched}" ${constructor_end} -1 constructor_remaining)
    string(FIND "${constructor_remaining}" "${constructor_before}" constructor_duplicate)
    if(NOT constructor_duplicate EQUAL -1)
      message(FATAL_ERROR "Mumpa WebView shutdown patch: ambiguous constructor")
    endif()
    string(REPLACE "${constructor_before}" "${constructor_after}" patched "${patched}")
    set(hook_anchor "#pragma comment(lib, \"d3d11.lib\")")
    string(FIND "${patched}" "${hook_anchor}" hook_position)
    if(hook_position EQUAL -1)
      message(FATAL_ERROR "Mumpa WebView shutdown patch: hook anchor not found")
    endif()
    string(LENGTH "${hook_anchor}" hook_anchor_length)
    math(EXPR hook_end "${hook_position} + ${hook_anchor_length}")
    string(SUBSTRING "${patched}" ${hook_end} -1 hook_remaining)
    string(FIND "${hook_remaining}" "${hook_anchor}" hook_duplicate)
    if(NOT hook_duplicate EQUAL -1)
      message(FATAL_ERROR "Mumpa WebView shutdown patch: ambiguous hook anchor")
    endif()
    string(REPLACE "${hook_anchor}" "${hook_anchor}\n\n${shutdown_hook}" patched "${patched}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
      "${constructor_before_file}" "${constructor_after_file}" "${shutdown_hook_file}")
  endif()

  set(overlay "${CMAKE_BINARY_DIR}/mumpa_plugin_patches/${relative_source}")
  get_filename_component(overlay_dir "${overlay}" DIRECTORY)
  file(MAKE_DIRECTORY "${overlay_dir}")
  set(previous "")
  if(EXISTS "${overlay}")
    file(READ "${overlay}" previous)
  endif()
  if(NOT previous STREQUAL patched)
    file(WRITE "${overlay}" "${patched}")
  endif()

  get_target_property(plugin_sources ${plugin_target} SOURCES)
  set(patched_sources "")
  set(replacements 0)
  foreach(plugin_source IN LISTS plugin_sources)
    if(plugin_source MATCHES "^\\$<")
      list(APPEND patched_sources "${plugin_source}")
    else()
      get_filename_component(absolute_source "${plugin_source}" ABSOLUTE
        BASE_DIR "${plugin_source_dir}")
      if(absolute_source STREQUAL original)
        list(APPEND patched_sources "${overlay}")
        math(EXPR replacements "${replacements} + 1")
      else()
        list(APPEND patched_sources "${absolute_source}")
      endif()
    endif()
  endforeach()
  if(NOT replacements EQUAL 1)
    message(FATAL_ERROR "Mumpa WebView shutdown patch: expected exactly one target source (${relative_source})")
  endif()
  set_property(TARGET ${plugin_target} PROPERTY SOURCES "${patched_sources}")
  target_include_directories(${plugin_target} PRIVATE "${plugin_source_dir}")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${original}" "${before_file}" "${after_file}")
  message(STATUS "Mumpa: applied pinned WebView shutdown overlay (${relative_source})")
endfunction()

mumpa_overlay_webview_source(
  "in_app_webview/in_app_webview_manager.cpp"
  "eefc7b984c208696b3a3a34f99b0ddc11779fb7470009ebbabcfd274421d77ab"
  "${CMAKE_CURRENT_LIST_DIR}/manager_destructor.before.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/manager_destructor.after.cpp")
mumpa_overlay_webview_source(
  "flutter_inappwebview_windows_plugin.cpp"
  "635531a17e4ac0dd103002cec0288b98016cd2be2db06e56944c216c3862389a"
  "${CMAKE_CURRENT_LIST_DIR}/plugin_destructor.before.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/plugin_destructor.after.cpp")

# C++/WinRT error and async helpers need the Windows Runtime import library.
target_link_libraries(flutter_inappwebview_windows_plugin PRIVATE runtimeobject)
