"""Disposable-emulator recording of released UI. Never run against a user's device."""
import contextlib, functools, hashlib, http.server, json, os, re, signal, subprocess, sys, threading, time, traceback, urllib.parse, urllib.request, zipfile
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT=Path('recording').resolve(); MEDIA=ROOT/'media'; OUT=ROOT/'output'
PKG='com.pilipala.marcomovie'; BASE='http://10.0.2.2:8765'
EDITION=sys.argv[2]; EVENTS=[]; CURRENT=None; START=0
for p in [ROOT,MEDIA,OUT]: p.mkdir(parents=True,exist_ok=True)
def run(*args,check=True,timeout=45):
    p=subprocess.run([str(a) for a in args],capture_output=True,check=False,timeout=timeout)
    if check and p.returncode: raise RuntimeError(p.stderr.decode('utf-8','replace')[-1800:] or p.stdout.decode('utf-8','replace')[-1800:])
    return p.stdout.decode('utf-8','replace').strip()
def adb(*a,**kw):return run('adb',*a,**kw)
def sh(*a,**kw):return adb('shell',*a,**kw)
def get(url,path):
    if not path.exists():
        with urllib.request.urlopen(url,timeout=120) as r, path.open('wb') as f:
            while b:=r.read(1024*1024):f.write(b)
