"""Build a separate instrumentation APK using the local development identity."""
from pathlib import Path
import sys, zipfile, os
sys.path.insert(0,str(Path(__file__).parent))
from build_android import ROOT, BUILD, JDK, SDK, ANDROID, run, exe

probe_name=sys.argv[1] if len(sys.argv)>1 else 'DecoderProbe'
assert probe_name in ('DecoderProbe','InteractionProbe','HomeProbe')
out=BUILD/('probe' if probe_name=='Probe' else 'decoder-probe' if probe_name=='DecoderProbe' else 'home-probe' if probe_name=='HomeProbe' else 'interaction-probe');out.mkdir(exist_ok=True)
for d in ('classes','dex'): (out/d).mkdir(exist_ok=True)
manifest=out/'AndroidManifest.xml'
manifest.write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test"><uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/><application android:label="Marco Movie local test"/><instrumentation android:name="com.pilipala.marcomovie.Probe" android:targetPackage="com.pilipala.marcomovie"/></manifest>''',encoding='utf-8')
manifest.write_text(manifest.read_text().replace('com.pilipala.marcomovie.Probe','com.pilipala.marcomovie.'+probe_name),encoding='utf-8')
run(exe(SDK,'aapt2'),'link','-o',out/'resources.apk','--manifest',manifest,'-I',ANDROID)
run(exe(JDK/'bin','javac'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-classpath',str(ANDROID)+';'+str(BUILD/'classes.jar'),'-d',out/'classes',ROOT/('android/tests/device/'+probe_name+'.java'))
with zipfile.ZipFile(out/'classes.jar','w') as z:
    for p in (out/'classes').rglob('*.class'):z.write(p,p.relative_to(out/'classes').as_posix())
run(exe(JDK/'bin','java'),'-cp',SDK/'lib/d8.jar','com.android.tools.r8.D8','--min-api','23','--lib',ANDROID,'--classpath',BUILD/'classes.jar','--output',out/'dex',out/'classes.jar')
with zipfile.ZipFile(out/'resources.apk') as src,zipfile.ZipFile(out/'unsigned.apk','w',zipfile.ZIP_DEFLATED) as dst:
    for n in src.namelist():dst.writestr(n,src.read(n))
    dst.write(out/'dex/classes.dex','classes.dex')
run(exe(SDK,'zipalign'),'-f','4',out/'unsigned.apk',out/'aligned.apk')
run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--ks',Path(os.environ.get('MARCOMOVIE_SIGNING_KEY',str(ROOT/'android/private/development.p12'))),'--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',out/'probe.apk',out/'aligned.apk')
print(out/'probe.apk')
