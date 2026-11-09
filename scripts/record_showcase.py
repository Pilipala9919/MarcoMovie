"""Disposable-emulator recording of released UI. Never run against a user's device."""
import contextlib, functools, hashlib, http.server, json, os, re, signal, subprocess, sys, threading, time, traceback, urllib.parse, urllib.request, zipfile
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT=Path('recording').resolve(); MEDIA=ROOT/'media'; OUT=ROOT/'output'
PKG='com.pilipala.marcomovie'; BASE='http://10.0.2.2:8765'
EDITION=sys.argv[2]; EVENTS=[]; CURRENT=None; START=0
for p in [ROOT,MEDIA,OUT]: p.mkdir(parents=True,exist_ok=True)
def run(*args,check=True,timeout=180):
    p=subprocess.run([str(a) for a in args],capture_output=True,check=check,timeout=timeout)
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
    get('https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',MEDIA/'bunny.mp4')
    get('https://storage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',MEDIA/'sintel.mp4')
    cards=[]
    for i,(movie,sec,title) in enumerate([('bunny',35,'大雄兔 · 林间清晨'),('sintel',95,'辛特尔 · 旅途'),('bunny',120,'大雄兔 · 森林伙伴'),('sintel',180,'辛特尔 · 相遇'),('bunny',210,'大雄兔 · 午后'),('sintel',250,'辛特尔 · 守护'),('bunny',300,'大雄兔 · 冒险'),('sintel',380,'辛特尔 · 远行'),('bunny',390,'大雄兔 · 回归')]):
        run('ffmpeg','-v','error','-ss',str(sec),'-i',MEDIA/(movie+'.mp4'),'-frames:v','1','-vf','scale=720:-1', '-y', MEDIA/f'poster{i}.jpg')
        cards.append(dict(vod_id=str(i+1),vod_name=title,vod_pic=f'{BASE}/poster{i}.jpg',vod_remarks='开放电影 · 演示章节',vod_year='2008' if movie=='bunny' else '2010',vod_area='Blender',vod_class='动画 / 短片',vod_actor='Blender Foundation',vod_director='Blender Foundation',vod_content='本演示使用 Blender Foundation 开放电影片段，CC BY 3.0。为便于讲解浏览、收藏与选集，将电影按演示章节组织；应用本身不内置片库。',vod_play_from='原片演示$$$备用线路',vod_play_url='#'.join(f'演示章节 {n:02d}${BASE}/{movie}.mp4' for n in range(1,13))+'$$$'+f'原片播放${BASE}/{movie}.mp4'))
    (MEDIA/'cards.json').write_text(json.dumps(cards,ensure_ascii=False))
    config={'sites':[{'key':'openfilms','name':'开放电影演示','type':1,'api':BASE+'/api','searchable':1},{'key':'collection','name':'动画短片精选','type':1,'api':BASE+'/api2','searchable':1}],'lives':[{'name':'演示频道','url':BASE+'/live.m3u'}]}
    (MEDIA/'config.json').write_text(json.dumps(config,ensure_ascii=False))
    (MEDIA/'live.m3u').write_text('#EXTM3U\n#EXTINF:-1 group-title="开放动画",大雄兔演示台\n'+BASE+'/bunny.mp4\n#EXTINF:-1 group-title="开放动画",辛特尔演示台\n'+BASE+'/sintel.mp4\n')
    (OUT/'provenance.json').write_text(json.dumps({'app_release':url,'sha256':hashlib.sha256((ROOT/'release.apk').read_bytes()).hexdigest(),'environment':'Android 16 x86_64 emulator; release UI, ARM libraries removed and APK resigned solely for capture; system playback engine. Not a physical-device or native-decoder test.','media':['Big Buck Bunny (c) 2008 Blender Foundation / www.bigbuckbunny.org, CC BY 3.0','Sintel (c) Blender Foundation / www.sintel.org, CC BY 3.0'],'demo_catalog':'Synthetic chapter organisation using openly licensed films; not bundled content or real live broadcasts.'},ensure_ascii=False,indent=2))

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
        else:super().do_GET()

def event(action,**kw):
    EVENTS.append(dict(clip=CURRENT,time=round(time.monotonic()-START,3),action=action,**kw))
