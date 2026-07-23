#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

tools_menu(){
    while true; do
        header "工具箱"
        menu_item "1" "VPS 测试"
        menu_item "2" "DD 系统 Debian"
        menu_item "3" "安装 XanMod 内核（BBRv3）"
        menu_item "4" "UFW 防火墙管理"
        menu_item "5" "Fail2Ban 管理"
        menu_item "6" "SSH 端口与密钥管理"
        menu_item "7" "虚拟内存管理"
        menu_item "8" "时区调整"
        menu_item "9" "系统调优"
        menu_item "10" "IPv6 管理"
        menu_item "11" "MTU 设置"
        menu_item "12" "自动更新与自动重启"
        echo
        menu_item "0" "返回主菜单"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) run_vps_test ;;
            2) dd_debian ;;
            3) install_xanmod_kernel ;;
            4) ufw_menu ;;
            5) fail2ban_menu ;;
            6) ssh_menu ;;
            7) swap_menu ;;
            8) set_timezone ;;
            9) system_tuning ;;
            10) ipv6_menu ;;
            11) configure_mtu ;;
            12) configure_auto_updates ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
