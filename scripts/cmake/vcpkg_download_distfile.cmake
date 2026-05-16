function(z_vcpkg_check_hash result file_path sha512)
    file(SHA512 "${file_path}" file_hash)
    string(TOLOWER "${sha512}" sha512_lower)
    string(COMPARE EQUAL "${file_hash}" "${sha512_lower}" hash_match)
    set("${result}" "${hash_match}" PARENT_SCOPE)
endfunction()

function(z_vcpkg_download_distfile_test_hash file_path kind error_advice sha512 skip_sha512)
    if(_VCPKG_INTERNAL_NO_HASH_CHECK)
        # When using the internal hash skip, do not output an explicit message.
        return()
    endif()
    if(skip_sha512)
        message(STATUS "Skipping hash check for ${file_path}.")
        return()
    endif()

    set(hash_match OFF)
    z_vcpkg_check_hash(hash_match "${file_path}" "${sha512}")

    if(NOT hash_match)
        message(FATAL_ERROR
            "\nFile does not have expected hash:\n"
            "        File path: [ ${file_path} ]\n"
            "    Expected hash: [ ${sha512} ]\n"
            "      Actual hash: [ ${file_hash} ]\n"
            "${error_advice}\n")
    endif()
endfunction()

function(z_vcpkg_download_distfile_show_proxy_and_fail error_code)
    message(FATAL_ERROR
        "    Failed to download file with error: ${error_code}\n")
endfunction()

function(z_vcpkg_download_distfile_via_aria)
    cmake_parse_arguments(PARSE_ARGV 1 arg
        "SKIP_SHA512"
        "FILENAME;SHA512"
        "URLS;HEADERS"
    )

    message(STATUS "Using Aria2")  # Updated to display the URL
    message(STATUS "Downloading ${arg_FILENAME}...")

    vcpkg_list(SET headers_param)
    foreach(header IN LISTS arg_HEADERS)
        vcpkg_list(APPEND headers_param "--header=${header}")
    endforeach()

    foreach(URL IN LISTS arg_URLS)
        message(STATUS "Download Command: ${ARIA2} ${URL} -o temp/${filename} -l download-${filename}-detailed.log ${headers_param}")
        vcpkg_execute_in_download_mode(
            COMMAND ${ARIA2} ${URL}
            -o temp/${arg_FILENAME}
            -l download-${arg_FILENAME}-detailed.log
            ${headers_param}
            OUTPUT_FILE download-${arg_FILENAME}-out.log
            ERROR_FILE download-${arg_FILENAME}-err.log
            RESULT_VARIABLE error_code
            WORKING_DIRECTORY "${DOWNLOADS}"
        )
        
        if ("${error_code}" STREQUAL "0")
            break()
        endif()
    endforeach()
    if (NOT "${error_code}" STREQUAL "0")
        message(STATUS
            "Downloading ${arg_FILENAME}... Failed.\n"
            "    Exit Code: ${error_code}\n"
            "    See logs for more information:\n"
            "        ${DOWNLOADS}/download-${arg_FILENAME}-out.log\n"
            "        ${DOWNLOADS}/download-${arg_FILENAME}-err.log\n"
            "        ${DOWNLOADS}/download-${arg_FILENAME}-detailed.log\n"
        )
        z_vcpkg_download_distfile_show_proxy_and_fail("${error_code}")
    else()
        z_vcpkg_download_distfile_test_hash(
            "${DOWNLOADS}/temp/${arg_FILENAME}"
            "downloaded file"
            "The file may have been corrupted in transit."
            "${arg_SHA512}"
            ${arg_SKIP_SHA512}
        )
        file(REMOVE
            ${DOWNLOADS}/download-${arg_FILENAME}-out.log
            ${DOWNLOADS}/download-${arg_FILENAME}-err.log
            ${DOWNLOADS}/download-${arg_FILENAME}-detailed.log
        )
        get_filename_component(downloaded_file_dir "${downloaded_file_path}" DIRECTORY)
        file(MAKE_DIRECTORY "${downloaded_file_dir}")
        file(RENAME "${DOWNLOADS}/temp/${arg_FILENAME}" "${downloaded_file_path}")
    endif()
endfunction()

