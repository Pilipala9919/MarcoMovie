"""Compile actual paging methods; reject prefetch caused by a partly rendered window."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[2]
HOME = 'android-mobile/src/main/java/com/pilipala/marcomovie/HomeScreen.java'
JAVA = Path(os.environ['MARCOMOVIE_JDK'])/'bin'
SUFFIX = '.exe' if os.name == 'nt' else ''
def method(text, name):
    start=text.index('    '+name); at=text.index('{',start); depth=1; end=at+1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
old=subprocess.check_output(['git','show','daffd3eb58a7dcef917a2a97de6d20d59bebdf04:'+HOME],cwd=ROOT).decode('utf8')
fixed=(ROOT/HOME).read_text(encoding='utf8')
with tempfile.TemporaryDirectory(prefix='home-render-gate-') as folder:
    work=Path(folder)
    for label,src in [('before',old),('after',fixed)]:
        methods=method(src,'void maybeAutoLoadMore()')
        if label=='after':methods+=method(src,'boolean renderedWindowComplete()')
        harness='''import java.util.*;
public class PagingCheck {
 static class View {}
 static class State {boolean ready=true,categoryFailed,library=true; int windowStart,page=1,pages=5; List<Object> videos=new ArrayList<>();}
 State state=new State(); boolean busy; Object snapshot=new Object(),homeHost; int loads,moves;
 List<List<View>> rows=new ArrayList<>();
 boolean active(){return true;} int windowSize(){return 360;}
 int windowEnd(){return Math.min(state.videos.size(),state.windowStart+360);}
 void showWindow(int start){moves++;state.windowStart=start;} void loadCategory(boolean fresh){loads++;}
 METHODS
 static PagingCheck make(int start,int size,int drawn){PagingCheck x=new PagingCheck();x.state.windowStart=start;
  for(int i=0;i<size;i++)x.state.videos.add(new Object());List<View> row=new ArrayList<>();for(int i=0;i<drawn;i++)row.add(new View());x.rows.add(row);return x;}
 static void check(boolean b,String s){if(!b)throw new AssertionError(s);System.out.println("PASS "+s);}
 public static void main(String[] a){
  PagingCheck x=make(360,500,29);x.maybeAutoLoadMore();check(x.loads==0&&x.moves==0,"partial buffered window cannot fetch remote page");
  x=make(0,500,29);x.maybeAutoLoadMore();check(x.loads==0&&x.moves==0,"partial first window cannot skip retained cards");
  x=make(0,500,360);x.maybeAutoLoadMore();check(x.moves==1&&x.loads==0&&x.state.windowStart==360,"complete buffered window still advances");
  x=make(360,500,140);x.maybeAutoLoadMore();check(x.loads==1&&x.moves==0,"complete partial tail still loads next page");
  x=make(360,500,140);x.busy=true;x.maybeAutoLoadMore();check(x.loads==0,"busy still deduplicates");
  x=make(1800,2001,201);x.state.page=5;x.maybeAutoLoadMore();check(x.loads==0&&x.moves==0,"last of five pages has no extra request");
 }}'''.replace('METHODS',methods)
        source=work/'PagingCheck.java';source.write_text(harness,encoding='utf8')
        subprocess.run([str(JAVA/('javac'+SUFFIX)),'-encoding','UTF-8','-d',str(work),str(source)],check=True)
        r=subprocess.run([str(JAVA/('java'+SUFFIX)),'-cp',str(work),'PagingCheck'],capture_output=True,text=True)
        print(label,r.returncode,r.stdout,r.stderr)
        assert (r.returncode!=0 if label=='before' else r.returncode==0)
