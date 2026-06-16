# OpenWrt Makefile для xray-status
# Поместить в: feeds/packages/net/xray-status/Makefile
# Сборка: make package/xray-status/compile V=s

include $(TOPDIR)/rules.mk

PKG_NAME:=xray-status
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=XPowerSpirit Team
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/xray-status
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Xray Status Dashboard for OpenWrt
	DEPENDS:=+python3-light +xray-core
	PKGARCH:=all
endef

define Package/xray-status/description
	CLI-утилита для отображения статуса Xray TProxy.
	Читает /etc/xray/settings.json и /etc/xray/config.json,
	выводит дашборд с информацией о системе, подписке,
	прокси-серверах, роутинге и проверкой здоровья.
endef

define Build/Compile
	# Ничего не компилируем — это Python-скрипт
	true
endef

define Package/xray-status/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./src/xray-status.py $(1)/usr/bin/xray-status
endef

$(eval $(call BuildPackage,xray-status))