function(vcpkg_download_distfile out_var)
    cmake_parse_arguments(PARSE_ARGV 1 arg
        "SKIP_SHA512;SILENT_EXIT;QUIET;ALWAYS_REDOWNLOAD;DISABLE_ARIA2"
        "FILENAME;SHA512"
        "URLS;HEADERS"
    )

    if(NOT DEFINED arg_URLS)
        message(FATAL_ERROR "vcpkg_download_distfile requires a URLS argument.")
    endif()
    if(NOT DEFINED arg_FILENAME)
        message(FATAL_ERROR "vcpkg_download_distfile requires a FILENAME argument.")
    endif()
    if(arg_SILENT_EXIT)
        message(WARNING "SILENT_EXIT no longer has any effect. To resolve this warning, remove SILENT_EXIT.")
    endif()

    if(arg_ALWAYS_REDOWNLOAD AND NOT arg_SKIP_SHA512)
        message(FATAL_ERROR "ALWAYS_REDOWNLOAD requires SKIP_SHA512")
    endif()

    if(NOT arg_SKIP_SHA512 AND NOT DEFINED arg_SHA512)
        message(FATAL_ERROR "vcpkg_download_distfile requires a SHA512 argument.
If you do not know the SHA512, add it as 'SHA512 0' and retry.")
    elseif(arg_SKIP_SHA512 AND DEFINED arg_SHA512)
        message(FATAL_ERROR "SHA512 may not be used with SKIP_SHA512.")
    endif()

    if(_VCPKG_INTERNAL_NO_HASH_CHECK)
        set(arg_SKIP_SHA512 1)
    endif()

    if(NOT arg_SKIP_SHA512)
        if("${arg_SHA512}" STREQUAL "0")
            string(REPEAT 0 128 arg_SHA512)
        else()
            string(LENGTH "${arg_SHA512}" arg_SHA512_length)
            if(NOT "${arg_SHA512_length}" EQUAL "128" OR NOT "${arg_SHA512}" MATCHES "^[a-zA-Z0-9]*$")
                message(FATAL_ERROR "Invalid SHA512: ${arg_SHA512}.
    If you do not know the file's SHA512, set this to \"0\".")
            endif()
            string(TOLOWER "${arg_SHA512}" arg_SHA512)
        endif()
    endif()

    set(downloaded_file_path "${DOWNLOADS}/${arg_FILENAME}")

    get_filename_component(directory_component "${arg_FILENAME}" DIRECTORY)
    if ("${directory_component}" STREQUAL "")
        file(MAKE_DIRECTORY "${DOWNLOADS}")
    else()
        file(MAKE_DIRECTORY "${DOWNLOADS}/${directory_component}")
    endif()

    if(EXISTS "${downloaded_file_path}")
        if(arg_SKIP_SHA512)
            if(NOT arg_ALWAYS_REDOWNLOAD)
                if(NOT _VCPKG_INTERNAL_NO_HASH_CHECK)
                    message(STATUS "Skipping hash check and using cached ${arg_FILENAME}")
                endif()
                set("${out_var}" "${downloaded_file_path}" PARENT_SCOPE)
                return()
            endif()
        else()
            file(SHA512 "${downloaded_file_path}" file_hash)
            if("${file_hash}" STREQUAL "${arg_SHA512}")
                message(STATUS "Using cached ${arg_FILENAME}")
                set("${out_var}" "${downloaded_file_path}" PARENT_SCOPE)
                return()
            endif()

            get_filename_component(filename_component "${arg_FILENAME}" NAME_WE)
            get_filename_component(extension_component "${arg_FILENAME}" EXT)
            string(SUBSTRING "${arg_SHA512}" 0 8 hash)
            set(arg_FILENAME "${filename_component}-${hash}${extension_component}")
            if (NOT "${directory_component}" STREQUAL "")
                set(arg_FILENAME "${directory_component}/${arg_FILENAME}")
            endif()

            set(downloaded_file_path "${DOWNLOADS}/${arg_FILENAME}")
            if(EXISTS "${downloaded_file_path}")
                if(_VCPKG_NO_DOWNLOADS)
                    set(advice_message "note: Downloads are disabled. Please ensure that the expected file is placed at ${downloaded_file_path} and retry.")
                else()
                    set(advice_message "note: You may be able to resolve this failure by redownloading the file. To do so, delete ${downloaded_file_path} and retry.")
                endif()

                file(SHA512 "${downloaded_file_path}" file_hash)
                if("${file_hash}" STREQUAL "${arg_SHA512}")
                    message(STATUS "Using cached ${arg_FILENAME}")
                    set("${out_var}" "${downloaded_file_path}" PARENT_SCOPE)
                    return()
                endif()

                message(FATAL_ERROR
                    "  ${downloaded_file_path}: error: existing downloaded file had an unexpected hash\n"
                    "  Expected: ${arg_SHA512}\n"
                    "  Actual  : ${file_hash}\n"
                    "  ${advice_message}")
            endif()
        endif()
    endif()

    if(_VCPKG_NO_DOWNLOADS)
        message(FATAL_ERROR "Downloads are disabled, but '${downloaded_file_path}' does not exist.")
    endif()

    # 保存原始URL列表以备回退使用
    vcpkg_list(SET arg_URLS_Original)
    foreach(url IN LISTS arg_URLS)
        vcpkg_list(APPEND arg_URLS_Original "${url}")
    endforeach()


    # 你的镜像替换逻辑（核心修改部分）
    vcpkg_list(SET urls_param)
    vcpkg_list(SET arg_URLS_Real)
    foreach(url IN LISTS arg_URLS)
        string(REPLACE "http://download.savannah.nongnu.org/releases/gta/" "https://marlam.de/gta/releases/" url "${url}")
        string(REPLACE "https://github.com/" "https://gh.llkk.cc/https://github.com/" url "${url}")
        string(REPLACE "https://ftp.gnu.org/" "https://mirrors.aliyun.com/" url "${url}")
        string(REPLACE "https://raw.githubusercontent.com/" "https://gh.llkk.cc/https://raw.githubusercontent.com/" url "${url}")
        string(REPLACE "http://ftp.gnu.org/pub/gnu/" "https://mirrors.aliyun.com/gnu/" url "${url}")
        string(REPLACE "https://ftp.postgresql.org/pub/" "https://mirrors.tuna.tsinghua.edu.cn/postgresql/" url "${url}")
        string(REPLACE "https://support.hdfgroup.org/ftp/lib-external/szip/2.1.1/src/" "https://distfiles.macports.org/szip/" url "${url}")

        vcpkg_list(APPEND urls_param "--url=${url}")
        vcpkg_list(APPEND arg_URLS_Real "${url}")
    endforeach()

    if(NOT vcpkg_download_distfile_QUIET)
        message(STATUS "Downloading ${arg_URLS_Real} -> ${arg_FILENAME}...")
    endif()

    # 优先尝试 ARIA2 下载（远程仓库新增功能）
    if(NOT arg_DISABLE_ARIA2 AND _VCPKG_DOWNLOAD_TOOL STREQUAL "ARIA2" AND NOT EXISTS "${downloaded_file_path}")
        if (arg_SKIP_SHA512)
            set(OPTION_SKIP_SHA512 "SKIP_SHA512")
        endif()
        
        # 尝试使用镜像URL下载
        z_vcpkg_download_distfile_via_aria(
            "${OPTION_SKIP_SHA512}"
            FILENAME "${arg_FILENAME}"
            SHA512 "${arg_SHA512}"
            URLS "${arg_URLS_Real}"
            HEADERS "${arg_HEADERS}"
        )
        
        # 检查下载是否成功
        if(EXISTS "${downloaded_file_path}")
            set("${out_var}" "${downloaded_file_path}" PARENT_SCOPE)
            return()
        endif()
                
        # 镜像下载失败，尝试使用原始URL
        message(STATUS "镜像下载失败，尝试使用原始URL下载...")
        z_vcpkg_download_distfile_via_aria(
            "${OPTION_SKIP_SHA512}"
            FILENAME "${arg_FILENAME}"
            SHA512 "${arg_SHA512}"
            URLS "${arg_URLS_Original}"
            HEADERS "${arg_HEADERS}"
        )
        
        # 检查原始URL下载是否成功
        if(EXISTS "${downloaded_file_path}")
            set("${out_var}" "${downloaded_file_path}" PARENT_SCOPE)
            return()
        endif()
    endif()
    # 默认下载逻辑
    vcpkg_list(SET headers_param)
    foreach(header IN LISTS arg_HEADERS)
        vcpkg_list(APPEND headers_param "--header=${header}")
    endforeach()
    
    # 准备命令行参数
    vcpkg_list(SET download_params x-download "${arg_FILENAME}")
    
    # 添加URL参数
    foreach(url IN LISTS arg_URLS_Real)
        vcpkg_list(APPEND download_params "--url=${url}")
    endforeach()
    
    # 添加SHA512参数（如果需要）
    if(arg_SKIP_SHA512)
        vcpkg_list(APPEND download_params "--skip-sha512")
    else()
        vcpkg_list(APPEND download_params "--sha512=${arg_SHA512}")
    endif()
    
    # 添加headers参数
    foreach(header IN LISTS arg_HEADERS)
        vcpkg_list(APPEND download_params "--header=${header}")
    endforeach()
    
    # 首先尝试使用镜像URL
    vcpkg_execute_in_download_mode(
        COMMAND "$ENV{VCPKG_COMMAND}" ${download_params}
        RESULT_VARIABLE mirror_error_code
        WORKING_DIRECTORY "${DOWNLOADS}"
        ERROR_VARIABLE error_output
        OUTPUT_QUIET
    )
    
    # 如果镜像下载失败，尝试原始URL
    if(NOT "${mirror_error_code}" EQUAL "0")
        message(STATUS "镜像站下载失败，尝试使用原始URL下载...")
        
        # 重置下载参数
        vcpkg_list(SET download_params x-download "${arg_FILENAME}")
        
        # 添加原始URL参数
        foreach(url IN LISTS arg_URLS_Original)
            vcpkg_list(APPEND download_params "--url=${url}")
        endforeach()
        
        # 添加SHA512参数（如果需要）
        if(arg_SKIP_SHA512)
            vcpkg_list(APPEND download_params "--skip-sha512")
        else()
            vcpkg_list(APPEND download_params "--sha512=${arg_SHA512}")
        endif()
        
        # 添加headers参数
        foreach(header IN LISTS arg_HEADERS)
            vcpkg_list(APPEND download_params "--header=${header}")
        endforeach()
        
        vcpkg_execute_in_download_mode(
            COMMAND "$ENV{VCPKG_COMMAND}" ${download_params}
            RESULT_VARIABLE error_code
            WORKING_DIRECTORY "${DOWNLOADS}"
        )
        
        if(NOT "${error_code}" EQUAL "0")
            message(FATAL_ERROR "镜像站和原始URL下载均失败，无法继续。")
        endif()
    endif()

    set("${out_var}" "${downloaded_file_path}" PARENT_SCOPE)
endfunction()