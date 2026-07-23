#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

install_ufw(){
    header "安装 UFW"
    ensure_apt_package "ufw"
    ufw --force enable >/dev/null
    success "UFW 已安装并启用。"
    pause
}

ufw_batch_add_port(){
    header "允许端口"
    local input
    local port

    read -r -p "$(prompt_text "请输入要允许的端口（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "端口不能为空。" && pause && return
    reject_comma_separator "$input" || return

    for port in $(split_items "$input"); do
        valid_port "$port" || { error "端口无效: ${port}"; pause; return; }
    done

    for port in $(split_items "$input"); do
        ufw allow "${port}/tcp"
        ufw allow "${port}/udp"
        success "已允许端口: ${port}/tcp 和 ${port}/udp"
    done

    pause
}

ufw_batch_delete_port(){
    header "删除端口"

    local input
    local status_output
    local index
    local display_index
    local record
    local line
    local rule_number
    local port_spec
    local record_port
    local protocol
    local comment
    local descriptor
    local details
    local -A seen_details=()
    local -a rule_records=()
    local -a ports=()
    local -a requested_indexes=()
    local -a delete_rule_numbers=()
    local -A selected_indexes=()
    local -A selected_ports=()

    if ! command -v ufw >/dev/null 2>&1; then
        warning "UFW 未安装。"
        pause
        return
    fi

    if ! status_output=$(ufw status numbered); then
        error "无法读取 UFW 端口规则。"
        pause
        return
    fi

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+(:[0-9]+)?)(/(tcp|udp))?([[:space:]]|$) ]]; then
            rule_number="${BASH_REMATCH[1]}"
            port_spec="${BASH_REMATCH[2]}"
            protocol="${BASH_REMATCH[5]:-all}"
            comment=""
            [[ "$line" == *"#"* ]] && comment=$(trim_edges "${line#*#}")
            rule_records+=("${rule_number}|${port_spec}|${protocol}|${comment}")
        fi
    done <<< "$status_output"

    if [[ "${#rule_records[@]}" -eq 0 ]]; then
        warning "当前没有可删除的数字端口规则。"
        pause
        return
    fi

    mapfile -t ports < <(
        printf '%s\n' "${rule_records[@]}" | cut -d '|' -f2 | sort -n -u
    )

    section "当前 UFW 端口" "$YELLOW"
    echo
    label " 端口 / 协议 / 注释"
    echo
    for index in "${!ports[@]}"; do
        port_spec="${ports[$index]}"
        details=""
        seen_details=()

        for record in "${rule_records[@]}"; do
            IFS='|' read -r rule_number record_port protocol comment <<< "$record"
            [[ "$record_port" == "$port_spec" ]] || continue

            descriptor="$protocol"
            [[ -n "$comment" ]] && descriptor+=" · ${comment}"
            if [[ -z "${seen_details[$descriptor]:-}" ]]; then
                seen_details["$descriptor"]=1
                details+="${details:+; }${descriptor}"
            fi
        done

        menu_item "$((index + 1))" "${port_spec}  ${details}"
    done

    echo
    read -r -p "$(prompt_text "请输入要删除的序号（多个用空格分隔，0 取消）: ")" input
    input=$(trim_edges "$input")
    cancel_input "$input" && return

    if [[ -z "$input" ]]; then
        error "序号不能为空。"
        pause
        return
    fi

    read -r -a requested_indexes <<< "$input"

    for display_index in "${requested_indexes[@]}"; do
        if [[ ! "$display_index" =~ ^[0-9]+$ ]] || \
           (( display_index < 1 || display_index > ${#ports[@]} )); then
            error "无效序号：${display_index}。多个序号请使用空格分隔。"
            pause
            return
        fi

        selected_indexes["$display_index"]=1
        selected_ports["${ports[$((display_index - 1))]}"]=1
    done

    for record in "${rule_records[@]}"; do
        IFS='|' read -r rule_number record_port protocol comment <<< "$record"
        if [[ -n "${selected_ports[$record_port]:-}" ]]; then
            delete_rule_numbers+=("$rule_number")
        fi
    done

    mapfile -t delete_rule_numbers < <(
        printf '%s\n' "${delete_rule_numbers[@]}" | sort -rn -u
    )

    for rule_number in "${delete_rule_numbers[@]}"; do
        ufw --force delete "$rule_number" >/dev/null
    done

    for display_index in $(printf '%s\n' "${!selected_indexes[@]}" | sort -n); do
        port_spec="${ports[$((display_index - 1))]}"
        success "已删除端口 ${port_spec} 的 UFW 规则。"
    done

    pause
}

ufw_batch_add_ip(){
    header "允许 IP"
    local input
    local ip

    read -r -p "$(prompt_text "请输入要允许的 IP/CIDR（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return
    reject_comma_separator "$input" || return

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        ufw allow from "$ip"
        success "已允许 IP/CIDR: ${ip}"
    done

    pause
}

ufw_batch_delete_ip(){
    header "删除 IP"
    local input
    local ip

    read -r -p "$(prompt_text "请输入要删除的 IP/CIDR（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return
    reject_comma_separator "$input" || return

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        ufw --force delete allow from "$ip" || true
        success "已删除 IP/CIDR 规则: ${ip}"
    done

    pause
}

show_ufw_status(){
    header "UFW 状态"

    if ! command -v ufw >/dev/null 2>&1; then
        warning "UFW 未安装。"
        pause
        return
    fi

    ufw status verbose
    pause
}

uninstall_ufw(){
    header "卸载 UFW"
    warning "正在卸载 UFW..."
    ufw --force disable >/dev/null 2>&1 || true
    apt purge -y ufw
    apt autoremove -y
    success "UFW 已卸载。"
    pause
}

ufw_menu(){
    while true; do
        header "UFW 防火墙管理"
        menu_item "1" "安装 UFW"
        menu_item "2" "查看 UFW 状态"
        menu_item "3" "允许端口"
        menu_item "4" "删除端口"
        menu_item "5" "允许 IP"
        menu_item "6" "删除 IP"
        menu_item "7" "卸载 UFW"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_ufw ;;
            2) show_ufw_status ;;
            3) ufw_batch_add_port ;;
            4) ufw_batch_delete_port ;;
            5) ufw_batch_add_ip ;;
            6) ufw_batch_delete_ip ;;
            7) uninstall_ufw ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
