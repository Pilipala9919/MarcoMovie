"""Offline diagnostic-contract checks plus javac/D8. No APK, device, signing or network work."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PREVIOUS = "a088e7818ad86eff04b6b3dd69456975ff2ca1e7"


def method(text, signature):
    start = text.index(signature)
    at = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[at] == "{") - (text[at] == "}")
        at += 1
    return text[start:at]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--jdk", type=Path, required=True)
    parser.add_argument("--android", type=Path, required=True)
    parser.add_argument("--d8", type=Path, required=True)
    parser.add_argument("--product-classes", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    build = (ROOT / "android-mobile/build").resolve()
    if not out.is_relative_to(build) or out == build or out.exists():
        parser.error("Use a NEW child of this checkout's android-mobile/build")
    out.mkdir(parents=True)
    report = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "native_execution": False, "apk_build": False, "commands": [], "checks": {}}
    java = args.jdk / "bin" / ("java.exe" if os.name == "nt" else "java")
    javac = args.jdk / "bin" / ("javac.exe" if os.name == "nt" else "javac")

    def run(name, *command):
        completed = subprocess.run(list(map(str, command)), cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        (out / (name + ".log")).write_bytes(completed.stdout)
        report["commands"].append({"name": name, "exit_code": completed.returncode})
        if completed.returncode:
            raise RuntimeError(name + " failed; see retained log")

    try:
        current = (ROOT / "android-mobile/tests/device/HomeProbe.java").read_text(encoding="utf-8")
        old = subprocess.check_output(["git", "show", PREVIOUS + ":android-mobile/tests/device/HomeProbe.java"], cwd=ROOT).decode("utf-8").replace("\r\n", "\n")
        replacement = ('        HomeRenderDiagnostics.awaitLastCard(this, a, this::retained,\n'
                       '                () -> tag("home-video:" + (retained().windowEnd() - 1)) != null,\n'
                       '                result, result.optString("section_stage"));')
        original = '        await(() -> tag("home-video:" + (retained().windowEnd() - 1)) != null);'
        assert current.count(replacement) == 1
        assert current.replace(replacement, original) == old
        report["checks"]["full_homeprobe_otherwise_byte_identical_lf"] = True
        spec = importlib.util.spec_from_file_location("overlay", HERE / "prepare_home_render_diagnostics.py")
        overlay = importlib.util.module_from_spec(spec); spec.loader.exec_module(overlay)
        cp = str(args.android) + os.pathsep + str(args.product_classes)
        for label, revision in (("base", overlay.BASE), ("current", overlay.CURRENT)):
            original_source = subprocess.check_output(["git", "show", revision + ":" + overlay.SOURCE], cwd=ROOT).decode("utf-8").replace("\r\n", "\n")
            generated, edits = overlay.instrument(original_source)
            folder = out / label; folder.mkdir(); (folder / "classes").mkdir()
            (folder / "HomeScreen.java").write_text(generated, encoding="utf-8")
            trace = (HERE / "HomeGridTrace.java.in").read_text(encoding="utf-8").replace("@SOURCE_REVISION@", revision)
            (folder / "HomeGridTrace.java").write_text(trace, encoding="utf-8")
            run(label + "-javac", javac, "-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options",
                "-classpath", cp, "-d", folder / "classes", folder / "HomeScreen.java", folder / "HomeGridTrace.java")
            report["checks"][label + "_inverse_exact"] = True
            report["checks"][label + "_overlay_sha256"] = hashlib.sha256(generated.encode()).hexdigest()
        # Both syntax checks use the reviewed current classpath. This is NOT a baseline app build.
        report["baseline_compile_scope"] = "baseline HomeScreen source syntax against current dependency classes; A must build an authentic baseline fixture"
        probes = out / "probe-classes"; probes.mkdir()
        sources = [ROOT / ("android-mobile/tests/device/" + name + ".java") for name in
                   ("HomeProbe", "HomeRenderDiagnostics", "GridRenderCompareProbe")]
        run("probe-javac", javac, "-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options",
            "-classpath", cp, "-d", probes, *sources)
        for label, classes in (("probe", probes), ("current-overlay", out / "current/classes"), ("base-overlay", out / "base/classes")):
            archive = out / (label + ".jar")
            with zipfile.ZipFile(archive, "w") as jar:
                for path in sorted(classes.rglob("*.class")):
                    jar.write(path, path.relative_to(classes).as_posix())
            dex = out / (label + "-dex"); dex.mkdir()
            run(label + "-d8", java, "-cp", args.d8, "com.android.tools.r8.D8", "--min-api", "23",
                "--lib", args.android, "--classpath", args.product_classes, "--output", dex, archive)
        runtime = out / "runtime"; runtime.mkdir(); (runtime / "classes").mkdir()
        stubs = {
            "SystemClock.java": '''package android.os; public final class SystemClock {
                public static long now, queue; public static long elapsedRealtime(){return now;}
                public static void sleep(long ms){now+=ms;}}
            ''',
            "Instrumentation.java": '''package android.app; public class Instrumentation {
                public void runOnMainSync(Runnable action){android.os.SystemClock.now+=android.os.SystemClock.queue;action.run();}}
            ''',
            "View.java": '''package android.view; public class View {public boolean broken;
                public boolean isAttachedToWindow(){if(broken)throw new IllegalStateException("observer read failed");return true;}
                public boolean isShown(){return true;}}
            ''',
            "MainActivity.java": '''package com.pilipala.marcomovie; class MainActivity {
                int generation=7; java.io.File output; boolean isFinishing(){return false;}
                java.io.File getExternalFilesDir(String ignored){return output;}}
            ''',
            "HomeScreen.java": '''package com.pilipala.marcomovie; class HomeScreen {
                MainActivity a; int ticket=7,gridEpoch=4; boolean busy; Runnable pendingGrid;
                android.view.View content=new android.view.View(); State state=new State();
                java.util.List<java.util.List<android.view.View>> rows=new java.util.ArrayList<>();
                boolean active(){return ticket==a.generation&&!a.isFinishing();} int windowEnd(){return 360;}
                static class State{boolean ready=true;int windowStart,page=1;java.util.List<Object>videos=new java.util.ArrayList<>();}}
            '''}
        for name, source in stubs.items(): (runtime / name).write_text(source, encoding="utf-8")
        (runtime / "HomeGridTrace.java").write_text((out / "current/HomeGridTrace.java").read_text(encoding="utf-8"), encoding="utf-8")
        original_await = method(old, "void await(Callable<Boolean> condition)")
        original_ui = method(old, "boolean ui(Callable<Boolean> call)")
        harness = '''package com.pilipala.marcomovie;
import java.util.concurrent.Callable; import org.json.*; import android.os.SystemClock;
public class RenderDiagnosticContract extends android.app.Instrumentation {
static int checks; static void require(boolean ok,String name){if(!ok)throw new AssertionError(name);checks++;System.out.println("PASS "+name);}
MainActivity app=new MainActivity(); HomeScreen home=new HomeScreen();
RenderDiagnosticContract(java.io.File dir){app.output=dir;home.a=app;}
void parity(int stopAt,long queue,boolean broken)throws Exception{
    int[] oldPolls={0}; boolean oldFail=false; SystemClock.now=0;SystemClock.queue=queue;
    try{await(()->++oldPolls[0]>=stopAt);}catch(AssertionError expected){oldFail=true;}
    long oldEnded=SystemClock.now; int[] newPolls={0};boolean newFail=false;
    SystemClock.now=0;home.content.broken=broken;JSONObject result=new JSONObject();
    try{HomeRenderDiagnostics.awaitLastCard(this,app,()->home,()->++newPolls[0]>=stopAt,result,"contract");}
    catch(AssertionError expected){require("Wait timed out".equals(expected.getMessage()),"original failure preserved");newFail=true;}
    require(oldFail==newFail,"predicate outcome preserved");
    require(oldPolls[0]==newPolls[0],"original poll count preserved");
    // stopTrace uses one extra main-thread dispatch AFTER the original wait, never for its predicate.
    require(SystemClock.now==oldEnded+queue,"deadline/sleep unchanged; cleanup separately accounted");
    require(result.has("render_waits"),"bounded sidecar recorded");
    if(broken)require(result.getJSONArray("render_waits").getJSONObject(0).has("diagnostic_error"),"observer failure reported without changing predicate");
    home.content.broken=false;
}
void collector()throws Exception{
    SystemClock.now=100;HomeGridTrace.begin(home,110);HomeGridTrace.mark(home,1,0,5,4,0);
    HomeScreen other=new HomeScreen();other.a=app;HomeGridTrace.mark(other,1,0,5,4,0);
    SystemClock.now=110;HomeGridTrace.mark(home,14,-1,-1,4,0);SystemClock.now=111;HomeGridTrace.mark(home,15,-1,-1,5,0);
    long[][] capture=HomeGridTrace.finish();require(capture[0][0]==2&&capture[0][2]==1,"owner and deadline bound events");
    require(capture[1][5]==4&&capture[1][6]==4&&capture[1][7]==7,"captured/current epoch and ticket retained");
    require(home.gridEpoch==4&&home.ticket==7&&!home.busy&&home.pendingGrid==null,"collector does not mutate product state");
    HomeGridTrace.mark(home,1,0,5,4,0);require(HomeGridTrace.owner==null,"disabled after finish");
    SystemClock.now=0;HomeGridTrace.begin(home,1000);for(int n=0;n<HomeGridTrace.LIMIT+3;n++)HomeGridTrace.mark(home,1,n,n+1,4,0);
    capture=HomeGridTrace.finish();require(capture[0][0]==HomeGridTrace.LIMIT&&capture[0][1]==3,"bounded overflow counted");
    HomeGridTrace.begin(home,1000);home.content.broken=true;HomeGridTrace.mark(home,1,0,1,4,0);home.content.broken=false;
    require(HomeGridTrace.finish()[0][3]==1,"trace read failure contained");
}
public static void main(String[] args)throws Exception{
    RenderDiagnosticContract t=new RenderDiagnosticContract(new java.io.File(args[0]));
    t.parity(1,0,false);t.parity(6,40,false);t.parity(Integer.MAX_VALUE,0,false);
    t.parity(Integer.MAX_VALUE,40,false);t.parity(2,0,true);t.collector();
    System.out.println("CHECKS="+checks+"; NATIVE_ASSERTIONS=0");
}
''' + original_ui + '\n' + original_await + '\n}\n'
        (runtime / "RenderDiagnosticContract.java").write_text(harness, encoding="utf-8")
        json_sources = list((ROOT / "android-mobile/tests/lib/aosp-json").rglob("*.java"))
        run("runtime-javac", javac, "-encoding", "UTF-8", "-d", runtime / "classes",
            *runtime.glob("*.java"), ROOT / "android-mobile/tests/device/HomeRenderDiagnostics.java", *json_sources)
        run("runtime-contract", java, "-cp", runtime / "classes", "com.pilipala.marcomovie.RenderDiagnosticContract", runtime)
        report["checks"]["runtime_contract"] = (out / "runtime-contract.log").read_text(encoding="utf-8").strip().splitlines()[-1]
        spec = importlib.util.spec_from_file_location("analysis", HERE / "analyze_home_render_trace.py")
        analysis = importlib.util.module_from_spec(spec); spec.loader.exec_module(analysis)
        example = json.loads((runtime / "home-render-wait-000.json").read_text(encoding="utf-8"))
        def event(kind, ms, start=0, epoch=4, value=0):
            values = {"kind": kind, "nano_time": int(ms * 1000000), "elapsed_ms": int(ms),
                      "start": start, "captured_epoch": epoch, "home_id": 1, "value": value}
            return [values.get(key, 0) for key in example["event_columns"]]
        example["events"] = [event(1, 0), event(2, 1), event(3, 3), event(4, 4), event(5, 5),
                             event(8, 6, 5), event(13, 6.5), event(9, 9, 5), event(10, 10, 5, value=1),
                             event(16, 12, 5), event(14, 13, -1, 4), event(15, 14, -1, 5)]
        example["event_count"] = len(example["events"])
        summary = analysis.analyze(example)
        assert summary["phase_ms"]["batch"]["total"] == 6.5
        assert summary["phase_ms"]["build"]["total"] == 2
        assert summary["phase_ms"]["wire"]["total"] == 1
        assert summary["phase_ms"]["animation_queue"]["total"] == 3
        assert summary["phase_ms"]["handler_queue"]["total"] == 2
        assert summary["phase_ms"]["cancel"]["total"] == 1
        assert summary["unpaired_starts"] == 0 and summary["unpaired_ends"] == 0
        report["checks"]["analysis_pairing_checks"] = 7
        (out / "analysis-contract.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        report["product_classes_sha256"] = hashlib.sha256(args.product_classes.read_bytes()).hexdigest()
        report["passed"] = True
    except Exception as error:
        report["passed"] = False; report["error"] = repr(error)
    report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (out / "check-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
