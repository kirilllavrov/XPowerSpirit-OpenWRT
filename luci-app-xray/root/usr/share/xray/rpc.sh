#!/bin/sh
# RPC endpoint: cat JSON-файлы Xray
# Вызывается LuCI через rpcd для получения данных для дашборда

case "$1" in
    list)
        echo '{"xray-status": {"settings": "/etc/xray/settings.json", "config": "/etc/xray/config.json"}}'
        ;;
    call)
        case "$2" in
            settings)
                if [ -f /etc/xray/settings.json ]; then
                    cat /etc/xray/settings.json
                else
                    echo '{}'
                fi
                ;;
            config)
                if [ -f /etc/xray/config.json ]; then
                    cat /etc/xray/config.json
                else
                    echo '{}'
                fi
                ;;
            health)
                # Быстрая проверка здоровья
                XRAY_RUNNING=0
                PORT_OK=0
                NFT_OK=0

                pgrep -x xray >/dev/null 2>&1 && XRAY_RUNNING=1
                ss -tuln 2>/dev/null | grep -q ':12345' && PORT_OK=1
                nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q 'tproxy ip to 127.0.0.1:12345' && NFT_OK=1

                echo "{\"xray_running\":$XRAY_RUNNING,\"tproxy_port\":$PORT_OK,\"nftables_ok\":$NFT_OK}"
                ;;
            *)
                echo '{"error": "unknown method"}'
                ;;
        esac
        ;;
esac
