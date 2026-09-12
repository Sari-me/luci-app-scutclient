#
# Copyright (C) 2016 SCUT Router Term
#
# This is free software, licensed under the Apache License, Version 2.0 .
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-scutclient
PKG_VERSION:=1.4.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI support for scutclient
LUCI_DEPENDS:=+scutclient +luci-compat
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