def prepare():
    url=f'https://github.com/Pilipala9919/MarcoMovie/releases/download/android-{EDITION}-v0.5.8/MarcoMovie-0.5.8-android-{EDITION}.apk'
    get(url,ROOT/'release.apk')
    with zipfile.ZipFile(ROOT/'release.apk') as src,zipfile.ZipFile(ROOT/'emulator-unsigned.apk','w',zipfile.ZIP_DEFLATED) as dst:
        for e in src.infolist():
            if not e.filename.startswith(('lib/','META-INF/')):dst.writestr(e,src.read(e.filename))
    bt=sorted((Path(os.environ['ANDROID_HOME'])/'build-tools').iterdir())[-1]
    run('keytool','-genkeypair','-keystore',ROOT/'demo.jks','-storepass','android','-keypass','android','-alias','demo','-dname','CN=Disposable recording','-keyalg','RSA','-validity','7')
    run(bt/'zipalign','-f','4',ROOT/'emulator-unsigned.apk',ROOT/'aligned.apk')
    run(bt/'apksigner','sign','--ks',ROOT/'demo.jks','--ks-pass','pass:android','--out',ROOT/'emulator.apk',ROOT/'aligned.apk')
    get('https://media.w3.org/2010/05/bunny/trailer.mp4',MEDIA/'bunny.mp4')
    get('https://media.w3.org/2010/05/sintel/trailer.mp4',MEDIA/'sintel.mp4')
    # Use MPEG-4 Part 2 to exercise Android's software decoder in headless capture.
    # The emulator's goldfish AVC hardware bridge fails without a host display.
    for movie in ['bunny','sintel']:
        run('ffmpeg','-v','error','-stream_loop','3','-i',MEDIA/(movie+'.mp4'),'-t','120','-vf','scale=854:480','-c:v','mpeg4','-q:v','3','-c:a','aac','-ac','2','-ar','44100','-movflags','+faststart','-y',MEDIA/(movie+'-sw.mp4'),timeout=120)
        (MEDIA/(movie+'-sw.mp4')).replace(MEDIA/(movie+'.mp4'))
    cards=[]
    for i,(movie,sec,title) in enumerate([('bunny',35,'大雄兔 · 林间清晨'),('sintel',95,'辛特尔 · 旅途'),('bunny',120,'大雄兔 · 森林伙伴'),('sintel',180,'辛特尔 · 相遇'),('bunny',210,'大雄兔 · 午后'),('sintel',250,'辛特尔 · 守护'),('bunny',300,'大雄兔 · 冒险'),('sintel',380,'辛特尔 · 远行'),('bunny',390,'大雄兔 · 回归')]):
        run('ffmpeg','-v','error','-ss',str(5+sec%35),'-i',MEDIA/(movie+'.mp4'),'-frames:v','1','-vf','scale=720:-1', '-y', MEDIA/f'poster{i}.jpg')
        cards.append(dict(vod_id=str(i+1),vod_name=title,vod_pic=f'{BASE}/poster{i}.jpg',vod_remarks='开放电影 · 演示章节',vod_year='2008' if movie=='bunny' else '2010',vod_area='Blender',vod_class='动画 / 短片',vod_actor='Blender Foundation',vod_director='Blender Foundation',vod_content='本演示使用 Blender Foundation 开放电影片段，CC BY 3.0。为便于讲解浏览、收藏与选集，将电影按演示章节组织；应用本身不内置片库。',vod_play_from='原片演示$$$备用线路',vod_play_url='#'.join(f'演示章节 {n:02d}${BASE}/{movie}.mp4' for n in range(1,13))+'$$$'+f'原片播放${BASE}/{movie}.mp4'))
    (MEDIA/'cards.json').write_text(json.dumps(cards,ensure_ascii=False))
    config={'sites':[{'key':'openfilms','name':'开放电影演示','type':1,'api':BASE+'/api','searchable':1},{'key':'collection','name':'动画短片精选','type':1,'api':BASE+'/api2','searchable':1}],'lives':[{'name':'演示频道','url':BASE+'/live.m3u'}]}
    (MEDIA/'config.json').write_text(json.dumps(config,ensure_ascii=False))
    (MEDIA/'live.m3u').write_text('#EXTM3U\n#EXTINF:-1 group-title="开放动画",大雄兔演示台\n'+BASE+'/bunny.mp4\n#EXTINF:-1 group-title="开放动画",辛特尔演示台\n'+BASE+'/sintel.mp4\n')
    (OUT/'provenance.json').write_text(json.dumps({'app_release':url,'sha256':hashlib.sha256((ROOT/'release.apk').read_bytes()).hexdigest(),'environment':'Android 11 emulator; release UI, ARM libraries removed and APK resigned solely for capture; system playback engine. Not a physical-device or native-decoder test.','media':['Big Buck Bunny (c) 2008 Blender Foundation / www.bigbuckbunny.org, CC BY 3.0','Sintel (c) Blender Foundation / www.sintel.org, CC BY 3.0'],'demo_catalog':'Synthetic chapter organisation using openly licensed films; not bundled content or real live broadcasts.'},ensure_ascii=False,indent=2))

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        u=urllib.parse.urlsplit(self.path)
        if u.path in ['/api','/api2']:
            q=urllib.parse.parse_qs(u.query); cards=json.loads((MEDIA/'cards.json').read_text())
            if 'ids' in q:cards=[c for c in cards if c['vod_id'] in q['ids'][0].split(',')]
            elif 'wd' in q:
                word=q['wd'][0].lower();cards=[c for c in cards if word in c['vod_name'].lower() or word in ['bunny','sintel','dh','xt','dx']]
            elif q.get('t',[''])[0]=='2':cards=[c for c in cards if '辛特尔' in c['vod_name']]
            elif q.get('t',[''])[0]=='1':cards=[c for c in cards if '大雄兔' in c['vod_name']]
            data=json.dumps({'class':[{'type_id':'1','type_name':'大雄兔'},{'type_id':'2','type_name':'辛特尔'}],'page':1,'pagecount':1,'limit':24,'total':len(cards),'list':cards},ensure_ascii=False).encode()
            self.send_response(200);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        elif u.path.endswith('.mp4'):
            path=MEDIA/Path(u.path).name
            total=path.stat().st_size; start=0; end=total-1
            rg=self.headers.get('Range','')
            m=re.match(r'bytes=(\d+)-(\d*)',rg)
            if m:
                start=int(m[1]); end=min(int(m[2]) if m[2] else end,end)
            self.send_response(206 if m else 200)
            self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length',str(end-start+1))
            if m:self.send_header('Content-Range',f'bytes {start}-{end}/{total}')
            self.end_headers()
            try:
                with path.open('rb') as f:
                    f.seek(start);remain=end-start+1
                    while remain:
                        b=f.read(min(65536,remain))
                        if not b:break
                        self.wfile.write(b);remain-=len(b)
            except (BrokenPipeError,ConnectionResetError):pass
        else:super().do_GET()

def event(action,**kw):
    EVENTS.append(dict(clip=CURRENT,time=round(time.monotonic()-START,3),action=action,**kw))
def pause(s=2):time.sleep(s)
def key(k):event('key',key=k);sh('input','keyevent',str(k));pause(.8)
def tap(x,y):event('tap',x=x,y=y);sh('input','tap',str(x),str(y));pause(1.2)
def swipe(x1,y1,x2,y2,d=700):event('swipe',x1=x1,y1=y1,x2=x2,y2=y2,duration=d);sh('input','swipe',x1,y1,x2,y2,d);pause(1)
def snap(name):
    raw=subprocess.check_output(['adb','exec-out','screencap','-p'],timeout=20);(OUT/(name+'.png')).write_bytes(raw)
    try:
        sh('uiautomator','dump','/sdcard/ui.xml',timeout=15)
        (OUT/(name+'.xml')).write_text(adb('exec-out','cat','/sdcard/ui.xml'))
    except Exception:pass
