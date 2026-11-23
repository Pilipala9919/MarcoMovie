"""Compile real application + exact host method slices with observable UI/player doubles. No device."""
from pathlib import Path
import os, subprocess, tempfile
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'android-tv/src/main/java/com/pilipala/marcomovie'

def method(file, signature):
    source = (SRC / file).read_text('utf8')
    start = source.index('    ' + signature)
    begin = source.index('{', start); depth = 1; end = begin + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

IME = '''package com.pilipala.marcomovie;
class ImeHostSlice {
 final PinyinKeyboardModel keyboard; final TvSearchImeState imeDraft=new TvSearchImeState();
 boolean imeActive=true,syncingInput; int imeConnectionDepth,candidatePage,searches;
 Runnable pendingImeRead; String value; int from=-1,to=-1,cursor;
 final Host a=new Host(); final Widget composition=new Widget(),resultBody=new Widget();
 static class View {static final int VISIBLE=0;}
 static class Widget {void setText(String x){} void setVisibility(int x){}}
 static class Host {final Host ui=this;void removeCallbacks(Runnable x){}}
 ImeHostSlice(PinyinKeyboardModel k){keyboard=k;value=k.query();cursor=value.length();imeDraft.open(k);}
 boolean current(){return true;}
 void readImeDraft(){imeDraft.update(value,from,to,cursor,keyboard);}
 void suspendForIme(){}
 void renderCandidates(){}
 void updateTitleSuggestions(){}
 void scheduleSearch(){searches++;}
 void changed(boolean reset){updateAfterImeInput(reset);}
 void changed(){updateAfterImeInput(true);}
 void updateAfterImeInput(){updateAfterImeInput(true);}
'''
TAIL = '''package com.pilipala.marcomovie;
class TailHostSlice {
 final Host a=new Host(); final Cms.Site site=new Cms.Site(); final Timeline timeline=new Timeline();
 final TvMarkerTailGate markerTail=new TvMarkerTailGate(); boolean transitioning; int pendingResumeMs;
 long tail; int intro,displayOverride=-1;
 static class Player {int position,duration=10000,seeks,target,pauses;
  int getDuration(){return duration;} int getCurrentPosition(){return position;}
  void seekTo(int x){seeks++;target=x;} void pause(){pauses++;}}
 static class PrefsDouble {int repeat=1;int getInt(String key,int fallback){return repeat;}}
 static class Timeline {int max;void setEnabled(boolean b){}void setMax(int x){max=x;}int getMax(){return max;}void setProgress(int x){}}
 static class Gesture {boolean active;}
 static class Status {void setText(String s){}}
 static class Host {boolean tv=true,playing=true,prepared=true;Object markerHost;final Gesture seekGesture=new Gesture();
  final Player player=new Player();WatchHistory.Entry playingBookmark;final PrefsDouble prefs=new PrefsDouble();final Status playStatus=new Status();
  boolean isTvDevice(){return tv;}void showControls(boolean b){} }
 boolean isUserSeeking(){return false;}void recordUserSeek(int x){}boolean step(int x){return false;}
 int displayPosition(int x){return displayOverride>=0?displayOverride:x;}
 int introPosition(int duration){return intro;}long outroPosition(int duration){return tail;}
'''

with tempfile.TemporaryDirectory(prefix='tv-v17-r3-') as tmp:
    work=Path(tmp)
    ime=work/'ImeHostSlice.java'; tail=work/'TailHostSlice.java'
    ime.write_text(IME+'\n'.join(method('GlobalSearchScreen.java', sig) for sig in [
        'void captureImeUpdate()', 'void finishSystemIme(boolean commit)',
        'void updateAfterImeInput(boolean resetCandidates)'])+'\n}',encoding='utf8')
    tail.write_text(TAIL+method('PlaybackControls.java','void tick()')+'\n}',encoding='utf8')
    cp=compile_real_android_sources(classes_dir=work/'classes',work_dir=work,
        test_sources=[ime,tail,ROOT/'android-tv/tests/TvV17ReviewFixChecks.java'])
    subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-Dfile.encoding=UTF-8','-cp',
        os.pathsep.join(map(str,cp)),'com.pilipala.marcomovie.TvV17ReviewFixChecks'],cwd=ROOT,check=True)
