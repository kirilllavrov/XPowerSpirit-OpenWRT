#!/bin/sh

echo "=== Configuring Home + Direct WiFi (MTK, no VLAN) ==="

###############################################
# 1. NETWORK: создаём br-guest
###############################################

uci -q delete network.brguest
uci -q delete network.guest

uci set network.brguest=device
uci set network.brguest.type='bridge'
uci set network.brguest.name='br-guest'

uci set network.guest=interface
uci set network.guest.device='br-guest'
uci set network.guest.proto='static'
uci set network.guest.ipaddr='192.168.50.1'
uci set network.guest.netmask='255.255.255.0'

###############################################
# 2. DHCP
###############################################

uci -q delete dhcp.guest
uci set dhcp.guest=dhcp
uci set dhcp.guest.interface='guest'
uci set dhcp.guest.start='100'
uci set dhcp.guest.limit='150'
uci set dhcp.guest.leasetime='12h'

###############################################
# 3. FIREWALL
###############################################

uci -q delete firewall.guest
uci -q delete firewall.guest_fwd

uci add firewall zone
uci set firewall.@zone[-1].name='guest'
uci set firewall.@zone[-1].network='guest'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='guest'
uci set firewall.@forwarding[-1].dest='wan'

###############################################
# 4. Удаляем ВСЕ старые Wi-Fi iface
###############################################

count=$(uci show wireless | grep "=wifi-iface" | wc -l)
i=0
while [ $i -lt $count ]; do
    uci delete wireless.@wifi-iface[0]
    i=$((i+1))
done

###############################################
# 5. Home WiFi (через Xray)
###############################################

# radio0
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio0'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Home'
uci set wireless.@wifi-iface[-1].network='lan'
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key='yourpassword'

# radio1
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio1'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Home'
uci set wireless.@wifi-iface[-1].network='lan'
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key='yourpassword'

###############################################
# 6. Direct WiFi (напрямую)
###############################################

# radio0
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio0'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Direct'
uci set wireless.@wifi-iface[-1].network='guest'
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key='guestpassword'

# radio1
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio1'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Direct'
uci set wireless.@wifi-iface[-1].network='guest'
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key='guestpassword'

###############################################
# 7. APPLY
###############################################

uci commit network
uci commit dhcp
uci commit firewall
uci commit wireless

/etc/init.d/network restart
wifi reload

echo "=== WiFi Home + Direct configured successfully ==="