def nodes():
    sh('uiautomator','dump','/sdcard/ui.xml',timeout=30)
    raw=adb('exec-out','cat','/sdcard/ui.xml');return list(ET.fromstring(raw).iter('node'))
def click(label,exact=False,required=True):
    ns=nodes();matches=[n for n in ns if (n.get('text')==label or n.get('content-desc')==label) if n.get('bounds')!='[0,0][0,0]']
    if not matches and not exact:matches=[n for n in ns if label in (n.get('text','')+' '+n.get('content-desc',''))]
    if not matches:
        event('missing',label=label);snap('missing-'+re.sub(r'[^a-zA-Z0-9]','_',label)+str(len(EVENTS)))
        if required:raise RuntimeError('UI label missing: '+label+'; visible: '+str([n.get('text') for n in ns if n.get('text')]))
        return False
    b=list(map(int,re.findall(r'\d+',matches[0].get('bounds'))));tap((b[0]+b[2])//2,(b[1]+b[3])//2);return True
def input_text(text):
    ns=nodes();n=next(n for n in ns if n.get('class')=='android.widget.EditText');b=list(map(int,re.findall(r'\d+',n.get('bounds'))));tap((b[0]+b[2])//2,(b[1]+b[3])//2);sh('input','text',text);event('type',text=text);pause(1)
def doubletap(x,y):
    event('doubletap',x=x,y=y);sh('sh','-c',f"'input tap {x} {y}; input tap {x} {y}'");pause(2)
def reset():
    sh('am','force-stop',PKG);sh('settings','put','system','accelerometer_rotation','0');sh('settings','put','system','user_rotation','0');sh('am','start','-n',PKG+'/.MainActivity');pause(5)
def clip(name,fn,tail=3):
    global CURRENT,START
    CURRENT=name;START=time.monotonic();snap(name+'-before')
    p=subprocess.Popen(['adb','shell','screenrecord','--bit-rate','6000000','--time-limit','170','/sdcard/'+name+'.mp4'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    pause(2)
    try:fn();pause(tail)
    except Exception as e:event('failure',error=str(e));(OUT/(name+'-error.txt')).write_text(traceback.format_exc());print(name,str(e),flush=True)
    finally:
        ids=sh('pidof','screenrecord',check=False).split()
        if ids:sh('kill','-2',*ids,check=False)
        try:p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            sh('input','keyevent','KEYCODE_VOLUME_MUTE',check=False)
            try:p.communicate(timeout=5)
            except subprocess.TimeoutExpired:p.terminate();p.communicate(timeout=5)
        adb('pull','/sdcard/'+name+'.mp4',OUT/(name+'.mp4'),check=False);snap(name+'-after');(OUT/'events.json').write_text(json.dumps(EVENTS,ensure_ascii=False,indent=2));CURRENT=None
        print('Recorded',name,flush=True)
def import_url(url):
    if not any(n.get('class')=='android.widget.EditText' for n in nodes()):
        if not click('导入我的配置',required=False) and not click('导入',exact=True,required=False):
            click('设置',required=False);click('片源与直播',required=False);click('导入配置',required=False)
    click('遥控输入',required=False)
    input_text(url);key(4)
    if not click('导入',exact=True,required=False):
        if not click('导入地址',exact=True,required=False):
            if not click('导入输入内容',required=False):click('确定',required=False)
    pause(12)
def seed():
    # This is only a disposable emulator, containing no user data.
    sh('am','force-stop',PKG)
    adb('push',MEDIA/'config.json','/data/local/tmp/demo-config.json')
    prefs='<map><int name="player_engine" value="1"/><boolean name="startup_animation" value="false"/><string name="origin">'+BASE+'/config.json</string><string name="selected_site">openfilms</string><string name="live_url">'+BASE+'/live.m3u</string></map>'
    (ROOT/'movie.xml').write_text(prefs);adb('push',ROOT/'movie.xml','/data/local/tmp/demo-prefs.xml')
    uid=sh('stat','-c','%u','/data/data/'+PKG,check=False)
    for d in ['files','shared_prefs']:sh('mkdir','-p','/data/data/'+PKG+'/'+d,check=False)
    sh('cp','/data/local/tmp/demo-config.json','/data/data/'+PKG+'/files/config.json',check=False)
    sh('cp','/data/local/tmp/demo-prefs.xml','/data/data/'+PKG+'/shared_prefs/movie.xml',check=False)
    sh('chown','-R',uid+':'+uid,'/data/data/'+PKG+'/files','/data/data/'+PKG+'/shared_prefs',check=False)
    reset()
    if any('导入我的配置' in n.get('text','') for n in nodes()):import_url(BASE+'/config.json')
    if EDITION=='tv':
        click('设置',required=False);click('播放与字幕',required=False)
        click('播放器',exact=True,required=False);click('系统播放器',exact=True,required=False)
        reset()
def requested_source():
    clip('00-requested-source-import',lambda:import_url('http://www.xn--sss604efuw.net/tv'),tail=5)
    clip('00-requested-source-home',lambda:(pause(12),key(22) if EDITION=='tv' else swipe(520,1470,520,900)),tail=4)
    sh('pm','clear',PKG);reset()

def mobile():
    requested_source()
    clip('01-first-launch',lambda:(pause(3),click('导入',exact=True,required=False),pause(3)))
    # Import through the app's actual input, with a seeded fallback only if it fails.
    clip('02-import',lambda:(input_text(BASE+'/config.json'),key(4),click('导入',exact=True),pause(7)))
    seed()
    clip('03-home-browse',lambda:(pause(3),swipe(530,1510,530,650),swipe(530,600,530,1480),click('辛特尔',exact=True),pause(3),click('大雄兔',exact=True)))
    reset()
    clip('04-search',lambda:(tap(961,178),pause(2),input_text('bunny'),key(4),click('搜索',exact=True),pause(5)))
    reset()
    clip('05-details',lambda:(click('大雄兔 · 林间清晨'),pause(5),click('♡',exact=True,required=False),swipe(520,1450,520,780),click('正序',required=False),pause(3),click('倒序',required=False)))
    clip('06-lines-episodes',lambda:(click('⇄',required=False),pause(3),click('备用线路',required=False),pause(3),click('⇄',required=False),click('原片演示',required=False),swipe(530,1450,530,800),pause(3)))
    click('播放 ·',required=False)
    pause(8)
    clip('07-playback',lambda:(tap(940,540),pause(3),doubletap(960,540),pause(3),doubletap(960,540),swipe(630,540,1300,540),pause(4)))
    clip('08-player-tools',lambda:(tap(960,540),click('1.0×',required=False),pause(3),key(4),tap(960,540),click('画面',required=False),pause(3),key(4),tap(960,540),click('更多',required=False),pause(4)))
    reset()
    clip('09-library',lambda:(click('片库',exact=True),pause(4),swipe(540,1510,540,750),pause(4)))
    reset()
    clip('10-live-catalog',lambda:(click('直播',exact=True),pause(5)))
    clip('11-live-playback',lambda:(click('大雄兔演示台'),pause(8),tap(960,540),pause(4)))
    reset()
    clip('12-settings',lambda:(click('设置',exact=True),pause(4),swipe(540,1500,540,700),swipe(540,700,540,1500)))
    for num,label in [(13,'片源与直播'),(14,'播放'),(15,'界面'),(16,'备份')]:
        reset();click('设置',exact=True)
        clip(f'{num:02d}-settings-detail',lambda label=label:(click(label),pause(4),swipe(540,1480,540,700),pause(4)))
def tv():
    requested_source()
    clip('01-first-launch',lambda:pause(4));seed()
    clip('02-home-navigation',lambda:(pause(4),key(20),key(22),key(22),key(21),key(20),key(20),key(19),key(19)))
    clip('03-source-selection',lambda:(key(82),pause(5),key(20),key(19),key(4)))
    reset()
    clip('04-details',lambda:(click('大雄兔 · 林间清晨'),pause(4),key(22),key(20),key(20),pause(3),click('收藏',required=False)))
    clip('05-episodes',lambda:(click('倒序',required=False),pause(3),click('正序',required=False),click('⇄',required=False),pause(3),click('备用线路',required=False),pause(3),click('⇄',required=False),click('原片演示',required=False)))
    click('播放',required=False);pause(8)
    clip('06-playback',lambda:(key(23),pause(3),key(23),pause(3),key(20),pause(3),key(22),key(22),key(21)))
    clip('07-player-tools',lambda:(key(20),click('1.0×',required=False),pause(4),key(4),key(20),click('更多',required=False),pause(4),key(4)))
    reset()
    for num,label in [(8,'搜索'),(9,'收藏'),(10,'直播'),(11,'设置')]:
        reset()
        clip(f'{num:02d}-{label}',lambda label=label:(click(label),pause(5),key(20),key(20),key(19)))
    for num,label in [(12,'首页与壁纸'),(13,'播放与字幕'),(14,'搜索与数据')]:
        reset();click('设置',required=False)
        clip(f'{num:02d}-settings-detail',lambda label=label:(click(label),pause(5),key(20),key(20),key(20)))

def supplement():
    seed()
    click('大雄兔 · 林间清晨');pause(3)
    if EDITION=='mobile':click('播放 ·',required=False)
    else:
        if not click('演示章节 01',required=False):click('播放',required=False)
    pause(8)
    if EDITION=='mobile':
        clip('21-playing',lambda:(pause(6),tap(900,540),pause(4)),tail=2)
        clip('22-pause-resume',lambda:(doubletap(900,540),pause(3),doubletap(900,540),pause(4)),tail=2)
        clip('23-seek-gestures',lambda:(swipe(600,540,1100,540),pause(3),swipe(240,700,240,430),pause(3),swipe(1450,700,1450,430)),tail=2)
        clip('24-speed',lambda:(tap(900,540),click('1.0×',required=False),pause(3),click('1.25',required=False),pause(3)),tail=2)
        clip('25-picture',lambda:(tap(900,540),click('画面',required=False),pause(4)),tail=2)
        key(4)
        clip('26-episode-panel',lambda:(tap(900,540),click('选集',required=False),pause(5)),tail=2)
        key(4)
        clip('27-subtitles',lambda:(tap(900,540),click('字幕',required=False),pause(4)),tail=2)
        reset();click('直播',exact=True);pause(3);click('大雄兔演示台',required=False);pause(8)
        clip('28-live-playing',lambda:(pause(6),tap(900,540),pause(4)),tail=2)
    else:
        clip('21-playing',lambda:pause(10),tail=2)
        clip('22-pause-resume',lambda:(key(23),pause(3),key(23),pause(5)),tail=2)
        clip('23-seek',lambda:(key(22),key(22),key(21),pause(5)),tail=2)
        clip('24-player-toolbar',lambda:(key(20),pause(4),key(22),key(22),key(21)),tail=2)
        clip('25-speed',lambda:(key(20),click('倍速',required=False),click('1.0',required=False),pause(4)),tail=2)
        key(4)
        clip('26-picture',lambda:(key(20),click('画面',required=False),pause(4)),tail=2)
        key(4)
        clip('27-episodes',lambda:(key(20),click('选集',required=False),pause(4)),tail=2)
        reset();click('直播',required=False);pause(3);click('大雄兔演示台',required=False);pause(8)
        clip('28-live-playing',lambda:(pause(6),key(23),pause(3)),tail=2)


def record():
    if sh('getprop','ro.kernel.qemu')!='1':raise RuntimeError('Disposable emulator required')
    adb('root');adb('wait-for-device');pause(2)
    server=http.server.ThreadingHTTPServer(('0.0.0.0',8765),functools.partial(Handler,directory=str(MEDIA)));threading.Thread(target=server.serve_forever,daemon=True).start()
    sh('wm','size','1080x1920' if EDITION=='mobile' else '1920x1080');sh('wm','density','420' if EDITION=='mobile' else '240')
    sh('settings','put','system','screen_off_timeout','2147483647');sh('settings','put','secure','immersive_mode_confirmations','confirmed')
    sh('settings','put','system','show_touches','1' if EDITION=='mobile' else '0');sh('settings','put','system','accelerometer_rotation','0');sh('settings','put','system','user_rotation','0')
    original=adb('install','-r',ROOT/'release.apk',check=False,timeout=90)
    print('Original APK install:',original,flush=True)
    if 'Success' not in original:adb('install','-r',ROOT/'emulator.apk')
    sh('pm','clear',PKG);reset()
    try:supplement()
    finally:
        (OUT/'logcat.txt').write_text(adb('logcat','-d',check=False));(OUT/'events.json').write_text(json.dumps(EVENTS,ensure_ascii=False,indent=2));server.shutdown()
if __name__=='__main__':(prepare if sys.argv[1]=='prepare' else record)()
