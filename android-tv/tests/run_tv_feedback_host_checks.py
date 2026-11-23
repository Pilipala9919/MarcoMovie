"""Execute actual focus policy and async publication gate with observable host doubles."""
from pathlib import Path
import subprocess,tempfile
from android_compile_support import resolve_jdk_bin,SUFFIX
ROOT=Path(__file__).resolve().parents[2]; SRC=ROOT/'android-tv/src/main/java/com/pilipala/marcomovie'
def method(file,signature):
    s=(SRC/file).read_text('utf8');start=s.index('    '+signature);pos=s.index('{',start)+1;depth=1
    while depth:
        depth+=(s[pos]=='{')-(s[pos]=='}');pos+=1
    return s[start:pos]
prefix='''package com.pilipala.marcomovie;
class FocusSlice {
 static final int FOCUS_UP=33,FOCUS_DOWN=130;
 static class KeyEvent {int repeat;long time=1000;int getRepeatCount(){return repeat;}long getEventTime(){return time;}}
 static class Rect {int top,bottom;Rect(int x,int t,int w,int b){top=t;bottom=b;}int height(){return bottom-top;}}
 static class View {int top,height,requests;boolean clickable;View(int t,int h,boolean c){top=t;height=h;clickable=c;}
 int getWidth(){return 100;}int getHeight(){return height;}boolean isClickable(){return clickable;}
 boolean requestFocus(int d){requests++;return true;}}
 static class TextView extends View {TextView(int t,int h,boolean c){super(t,h,c);}int getLineHeight(){return 24;}}
 final Host a=new Host();static class Host{int dp(int x){return x;}}
 long lastReadingStep;Object motion;int goal,scroll;int getScrollY(){return scroll;}int getHeight(){return 600;}
 int bound(int y){return Math.max(0,Math.min(3000,y));}void moveTo(int y){goal=bound(y);}
 void reveal(View v){goal=bound(v.top+v.height-600+14);}
 void offsetDescendantRectToMyCoords(View v,Rect r){r.top=v.top;r.bottom=v.top+v.height;}
'''
# Only the Android TextView type spelling and `next != this` sentinel use test equivalents.
body=method('TvScrollView.java','boolean readingKey(').replace('android.widget.TextView','TextView').replace('next != this && ','')
gate='''package com.pilipala.marcomovie;
class SuggestionSlice {
 int suggestionSerial=7;boolean valid=true;
 static class Host{boolean privateMode;}final Host a=new Host();
 static class Ime{boolean composing;boolean composing(){return composing;}}final Ime imeDraft=new Ime();
 static class Keyboard{String query="dldl";String query(){return query;}}Keyboard keyboard=new Keyboard();
 boolean current(){return valid;}
'''+method('GlobalSearchScreen.java','boolean acceptsTitleSuggestions(')+'\n}'
test='''package com.pilipala.marcomovie;
class FeedbackHostChecks {
 static int n;static void check(boolean b,String label){if(!b)throw new AssertionError(label);n++;System.out.println("PASS "+label);}
 public static void main(String[] args){
  FocusSlice s=new FocusSlice();FocusSlice.KeyEvent e=new FocusSlice.KeyEvent();
  FocusSlice.View first=new FocusSlice.TextView(0,50,true),next=new FocusSlice.TextView(1200,50,true);
  s.readingKey(e,130,first,next);check(next.requests==1 && s.goal>600,"offscreen control receives focus on first DOWN");
  s.scroll=1000;s.readingKey(e,33,next,first);check(first.requests==1 && s.goal==0,"first UP returns to prior control");
  FocusSlice.TextView prose=new FocusSlice.TextView(0,3000,false);s.scroll=0;
  next.requests=0;s.readingKey(e,130,prose,next);check(next.requests==0 && s.goal==528,"tall prose reads one viewport with context");
  e.repeat=1;e.time=1050;int before=s.goal;s.readingKey(e,130,prose,next);check(s.goal==before,"rapid repeat does not queue another page");
  e.repeat=0;e.time=1300;s.scroll=2600;s.readingKey(e,33,next,prose);check(prose.requests==1 && s.goal==2414,"UP into tall prose reveals its bottom");
  SuggestionSlice g=new SuggestionSlice();check(g.acceptsTitleSuggestions(7,"dldl"),"current query publishes suggestions");
  check(!g.acceptsTitleSuggestions(6,"dldl"),"superseded worker cannot publish");
  g.valid=false;check(!g.acceptsTitleSuggestions(7,"dldl"),"closed page or changed context cannot publish");g.valid=true;
  g.a.privateMode=true;check(!g.acceptsTitleSuggestions(7,"dldl"),"private space cannot expose public title history");g.a.privateMode=false;
  g.imeDraft.composing=true;check(!g.acceptsTitleSuggestions(7,"dldl"),"IME composition blocks suggestions");g.imeDraft.composing=false;
  g.keyboard.query="santi";check(!g.acceptsTitleSuggestions(7,"dldl"),"edited query rejects stale result");
  g.keyboard=null;check(!g.acceptsTitleSuggestions(7,"dldl"),"discarded keyboard rejects callback");
  System.out.println("TOTAL "+n);
 }
}'''
with tempfile.TemporaryDirectory(prefix='tv-feedback-host-') as tmp:
    d=Path(tmp);files=[]
    for name,data in [('FocusSlice.java',prefix+body+'\n}'),('SuggestionSlice.java',gate),('FeedbackHostChecks.java',test)]:
        p=d/name;p.write_text(data,'utf8');files.append(p)
    subprocess.run([str(resolve_jdk_bin()/('javac'+SUFFIX)),'-encoding','UTF-8','-d',str(d),str(SRC/'TvReadingScrollPolicy.java'),*map(str,files)],check=True)
    subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-cp',str(d),'com.pilipala.marcomovie.FeedbackHostChecks'],check=True)
