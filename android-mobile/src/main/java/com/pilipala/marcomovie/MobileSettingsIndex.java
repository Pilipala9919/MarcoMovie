package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Searchable catalog of all 50+ mobile settings across the 7 independent mobile setting sub-pages,
 * powering instant keyword filtering, direct sub-page jump, and target row highlight flash
 * ({@code SettingsFlash}).
 */
final class MobileSettingsIndex {
    static final class Entry {
        final int subPage;
        final String key;
        final String groupName;
        final String title;
        final String keywords;

        Entry(int subPage, String key, String groupName, String title, String keywords) {
            this.subPage = subPage;
            this.key = key;
            this.groupName = groupName;
            this.title = title;
            this.keywords = keywords;
        }
    }

    private static final List<Entry> ALL = new ArrayList<>();

    static {
        // 1. 片源与直播
        add(1, "ms-clip-import", "片源与直播", "一键读取剪贴板导入配置", "粘贴 订阅 网址 json js py");
        add(1, "ms-url-import", "片源与直播", "输入配置网址或选择本地包", "多仓 zip 本地 文件 订阅源");
        add(1, "ms-switch-site", "片源与直播", "切换默认首页片源", "换源 站点 默认源");
        add(1, "ms-sub-auto", "片源与直播", "订阅源每日自动更新与立即刷新", "自动更新 刷新 订阅 多源 合并");
        add(1, "ms-live-import", "片源与直播", "电视直播源管理 (M3U / TXT / JSON)", "直播 频道 iptv m3u");
        add(1, "ms-live-epg", "片源与直播", "自定义 XMLTV 节目单 (EPG)", "epg 预告 回看 节目表");
        add(1, "ms-live-udpxy", "片源与直播", "组播转单播网关 (udpxy)", "udpxy rtp 组播 原画");
        add(1, "ms-live-hq", "片源与直播", "直播优先最高画质与 IPv6", "ipv6 4k 高清 直播");
        add(1, "ms-ext-csp", "片源与直播", "第三方爬虫扩展引擎 (JAR / CPython / JS)", "插件 扩展 python js jar");
        add(1, "ms-search-sidebar", "片源与直播", "搜索结果平台列表布局", "侧边栏 顶部 搜索 并发");

        // 2. 外观与导航
        add(2, "ms-ui-scale", "外观与导航", "手机界面整体缩放", "字号 放大 缩小 比例 dpi");
        add(2, "ms-accent", "外观与导航", "主题强调色预设", "配色 主题色 翡翠 蓝 粉 紫");
        add(2, "ms-nav-style", "外观与导航", "底部导航栏样式 (液态玻璃 4+1 / 紧凑胶囊)", "底栏 搜索按钮 扁平 玻璃");
        add(2, "ms-nav-scroll", "外观与导航", "底栏滚动折叠与隐藏行为", "上滑 折叠 隐藏 常驻 导航");
        add(2, "ms-home-mode", "外观与导航", "首页发现视图模式 (片源 / TMDB 推荐)", "首页 tmdb 发现 榜单");
        add(2, "ms-home-banner", "外观与导航", "首页精选大图横幅", "轮播 海报 头图");
        add(2, "ms-cover-ambient", "外观与导航", "封面主色自适应柔光背景", "氛围 取色 背景 柔光");
        add(2, "ms-wallpaper", "外观与导航", "自定义背景图与遮挡压暗度", "壁纸 背景图 遮挡 压暗");
        add(2, "ms-glass-toggle", "外观与导航", "液态玻璃透明效果与动画精简", "毛玻璃 透明 动画 流畅 省电");

        // 3. 播放与手势
        add(3, "ms-detail-tap", "播放与手势", "详情页点选剧集起播方式", "内嵌 小窗 全屏 竖屏 详情页");
        add(3, "ms-ep-clean", "播放与手势", "详情页选集集名净化模式", "正则 净化 原名 乱码 集名");
        add(3, "ms-player-engine", "播放与手势", "默认播放内核与失败自动切核", "mpv media3 exo 系统 内核");
        add(3, "ms-decoder-mode", "播放与手势", "硬解 / 软解与 MPV 超分色调映射", "硬解 软解 hdr anime4k 超分");
        add(3, "ms-letterbox", "播放与手势", "宽银幕黑边氛围柔光虚化", "黑边 虚化 比例 画面");
        add(3, "ms-swipe-swap", "播放与手势", "左右半屏亮度与音量手势互换", "手势 左手 右手 亮度 音量");
        add(3, "ms-src-bright", "播放与手势", "按片源独立记忆播放亮度", "亮度 记忆 屏幕");
        add(3, "ms-long-speed", "播放与手势", "长按倍速播放档位", "倍速 2x 3x 加速 快进");
        add(3, "ms-vert-ep", "播放与手势", "双指上下滑防误触切换上下集", "双指 换集 上下滑 短剧");
        add(3, "ms-corner-hud", "播放与手势", "播放页角落常驻状态信息与迷你进度条", "网速 电量 时间 帧率 迷你进度条");
        add(3, "ms-btn-order", "播放与手势", "播放页工具栏按钮顺序编排", "按钮 排序 顶栏 底栏 自定义");
        add(3, "ms-skip-intro", "播放与手势", "TheIntroDB 自动跳过片头与手动片头片尾", "片头 片尾 跳过 introdb");
        add(3, "ms-pip-bg", "播放与手势", "自动画中画小窗 (PiP) 与后台音频播放", "小窗 画中画 后台 锁屏");
        add(3, "ms-hls-ad", "播放与手势", "HLS 伪装头清洗与切片广告过滤", "去广告 m3u8 hls 响度 增益");

        // 4. 字幕与弹幕
        add(4, "ms-sub-adjust", "字幕与弹幕", "全屏字幕触控可视化调校", "字幕 大小 底距 描边 样式");
        add(
                4,
                "ms-online-sub",
                "字幕与弹幕",
                "在线字幕站配置 (射手网 Assrt / OpenSubtitles)",
                "在线字幕 assrt opensubtitles token");
        add(4, "ms-sub-bilingual", "字幕与弹幕", "AI 字幕实时翻译保留双语对照", "双语 翻译 ai 字幕");
        add(4, "ms-danmaku-style", "字幕与弹幕", "弹幕显示区域、不透明度与滚动速度", "弹幕 半屏 透明度 速度 开关");
        add(4, "ms-danmaku-src", "字幕与弹幕", "弹幕源管理与一键测速排序", "弹弹play dandan logvar 测速 弹幕源");

        // 5. 刮削、账号与 AI 服务
        add(5, "ms-tmdb-cfg", "刮削、账号与 AI", "TMDB API Key 与镜像反代配置", "tmdb 刮削 剧照 海报 反代 语言");
        add(5, "ms-mdblist-cfg", "刮削、账号与 AI", "MDBList 聚合评分密钥 (IMDb / 烂番茄)", "评分 imdb 烂番茄 mdblist");
        add(5, "ms-bgm-trakt", "刮削、账号与 AI", "Bangumi / Trakt 追剧日历账号绑定", "追剧 日历 bangumi trakt 豆瓣");
        add(5, "ms-ai-cfg", "刮削、账号与 AI", "AI 大模型服务商与模型配置", "ai deepseek 通义千问 硅基流动 kimi glm ollama");

        // 6. 云同步、网盘与隐私
        add(6, "ms-cloud-sync", "云同步、网盘与隐私", "WebDAV 云盘自动增量同步与局域网同步", "webdav 云同步 历史 收藏 备份");
        add(6, "ms-netdisk", "云同步、网盘与隐私", "网盘扫码授权与顺序管理", "夸克 阿里 百度 uc 网盘 账号");
        add(6, "ms-alist", "云同步、网盘与隐私", "AList 原生挂载源管理", "alist webdav 挂载 网盘");
        add(6, "ms-privacy", "云同步、网盘与隐私", "隐私空间独立加密环境", "隐私 密码 隐藏 加密");
        add(6, "ms-spider-gw", "云同步、网盘与隐私", "Spider 局域网扩展共享网关", "spider 网关 局域网 共享");
        add(6, "ms-push-tv", "云同步、网盘与隐私", "局域网跨设备推源", "局域网 投送 推送 互联");

        // 7. 存储、更新与关于
        add(7, "ms-backup-export", "存储、更新与关于", "手机备份导出与恢复", "备份 导出 恢复 还原 json");
        add(7, "ms-disk-cache", "存储、更新与关于", "本地分块视频缓存上限", "缓存 空间 内存 mb");
        add(7, "ms-clear-caches", "存储、更新与关于", "分项缓存统计与一键清理", "清理 图片缓存 tmdb缓存 ai缓存 垃圾");
        add(7, "ms-crash-reports", "存储、更新与关于", "异常退出与崩溃报告诊断", "闪退 崩溃 crash 报告");
        add(7, "ms-logs", "存储、更新与关于", "运行诊断日志查看", "日志 报错 调试 诊断");
        add(7, "ms-updates", "存储、更新与关于", "检查手机端软件更新 (android-mobile)", "更新 升级 版本");
    }

    private MobileSettingsIndex() {}

    private static void add(int sub, String key, String grp, String title, String kw) {
        ALL.add(new Entry(sub, key, grp, title, kw));
    }

    static List<Entry> search(String rawQuery) {
        List<Entry> hits = new ArrayList<>();
        if (rawQuery == null) return hits;
        String q = rawQuery.trim().toLowerCase(Locale.ROOT);
        if (q.isEmpty()) return hits;
        for (Entry e : ALL) {
            if (e.title.toLowerCase(Locale.ROOT).contains(q)
                    || e.groupName.toLowerCase(Locale.ROOT).contains(q)
                    || e.keywords.toLowerCase(Locale.ROOT).contains(q)) {
                hits.add(e);
            }
        }
        return hits;
    }
}
