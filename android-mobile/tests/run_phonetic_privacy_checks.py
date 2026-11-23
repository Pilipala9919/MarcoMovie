"""Real title matching/paging plus actual initialization/learning method slices; no device/data."""
from pathlib import Path
import os, subprocess, tempfile
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie'
def method(file,signature):
    source=(SRC/file).read_text('utf8');start=source.index('    '+signature)
    end=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]
host='''package com.pilipala.marcomovie;
import java.io.*;import java.nio.file.*;import java.util.*;import java.util.concurrent.*;
class PhoneticHost {
 static PhoneticSearchIndex sharedPhoneticDictionary;
 static Path assets;
 static class Queue {ArrayList<Runnable> tasks=new ArrayList<>();void execute(Runnable r){tasks.add(r);}
  void post(Runnable r){tasks.add(r);}void postDelayed(Runnable r,long d){tasks.add(r);}
  void removeCallbacks(Runnable r){tasks.removeIf(x->x==r);}void drain(){while(!tasks.isEmpty())tasks.remove(0).run();}}
 static class MemoryPrefs {final Map<String,String> values=new HashMap<>();int writes;
  String getString(String k,String fallback){return values.getOrDefault(k,fallback);}
  Editor edit(){return new Editor();}class Editor {String k,v;Editor putString(String k,String v){this.k=k;this.v=v;return this;}
  void apply(){values.put(k,v);writes++;}}}
 final Queue ui=new Queue(),worker=new Queue(),phoneticWork=new Queue();
 final LinkedHashSet<String> pendingTitles=new LinkedHashSet<>();
 final Runnable learnPendingTitles=()->LearnSlice.learnPendingTitles(this);
 MemoryPrefs prefs=new MemoryPrefs();Object config=new Object();int engineEpoch;boolean privateMode,switchingPrivacy,destroyed,finishing;
 volatile PhoneticSearchIndex phonetic;final CountDownLatch phoneticReady=new CountDownLatch(1);
 boolean isDestroyed(){return destroyed;}boolean isFinishing(){return finishing;}
 static class Assets {InputStream open(String name)throws Exception{return Files.newInputStream(assets.resolve(name));}}
 Assets getAssets(){return new Assets();}
 void initialize(){initializePhonetic();worker.drain();ui.drain();}
'''+method('MainActivity.java','void initializePhonetic(').replace('MainActivity.class','PhoneticHost.class').replace('SharedPreferences','MemoryPrefs')+'\n}'
learn='''package com.pilipala.marcomovie;import java.util.*;
class LearnSlice {
'''+('\n'.join(method('SourceController.java',s) for s in ['static void learnTitles(','static void learnPendingTitles('])).replace('MainActivity','PhoneticHost').replace('android.content.SharedPreferences','PhoneticHost.MemoryPrefs')+'\n}'
match='''package com.pilipala.marcomovie;class MatchSlice {final PhoneticHost a;MatchSlice(PhoneticHost a){this.a=a;}
'''+method('GlobalSearchScreen.java','boolean matchesTitle(')+'\n}'
with tempfile.TemporaryDirectory(prefix='phonetic-privacy-') as tmp:
    work=Path(tmp);files=[]
    for name,text in [('PhoneticHost.java',host),('LearnSlice.java',learn),('MatchSlice.java',match)]:
        p=work/name;p.write_text(text,'utf8');files.append(p)
    cp=compile_real_android_sources(work/'classes',work,[*files,ROOT/'android-mobile/tests/PhoneticPrivacyChecks.java'])
    subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-Dfile.encoding=UTF-8','-cp',os.pathsep.join(map(str,cp)),
        'com.pilipala.marcomovie.PhoneticPrivacyChecks',str(ROOT)],check=True,cwd=ROOT)
