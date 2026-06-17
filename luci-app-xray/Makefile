#
# Copyright (C) 2026 XPowerSpirit Team
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Xray Status Dashboard
LUCI_DESCRIPTION:=Web dashboard for Xray TProxy on OpenWrt. Displays system info, subscription status, proxy servers, and routing rules from /etc/xray/settings.json and /etc/xray/config.json.
LUCI_DEPENDS:=+luci-base +xray-core +python3-light
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=XPowerSpirit Team
PKG_VERSION:=1.0.0

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
