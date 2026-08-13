# luci-app-cfipopt — CF IP optimizer & speed test for edgetunnel
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cfipopt
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-cfipopt
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=CF IP optimizer & speed test (edgetunnel node list)
  URL:=https://github.com/cmliu/edgetunnel
  DEPENDS:=+curl +luci-base
  PKGARCH:=all
endef

define Package/luci-app-cfipopt/description
  Cloudflare IP 优选测速. 参照 cmliu/edgetunnel 的优选逻辑生成候选 IP,
  绕过 OpenClash/DAE 代理直连 speed.cloudflare.com 测速,
  输出可直接用于 edgetunnel 实例节点列表的 IP:端口#备注 结果.
endef

define Build/Compile
endef

define Package/luci-app-cfipopt/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/libexec/cfipopt
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/cfipopt
	$(INSTALL_CONF) ./files/etc/config/cfipopt $(1)/etc/config/
	$(INSTALL_BIN) ./files/usr/libexec/cfipopt/run.sh $(1)/usr/libexec/cfipopt/
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/luci.cfipopt $(1)/usr/share/rpcd/ucode/
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-cfipopt.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-cfipopt.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/cfipopt/overview.js $(1)/www/luci-static/resources/view/cfipopt/
endef

$(eval $(call BuildPackage,luci-app-cfipopt))
