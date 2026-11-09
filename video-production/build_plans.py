from pathlib import Path
import json,subprocess
ROOT=Path(__file__).parent
def footage(ed,stem):
    p=ROOT/'raw'/ed
    matches=list(p.glob(stem+'*.mp4'))
    if not matches:raise FileNotFoundError(stem)
    return matches[0].relative_to(ROOT).as_posix()
def main(ed):
    scenes=[]
    def card(title,duration,body):scenes.append(dict(title=title,duration=duration,body=body,label='Marco Movie 0.5.8 · 60fps 成片'))
    def shot(stem,title,duration,tips,start=0,zoom=1.,focus=(.5,.5),label='Android 模拟器实录 · 功能演示片库'):
        scenes.append(dict(source=footage(ed,stem),title=title,duration=duration,tips=tips,start=start,zoom=zoom,focus=focus,label=label))
    card('从导入到日常观影',10,['配置导入与首页浏览','搜索、收藏、线路与选集','播放控制、直播与常用设置'])
    shot('00-requested-source-import','导入你的配置地址',19,['填写配置地址，然后确认导入','本次导入使用你提供的地址'],start=2,zoom=1.1,focus=(.5,.35),label='指定配置地址 · 实际导入过程')
    shot('00-requested-source-home','导入完成，认识首页',15,['顶部显示当前选中的片源','选择分类，浏览片库内容'],start=0,zoom=1.06,focus=(.5,.28),label='指定配置地址 · 实际片库界面')
    card('接下来，逐项看操作',8,['以下功能使用开放电影演示片库','演示章节便于讲解线路和选集','应用本身不内置这些影片'])
    if ed=='mobile':
        shot('03-home-browse','首页浏览与分类',20,['上下滑动浏览海报','点按分类，切换当前列表'],zoom=1.06,focus=(.5,.5))
        shot('04-search','搜索你想看的作品',25,['打开搜索，输入关键词','从结果列表选择作品'],zoom=1.1,focus=(.5,.2))
        shot('05-details','详情与收藏',24,['阅读简介，查看作品信息','点按右上角爱心，收藏作品'],zoom=1.13,focus=(.8,.15))
        shot('06-lines-episodes','切换播放线路',25,['点按右上方线路按钮','选择线路后查看对应剧集'],zoom=1.13,focus=(.75,.14))
        shot('05-details','按顺序找到要看的集数',12,['正序、倒序调整排列','从集数条或剧集卡片进入'],start=16,zoom=1.12,focus=(.5,.8))
        shot('21-playing','进入播放界面',16,['单击画面，显示播放工具','进度与当前播放信息位于底部'],zoom=1.)
        shot('22-pause-resume','暂停与继续播放',15,['双击画面，暂停或继续','观看时可收起工具栏'],zoom=1.06)
        shot('23-seek-gestures','用手势控制观看',20,['左右滑动调整进度','左侧调亮度，右侧调音量'],zoom=1.)
        shot('24-speed','调整播放速度',16,['打开当前倍速按钮','选择速度后继续观看'],zoom=1.13,focus=(.9,.5))
        shot('25-picture','选择合适的画面比例',13,['点按“画面”查看显示选项','按影片比例与观看习惯选择'],zoom=1.1,focus=(.8,.5))
        shot('26-episode-panel','播放中打开选集',14,['点按“选集”查看剧集列表','不必回到首页重新查找'],zoom=1.1,focus=(.82,.5))
        shot('27-subtitles','播放中的字幕入口',13,['点按“字幕”打开相关选项','可用项目取决于影片与字幕资源'],zoom=1.08,focus=(.8,.5))
        shot('09-library','在片库找回收藏与历史',15,['观看历史用于找回进度','收藏和下载在这里集中管理'],zoom=1.08,focus=(.5,.25))
        shot('10-live-catalog','浏览直播频道列表',13,['选择频道分组或搜索频道','也可在这里导入直播列表'],zoom=1.1,focus=(.5,.25))
        shot('28-live-playing','打开频道观看',14,['点按频道进入播放','本片使用开放电影作为演示频道'],zoom=1.)
        shot('12-settings','设置按用途分类',13,['片源、播放和外观分区管理','备份、更新与诊断也有独立入口'],zoom=1.08,focus=(.5,.42))
        shot('13-settings-detail','片源与直播配置',16,['修改配置、导入本地文件','管理直播源及默认片源'],zoom=1.1,focus=(.5,.4))
        shot('14-settings-detail','播放、解码与字幕',18,['查看解码和自动连播选项','设置片头片尾及字幕样式'],zoom=1.1,focus=(.5,.6))
        shot('15-settings-detail','界面外观与偏好',16,['调整界面及导航栏大小','透明效果和动画可单独设置'],zoom=1.1,focus=(.5,.4))
        shot('16-settings-detail','备份、更新与诊断',16,['在这里检查版本更新','查看诊断及备份恢复入口'],zoom=1.08,focus=(.5,.4))
    else:
        shot('02-home-navigation','用遥控器浏览首页',24,['方向键移动焦点','确认键进入选中项','返回键逐级返回'],zoom=1.04,focus=(.55,.55))
        shot('03-source-selection','切换当前片源',18,['打开片源选择','选择要使用的片源','载入后浏览对应内容'],zoom=1.08,focus=(.75,.4))
        shot('04-details','详情页与收藏',24,['查看海报与简介','收藏当前作品','向下浏览剧集'],zoom=1.07,focus=(.5,.5))
        shot('05-episodes','线路与剧集排序',24,['切换播放线路','查看正序与倒序','选择对应集数'],zoom=1.1,focus=(.6,.65))
        shot('21-playing','进入播放界面',16,['播放画面保持全景','稍后调出控制条','下方显示进度信息'])
        shot('22-pause-resume','遥控暂停与继续',17,['确认键暂停或继续','观察播放状态变化','再按确认键继续'])
        shot('23-seek','用遥控器调整进度',14,['左右键调整进度','观察时间提示','确认目标后继续播放'],zoom=1.06,focus=(.55,.8))
        shot('24-player-toolbar','找到播放工具条',17,['下方向键调出工具','左右移动焦点','确认进入选中功能'],zoom=1.1,focus=(.65,.8))
        shot('25-speed','播放速度入口',14,['打开倍速选项','根据观看习惯选择','返回关闭面板'],zoom=1.1,focus=(.65,.6))
        shot('26-picture','画面显示选项',14,['打开画面设置','查看比例与显示方式','按片源画幅选择'],zoom=1.1,focus=(.65,.6))
        shot('27-episodes','播放中查看选集',14,['打开选集面板','浏览可用剧集','返回关闭面板'],zoom=1.08,focus=(.65,.6))
        shot('08-','认识遥控搜索面板',18,['从侧边导航进入搜索','支持拼音、字母和数字','输入后确认搜索'],zoom=1.08,focus=(.5,.45))
        shot('09-','查看收藏入口',14,['从导航进入收藏','在详情页将作品加入收藏','收藏后可在此集中浏览'],zoom=1.05,focus=(.5,.45))
        shot('10-','直播频道与分组',16,['进入直播页面','按分组浏览频道','选择频道开始播放'],zoom=1.05,focus=(.45,.5))
        shot('28-live-playing','直播播放演示',14,['调出频道与播放操作','按返回键退出面板','画面使用开放电影演示'])
        shot('11-','设置总览',15,['按用途选择设置分类','确认进入对应页面','返回键回到上一级'],zoom=1.08,focus=(.45,.45))
        shot('12-settings-detail','首页、壁纸与界面',18,['查看首页布局选项','调整壁纸与界面效果','根据观看距离设置'],zoom=1.08,focus=(.45,.5))
        shot('13-settings-detail','播放与字幕设置',18,['查看播放器和解码选项','调整字幕与跳过设置','按设备情况选择'],zoom=1.08,focus=(.45,.5))
        shot('14-settings-detail','搜索与配置管理',17,['查看搜索并发和等待时间','管理配置源与直播源','根据网络情况调整'],zoom=1.08,focus=(.45,.5))
    card('开始你的日常观影',10,['导入配置 → 浏览搜索 → 选集播放','收藏与历史，方便下次继续','配置与内容可用性取决于所选来源'])
    card('演示与音乐说明',9,['真实 Android 模拟器界面录制','开放电影：Blender Foundation · CC BY 3.0','BGM：舒缓钢琴 · 无人声'])
    # A missing control is not evidence of a successful demonstration.
    event_path=ROOT/'raw'/ed/'events.json'
    if event_path.exists():
        ev=json.loads(event_path.read_text());bad=set()
        for e in ev:
            c=e.get('clip') or ''
            if e.get('action')=='failure' or (e.get('action')=='missing' and c.startswith(('24-','25-','26-','27-'))):bad.add(c)
        excluded=[s for s in scenes if s.get('source') and Path(s['source']).stem in bad]
        scenes=[s for s in scenes if s not in excluded]
        (ROOT/f'excluded-{ed}.json').write_text(json.dumps([s['title'] for s in excluded],ensure_ascii=False))
    plan=dict(title='Marco Movie 安卓'+('手机端' if ed=='mobile' else '电视端')+'详细使用展示',scenes=scenes)
    (ROOT/f'plan-{ed}.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2))
    print(ed,len(scenes),sum(s['duration'] for s in scenes))
if __name__=='__main__':
    import sys
    main(sys.argv[1])
