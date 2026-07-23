#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

header(){
    local title="${1:-NetKit}"

    echo
    divider "$CYAN"
    center_line "$title" "$WHITE"
    divider "$CYAN"
}

run_script(){
    local file="$1"
    shift

    if [[ ! -f "$file" ]]; then
        error "脚本不存在: $file"
        pause
        return 1
    fi

    bash "$file" "$@"
}

run_script_and_pause(){
    local status=0

    run_script "$@" || status=$?
    [[ "$status" -eq "$INPUT_CANCEL_STATUS" ]] && return 0
    pause
}

split_items(){
    local input="$1"
    printf '%s\n' $input
}

reject_comma_separator(){
    [[ "$1" == *","* ]] && error "请使用空格分隔，不要使用逗号。" && pause && return 1
    return 0
}

ensure_apt_package(){
    local package="$1"

    if dpkg -s "$package" >/dev/null 2>&1; then
        success "${package} 已安装。"
        return
    fi

    info "正在安装 ${package}..."
    apt update
    apt install -y "$package"
}
