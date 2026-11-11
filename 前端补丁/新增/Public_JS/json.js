/* 顶部导航各菜单下的入口。[0] 路由设置 [1] 设备管理 [2] 高级功能（这三个由原厂 main.js 渲染）；
   [3] 外网访问 [4] 网络服务（由 kel-nav.js 渲染）。 */
const tabListData = [
    [
        {
            "title": "Wi-Fi设置",
            "url": "./routerSet/wifi.html",
            "img": "../../P_IMG/menu-wifi.png"
        },
        {
            "title": "上网设置",
            "url": "./routerSet/internet.html",
            "img": "../../P_IMG/menu-internet.png"
        },
        {
            "title": "访客网络",
            "url": "./routerSet/guest_content.html",
            "img": "../../P_IMG/menu-guest.png"
        },
        {
            "title": "局域网设置",
            "url": "./routerSet/localnet.html",
            "img": "../../P_IMG/menu-lan.png"
        },
        {
            "title": "系统",
            "url": "./routerSet/system.html",
            "img": "../../P_IMG/menu-system.png"
        }
    ],
    [
        {
            "title": "设备列表",
            "url": "./management/deviceList.html",
            "img": "../../P_IMG/dev-list.png"
        },
        {
            "title": "访问控制",
            "url": "./management/access.html",
            "img": "../../P_IMG/access-control.png"
        },
        {
            "title": "DHCP静态IP分配",
            "url": "./management/dhcp.html",
            "img": "../../P_IMG/static.png"
        }
    ],
    [
        {
            "title": "自定义Hosts",
            "url": "./seniorManagement/CustomHosts.html",
            "img": "../../P_IMG/hosts.png"
        },
        {
            "title": "网口自定义",
            "url": "./seniorManagement/HighSetting.html",
            "img": "../../P_IMG/high_setting.png"
        },
        {
            "title": "OpenWrt高级设置",
            "url": "./seniorManagement/openwrt.html",
            "img": "../../P_IMG/menu-openwrt.png"
        }
    ],
    [
        {
            "title": "DDNS",
            "url": "./seniorManagement/DDNS.html",
            "img": "../../P_IMG/DDNS.png"
        },
        {
            "title": "端口转发",
            "url": "./seniorManagement/portForward.html",
            "img": "../../P_IMG/menu-port-forward.png"
        },
        {
            "title": "IPv6防火墙",
            "url": "./seniorManagement/ipv6fw.html",
            "img": "../../P_IMG/menu-ipv6fw.svg"
        },
        {
            "title": "DMZ",
            "url": "./seniorManagement/DMZ.html",
            "img": "../../P_IMG/DMZ.png"
        },
        {
            "title": "UPnP",
            "url": "./seniorManagement/UPnP.html",
            "img": "../../P_IMG/UPnP.png"
        },
        {
            "title": "NAT设置",
            "url": "./seniorManagement/NATSet.html",
            "img": "../../P_IMG/menu-nat.png"
        }
    ],
    [
        {
            "title": "代理加速",
            "url": "./seniorManagement/clash.html",
            "img": "../../P_IMG/menu-proxy.png"
        },
        {
            "title": "广告过滤",
            "url": "./seniorManagement/adguard.html",
            "img": "../../P_IMG/menu-adg.png"
        }
    ]
];
