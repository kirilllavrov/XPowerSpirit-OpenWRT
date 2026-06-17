#!/bin/sh
# RPC endpoint для LuCI: чтение и запись Xray-конфигов
# Вызывается через rpcd file exec

SETTINGS="/etc/xray/settings.json"
CONFIG="/etc/xray/config.json"

case "$1" in
    list)
        echo '{"xray-rw": {"read": ["settings","config","health"], "write": ["update"]}}'
        ;;
    call)
        case "$2" in
            # ─── ЧТЕНИЕ ───
            settings)
                [ -f "$SETTINGS" ] && cat "$SETTINGS" || echo '{}'
                ;;
            config)
                [ -f "$CONFIG" ] && cat "$CONFIG" || echo '{}'
                ;;
            health)
                XRAY_RUNNING=0; PORT_OK=0; NFT_OK=0
                pgrep -x xray >/dev/null 2>&1 && XRAY_RUNNING=1
                ss -tuln 2>/dev/null | grep -q ':12345' && PORT_OK=1
                nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q 'tproxy ip to 127.0.0.1:12345' && NFT_OK=1
                echo "{\"xray_running\":$XRAY_RUNNING,\"tproxy_port\":$PORT_OK,\"nftables_ok\":$NFT_OK}"
                ;;

            # ─── ЗАПИСЬ: обновление настроек подписки ───
            update)
                INPUT=$(cat)
                [ -z "$INPUT" ] && { echo '{"error":"empty input"}'; exit 1; }

                if ! echo "$INPUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
                    echo '{"error":"invalid JSON"}'
                    exit 1
                fi

                CURRENT=$([ -f "$SETTINGS" ] && cat "$SETTINGS" || echo '{}')

                RESULT=$(python3 -c "
import json
c = json.loads('$CURRENT')
u = json.loads('$INPUT')
if 'subscription' not in c: c['subscription'] = {}
s = c['subscription']
for k in ('url','user_agent','remarks_filter'): 
    if k in u and u[k] is not None: s[k] = u[k]
if 'domain_whitelist' in u and u['domain_whitelist'] is not None:
    s['domain_whitelist'] = u['domain_whitelist']
json.dump(c, open('$SETTINGS','w'), indent=2, ensure_ascii=False)
print('ok')
" 2>/dev/null)

                if [ "$RESULT" = "ok" ]; then
                    logger -t luci-xray "Settings updated via LuCI"
                    echo '{"status":"ok"}'
                else
                    echo '{"error":"python merge failed","details":"'"$RESULT"'"}'
                fi
                ;;
            *)
                echo '{"error":"unknown method"}'
                ;;
        esac
        ;;
esac
