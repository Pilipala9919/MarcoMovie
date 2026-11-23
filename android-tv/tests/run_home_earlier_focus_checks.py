"""Exercise the actual earlier-button visibility code and its previous counterexample."""
import os, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = 'android-tv/src/main/java/com/pilipala/marcomovie/HomeScreen.java'
JAVA = Path(os.environ['MARCOMOVIE_JDK']) / 'bin'
SUFFIX = '.exe' if os.name == 'nt' else ''
old = subprocess.check_output(['git','show','6a6db2aa35ce1091aa1272b03a0084a20f27068f:'+HOME], cwd=ROOT).decode('utf8')
old_line = next(line.strip() for line in old.splitlines() if 'earlier.setVisibility(state.windowStart' in line)
source = (ROOT/HOME).read_text(encoding='utf8')
start = source.index('    void updateEarlier() {')
at = source.index('{',start); end = at+1; depth = 1
while depth:
    depth += (source[end]=='{')-(source[end]=='}'); end += 1
with tempfile.TemporaryDirectory(prefix='earlier-focus-') as directory:
    work = Path(directory)
    for label, method in [('old','void updateEarlier(){'+old_line+'}'),('fixed',source[start:end])]:
        harness = '''public class EarlierCheck {
          static class View {static int VISIBLE=0,GONE=8;}
          static class Button {boolean focus; int visibility=0; boolean hasFocus(){return focus;}
            void setVisibility(int v){visibility=v;}}
          static class State {int windowStart;}
          State state=new State(); Button earlier=new Button();
          METHOD
          static void check(boolean b,String s){if(!b)throw new AssertionError(s);System.out.println("PASS "+s);}
          public static void main(String[] args){
            EarlierCheck h=new EarlierCheck(); h.earlier.focus=true;h.state.windowStart=0;
            h.updateEarlier();check(h.earlier.visibility==0,"focused earlier survives final return");
            h.updateEarlier();check(h.earlier.visibility==0,"repeated draw waits for focus transfer");
            h.earlier.focus=false;h.updateEarlier();check(h.earlier.visibility==8,"hide after destination receives focus");
            h.state.windowStart=360;h.updateEarlier();check(h.earlier.visibility==0,"earlier remains available outside first window");
          }}'''.replace('METHOD',method)
        p=work/'EarlierCheck.java';p.write_text(harness,encoding='utf8')
        subprocess.run([str(JAVA/('javac'+SUFFIX)),'-encoding','UTF-8','-d',str(work),str(p)],check=True)
        r=subprocess.run([str(JAVA/('java'+SUFFIX)),'-cp',str(work),'EarlierCheck'],capture_output=True,text=True)
        print(label,r.returncode,r.stdout,r.stderr)
        assert (r.returncode!=0 if label=='old' else r.returncode==0)
