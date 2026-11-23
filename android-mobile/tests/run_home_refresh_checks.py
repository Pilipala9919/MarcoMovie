"""Actual snapshot comparator and extracted updateMore body, including the pre-fix counterexample."""
from pathlib import Path
import os, subprocess, tempfile
from android_compile_support import compile_real_android_sources, resolve_jdk_bin, SUFFIX

ROOT = Path(__file__).resolve().parents[2]
HOME = 'android-mobile/src/main/java/com/pilipala/marcomovie/HomeScreen.java'


def method(text, name='updateMore'):
    start = text.index('    void '+name+'() {')
    at = text.index('{', start); depth = 1; end = at + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]


with tempfile.TemporaryDirectory(prefix='home-refresh-') as directory:
    work = Path(directory); classes = work / 'classes'
    cp = compile_real_android_sources(classes_dir=classes, work_dir=work,
        test_sources=[ROOT/'android-mobile/tests/HomeRefreshChecks.java'])
    java = str(resolve_jdk_bin()/('java'+SUFFIX)); javac = str(resolve_jdk_bin()/('javac'+SUFFIX))
    subprocess.run([java,'-Dfile.encoding=UTF-8','-cp',os.pathsep.join(map(str,cp)),
                    'com.pilipala.marcomovie.HomeRefreshChecks'],check=True)
    old = (ROOT/'android-mobile/tests/fixtures/home-update-more-before-v17.txt').read_text(encoding='utf8')
    for label, source in [('old',old),('fixed',(ROOT/HOME).read_text(encoding='utf8'))]:
        test = '''public class RetryCheck {
          static class View {static int VISIBLE=0,GONE=8;}
          static class Button {String text="重新加载"; boolean focus; int visibility=0;
            String getText(){return text;} boolean hasFocus(){return focus;}
            void setText(String s){text=s;} void setVisibility(int v){visibility=v;}}
          static class State {boolean ready,categoryFailed; int windowStart;}
          Button more=new Button(), earlier=new Button(); State state=new State();
          METHOD
          public static void main(String[] args){
            RetryCheck h=new RetryCheck(); h.state.ready=true; h.state.categoryFailed=true;
            h.updateMore(); if(h.more.visibility!=0)throw new AssertionError("later-page retry hidden by pending draw completion");
            h.updateMore(); if(h.more.visibility!=0)throw new AssertionError("retry did not survive another completion");
            h.state.categoryFailed=false;h.state.ready=false;h.updateMore();
            if(h.more.visibility!=0)throw new AssertionError("first-page retry lost");
            h.state.ready=true;h.updateMore();if(h.more.visibility!=8)throw new AssertionError("success leaves retry visible");
            System.out.println("PASS 4 extracted actual updateMore transitions");
          }}'''.replace('METHOD',method(source)+(method(source,'updateEarlier') if label=='fixed' else ''))
        p=work/'RetryCheck.java';p.write_text(test,encoding='utf8')
        subprocess.run([javac,'-encoding','UTF-8','-d',str(work),str(p)],check=True)
        r=subprocess.run([java,'-cp',str(work),'RetryCheck'],capture_output=True,text=True)
        print(label,r.returncode,r.stdout.strip(),r.stderr.strip())
        assert (r.returncode != 0 if label == 'old' else r.returncode == 0)