def pause(s=2):time.sleep(s)
def key(k):event('key',key=k);sh('input','keyevent',str(k));pause(.8)
def tap(x,y):event('tap',x=x,y=y);sh('input','tap',str(x),str(y));pause(1.2)
def swipe(x1,y1,x2,y2,d=700):event('swipe',x1=x1,y1=y1,x2=x2,y2=y2,duration=d);sh('input','swipe',x1,y1,x2,y2,d);pause(1)
def snap(name):
    raw=subprocess.check_output(['adb','exec-out','screencap','-p']);(OUT/(name+'.png')).write_bytes(raw)
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
def reset():sh('am','force-stop',PKG);sh('am','start','-n',PKG+'/.MainActivity');pause(7)
def clip(name,fn,tail=3):
    global CURRENT,START
    CURRENT=name;START=time.monotonic();snap(name+'-before')
    p=subprocess.Popen(['adb','shell','screenrecord','--bit-rate','6000000','--time-limit','170','/sdcard/'+name+'.mp4'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    pause(2)
    try:fn();pause(tail)
    except Exception as e:event('failure',error=str(e));(OUT/(name+'-error.txt')).write_text(traceback.format_exc());print(name,str(e),flush=True)
    finally:
        sh('pkill','-2','screenrecord',check=False);p.communicate(timeout=20);adb('pull','/sdcard/'+name+'.mp4',OUT/(name+'.mp4'),check=False);snap(name+'-after');(OUT/'events.json').write_text(json.dumps(EVENTS,ensure_ascii=False,indent=2));CURRENT=None
        print('Recorded',name,flush=True)
def seed():
    sh('am','force-stop',PKG)
    adb('push',MEDIA/'config.json','/sdcard/demo-config.json')
    prefs='<map><int name="player_engine" value="1"/><boolean name="startup_animation" value="false"/><string name="origin">'+BASE+'/config.json</string><string name="selected_site">openfilms</string><string name="live_url">'+BASE+'/live.m3u</string></map>'
    (ROOT/'movie.xml').write_text(prefs);adb('push',ROOT/'movie.xml','/sdcard/demo-prefs.xml')
    sh('sh','-c',f"'mkdir -p /data/data/{PKG}/files /data/data/{PKG}/shared_prefs; cp /sdcard/demo-config.json /data/data/{PKG}/files/config.json; cp /sdcard/demo-prefs.xml /data/data/{PKG}/shared_prefs/movie.xml; chown -R $(stat -c %u /data/data/{PKG}) /data/data/{PKG}/files /data/data/{PKG}/shared_prefs'")
    reset()
def mobile():
    clip('01-first-launch',lambda:(pause(3),click('导入',exact=True),pause(5)))
    # Import through the app's actual input, with a seeded fallback only if it fails.
    clip('02-import',lambda:(input_text(BASE+'/config.json'),key(4),click('导入输入内容'),pause(7)))
    seed()
    clip('03-home-browse',lambda:(pause(3),swipe(530,1510,530,650),swipe(530,600,530,1480),click('辛特尔',exact=True),pause(3),click('大雄兔',exact=True)))
    reset()
    clip('04-search',lambda:(tap(964,143),pause(2),input_text('bunny'),click('搜索',exact=True),key(4),pause(5)))
    reset()
    clip('05-details',lambda:(click('大雄兔 · 林间清晨'),pause(5),click('展开',required=False),swipe(520,1450,520,780),click('倒序',required=False),pause(3),click('正序',required=False),click('收藏',required=False)))
    clip('06-lines-episodes',lambda:(click('备用线路',required=False),pause(3),click('原片演示',required=False),swipe(530,1450,530,800),pause(3)))
    click('演示章节 01',required=False);pause(8)
    clip('07-playback',lambda:(tap(940,540),pause(3),tap(960,540),tap(960,540),pause(3),tap(960,540),tap(960,540),swipe(630,540,1300,540),pause(4)))
    clip('08-player-tools',lambda:(tap(960,540),click('倍速',required=False),pause(3),key(4),tap(960,540),click('画面',required=False),pause(3),key(4),tap(960,540),click('更多',required=False),pause(4)))
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
    clip('01-first-launch',lambda:pause(5));seed()
    clip('02-home-navigation',lambda:(pause(4),key(20),key(22),key(22),key(21),key(20),key(20),key(19),key(19)))
    clip('03-source-selection',lambda:(key(82),pause(5),key(20),key(19),key(4)))
    reset()
    clip('04-details',lambda:(click('大雄兔 · 林间清晨'),pause(4),key(22),key(20),key(20),pause(3),click('收藏',required=False)))
    clip('05-episodes',lambda:(click('倒序',required=False),pause(3),click('正序',required=False),click('备用线路',required=False),pause(3),click('原片演示',required=False)))
    click('演示章节 01',required=False);pause(8)
    clip('06-playback',lambda:(key(23),pause(3),key(23),pause(3),key(20),pause(3),key(22),key(22),key(21)))
    clip('07-player-tools',lambda:(key(20),click('倍速',required=False),pause(4),key(4),key(20),click('更多',required=False),pause(4),key(4)))
    reset()
    for num,label in [(8,'搜索'),(9,'收藏'),(10,'直播'),(11,'设置')]:
        reset()
        clip(f'{num:02d}-{label}',lambda label=label:(click(label),pause(5),key(20),key(20),key(19)))
    for num,label in [(12,'首页与壁纸'),(13,'播放与字幕'),(14,'搜索与数据')]:
        reset();click('设置',required=False)
        clip(f'{num:02d}-settings-detail',lambda label=label:(click(label),pause(5),key(20),key(20),key(20)))

def record():
    if sh('getprop','ro.kernel.qemu')!='1':raise RuntimeError('Disposable emulator required')
    adb('root');adb('wait-for-device');pause(2)
    server=http.server.ThreadingHTTPServer(('0.0.0.0',8765),functools.partial(Handler,directory=str(MEDIA)));threading.Thread(target=server.serve_forever,daemon=True).start()
    sh('wm','size','1080x1920');sh('wm','density','420' if EDITION=='mobile' else '240')
    sh('settings','put','system','show_touches','1' if EDITION=='mobile' else '0');sh('settings','put','system','accelerometer_rotation','0');sh('settings','put','system','user_rotation','0')
    adb('install','-r',ROOT/'emulator.apk');sh('pm','clear',PKG);reset()
    try:(mobile if EDITION=='mobile' else tv)()
    finally:
        (OUT/'logcat.txt').write_text(adb('logcat','-d',check=False));(OUT/'events.json').write_text(json.dumps(EVENTS,ensure_ascii=False,indent=2));server.shutdown()
if __name__=='__main__':(prepare if sys.argv[1]=='prepare' else record)()
