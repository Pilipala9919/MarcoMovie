from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import json,subprocess,os,threading,time
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
CLOSED_LIVE_STREAMS=[]
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def _json(self, payload):
        raw=json.dumps(payload).encode('utf-8')
        self.send_response(200);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
    def do_GET(self):
        if self.path=='/cross':self.send_response(302);self.send_header('Location',f'http://localhost:{self.server.server_port}/headers');self.end_headers()
        elif self.path=='/headers' and (self.headers.get('Authorization') or self.headers.get('Cookie')):self.send_response(403);self.end_headers()
        elif self.path=='/slow':time.sleep(6);self.send_response(503);self.end_headers()
        elif self.path=='/redirect':self.send_response(302);self.send_header('Location','lists/index.m3u');self.end_headers()
        elif self.path=='/failure':self.send_response(503);self.end_headers()
        elif self.path=='/loop':self.send_response(302);self.send_header('Location','loop');self.end_headers()
        elif self.path.split('?',1)[0]=='/list.php':self.send_response(200);self.send_header('Content-Type','text/plain');self.end_headers();self.wfile.write(('\ufeff#EXTM3U\n#EXTINF:-1,中文频道\nmedia/video.m3u8\n').encode('utf-16le'))
        elif self.path.startswith('/emby/LiveTv/Channels'):
            self._json({'TotalRecordCount':2,'Items':[
                {'Id':'ch1','Name':'CCTV-1 综合','Number':'1','ImageTags':{'Primary':'tag1'},'CurrentProgram':{'Name':'新闻联播'}},
                {'Id':'ch2','Name':'CCTV-4K 超高清','Number':'4','CurrentProgram':{'Name':'纪录片','EpisodeTitle':'第一集'}}
            ]})
        elif self.path=='/emby/closed-live-streams':
            self._json({'closed':CLOSED_LIVE_STREAMS})
        else:self.send_response(200);self.send_header('Content-Type','audio/x-mpegurl; charset=utf-8');self.end_headers();self.wfile.write(b'#EXTM3U\n#EXTINF:-1,Local test\n../media/test.m3u8\n')
    def do_POST(self):
        length=int(self.headers.get('Content-Length','0') or '0')
        body=json.loads(self.rfile.read(length).decode('utf-8')) if length>0 else {}
        if self.path.startswith('/emby/Items/ch1/PlaybackInfo'):
            self._json({'PlaySessionId':'ps-101','MediaSources':[{'Id':'ms-1','LiveStreamId':'ls-101','SupportsDirectStream':True,'DirectStreamUrl':'/emby/LiveTv/LiveStreamFiles/ls-101/stream.ts?api_key=leak'}]})
        elif self.path.startswith('/emby/Items/ch2/PlaybackInfo'):
            self._json({'PlaySessionId':'ps-202','MediaSources':[{'Id':'ms-2','RequiresOpening':True,'OpenToken':'tok-202','SupportsDirectStream':False,'SupportsTranscoding':True}]})
        elif self.path.startswith('/emby/LiveTv/LiveStreams/Open'):
            self._json({'MediaSource':{'Id':'ms-2','LiveStreamId':'ls-202','SupportsDirectStream':False,'SupportsTranscoding':True,'TranscodingUrl':'/emby/Videos/ch2/live.m3u8?api_key=leak'}})
        elif self.path.startswith('/emby/LiveTv/LiveStreams/Close'):
            if body.get('LiveStreamId'):CLOSED_LIVE_STREAMS.append(body['LiveStreamId'])
            self._json({})
        else:
            self._json({})
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
out=ROOT/'android-tv/tests/live-classes';out.mkdir(exist_ok=True)
jar=ROOT/'android-tv/tests/lib/json-20240303.jar'
try:
    subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',str(jar),'-d',str(out),str(ROOT/'shared/java/com/pilipala/source/Json.java'),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),str(ROOT/'shared/java/com/pilipala/emby/EmbyLibrary.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/Cms.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/RequestScope.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/LiveQualityPolicy.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/LiveCatalog.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/LiveEpgService.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/ProxyAddress.java'),str(ROOT/'android-tv/tests/LiveCatalogChecks.java')],check=True)
    result=subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-Dfile.encoding=UTF-8','-cp',str(out)+os.pathsep+str(jar),'LiveCatalogChecks',str(ROOT),f'http://127.0.0.1:{server.server_port}/'],check=True,text=True,encoding='utf-8',capture_output=True)
    print(result.stdout);(ROOT/'android-tv/tests/live-results.txt').write_text(result.stdout,encoding='utf-8')
    subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-cp',str(out)+os.pathsep+str(jar),'-d',str(out),str(ROOT/'android-tv/tests/LiveNetworkChecks.java'),str(ROOT/'android-tv/tests/PrivacyPinChecks.java'),str(ROOT/'android-tv/src/main/java/com/pilipala/marcomovie/PrivacyPin.java')],check=True)
    for name,extra in [('LiveNetworkChecks',[f'http://127.0.0.1:{server.server_port}/']),('PrivacyPinChecks',[])]:
        subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-Dfile.encoding=UTF-8','-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.'+name,*extra],check=True)
finally:server.shutdown()
