"""Build the independent Marco Movie native preview using an existing Android SDK."""
from pathlib import Path
import hashlib, json, os, subprocess, zipfile, urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'android/src/main'
BUILD = ROOT / 'android/build'
DIST = ROOT / 'dist'
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
SDK = Path(os.environ.get('MARCOMOVIE_BUILD_TOOLS', 'missing-build-tools'))
ANDROID = Path(os.environ.get('MARCOMOVIE_ANDROID_JAR', str(ROOT/'tools/android-35/android.jar')))
ENV = dict(os.environ, JAVA_HOME=str(JDK), PATH=str(JDK/'bin')+os.pathsep+os.environ.get('PATH',''), MARCOMOVIE_KEY_PASSWORD='android')

def exe(parent,name):
    return parent / (name + ('.exe' if os.name=='nt' else ''))

def run(*args, capture=False):
    r = subprocess.run([str(x) for x in args], cwd=ROOT, env=ENV, check=True, text=True,
                       encoding='utf-8', errors='replace', stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None)
    return r.stdout if capture else None

def main():
    if 'MARCOMOVIE_ANDROID_JAR' not in os.environ:
        from prepare_android_platform import prepare
        prepare()
    dependencies=[];native_files={};resource_dirs=[];packages=[]
    items=json.loads((ROOT/'android/dependencies.json').read_text(encoding='utf-8'))
    for filename in ('media-dependencies.json','torrent-dependencies.json','decoder-dependencies.json'):
        manifest=ROOT/'android'/filename
        if manifest.exists():items+=json.loads(manifest.read_text(encoding='utf-8'))
    for item in items:
        jar=ROOT/'tools/java-dependencies'/item['url'].rsplit('/',1)[1];jar.parent.mkdir(parents=True,exist_ok=True)
        if not jar.exists():jar.write_bytes(urllib.request.urlopen(item['url'],timeout=30).read())
        if hashlib.sha256(jar.read_bytes()).hexdigest()!=item['sha256']:raise RuntimeError('Dependency digest mismatch: '+item['name'])
        if jar.suffix=='.aar':
            unpack=BUILD/'aar'/jar.stem;unpack.mkdir(parents=True,exist_ok=True)
            with zipfile.ZipFile(jar) as z:
                classes=unpack/'classes.jar';classes.write_bytes(z.read('classes.jar'));dependencies.append(classes)
                manifest=ET.fromstring(z.read('AndroidManifest.xml'))
                package=manifest.get('package')
                if package:packages.append(package)
                for name in z.namelist():
                    if name.startswith('jni/armeabi-v7a/') and name.endswith('.so'):native_files['lib/'+name[4:]]=z.read(name)
                    if name.startswith('res/') and not name.endswith('/'):
                        target=(unpack/name).resolve()
                        if not target.is_relative_to(unpack.resolve()):raise RuntimeError('Invalid AAR resource path')
                        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(z.read(name))
                if (unpack/'res').exists():resource_dirs.append(unpack/'res')
        else:
            if item.get('java_classes',True):dependencies.append(jar)
            if item.get('native_members'):
                with zipfile.ZipFile(jar) as z:
                    for name in item['native_members']:
                        if not name.startswith('lib/armeabi-v7a/') or not name.endswith('.so'):raise RuntimeError('Unexpected native dependency member')
                        native_files[name]=z.read(name)
    for p in (JDK/'bin/java.exe', SDK/'aapt2.exe', ANDROID):
        if not p.exists(): raise RuntimeError(f'Required existing tool missing: {p}')
    for folder in (BUILD, BUILD/'classes', BUILD/'dex', DIST): folder.mkdir(parents=True, exist_ok=True)
    boundary = BUILD.resolve()
    for folder, pattern in ((BUILD/'classes','*.class'),(BUILD/'dex','*.dex')):
        for old in folder.rglob(pattern):
            if not old.resolve().is_relative_to(boundary): raise RuntimeError('Generated output leaves build directory')
            old.unlink()
    run(exe(SDK,'aapt2'),'compile','--dir',SRC/'res','-o',BUILD/'resources.zip')
    overlays=[]
    for i,folder in enumerate(resource_dirs):
        resource=BUILD/f'dep-res-{i}.zip';run(exe(SDK,'aapt2'),'compile','--dir',folder,'-o',resource);overlays+=['-R',resource]
    generated=BUILD/'generated';generated.mkdir(exist_ok=True)
    for old in generated.rglob('*.java'):old.unlink()
    extra=['--extra-packages',':'.join(sorted(set(packages)))] if packages else []
    run(exe(SDK,'aapt2'),'link','-o',BUILD/'resources.apk','--manifest',SRC/'AndroidManifest.xml','-I',ANDROID,'-A',SRC/'assets','--java',generated,'--auto-add-overlay',*extra,*overlays,'-R',BUILD/'resources.zip')
    sources=sorted((SRC/'java').rglob('*.java'))+sorted(generated.rglob('*.java'))
    run(exe(JDK/'bin','javac'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-classpath',os.pathsep.join(str(p) for p in [ANDROID,*dependencies]),'-d',BUILD/'classes',*sources)
    with zipfile.ZipFile(BUILD/'classes.jar','w',zipfile.ZIP_DEFLATED) as z:
        for p in (BUILD/'classes').rglob('*.class'): z.write(p,p.relative_to(BUILD/'classes').as_posix())
    run(exe(JDK/'bin','java'),'-cp',SDK/'lib/d8.jar','com.android.tools.r8.D8','--min-api','23','--lib',ANDROID,'--output',BUILD/'dex',BUILD/'classes.jar',*dependencies)
    with zipfile.ZipFile(BUILD/'resources.apk') as source, zipfile.ZipFile(BUILD/'unsigned.apk','w',zipfile.ZIP_DEFLATED) as dest:
        for entry in source.infolist():dest.writestr(entry,source.read(entry.filename))
        for dex in (BUILD/'dex').glob('*.dex'):dest.write(dex,dex.name)
        for name,data in native_files.items():dest.writestr(name,data)
    run(exe(SDK,'zipalign'),'-f','4',BUILD/'unsigned.apk',BUILD/'aligned.apk')
    key=Path(os.environ.get('MARCOMOVIE_SIGNING_KEY',str(ROOT/'android/private/development.p12')));key.parent.mkdir(parents=True,exist_ok=True)
    if not key.exists():
        run(exe(JDK/'bin','keytool'),'-genkeypair','-keystore',key,'-storetype','PKCS12','-alias','marcomovie','-storepass:env','MARCOMOVIE_KEY_PASSWORD','-keypass:env','MARCOMOVIE_KEY_PASSWORD','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=Pilipala, OU=Marco Movie Preview')
    version=ET.parse(SRC/'AndroidManifest.xml').getroot().get('{http://schemas.android.com/apk/res/android}versionName')
    apk=DIST/f'MarcoMovie-{version}-preview.apk'
    run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--ks',key,'--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',apk,BUILD/'aligned.apk')
    signature=run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','verify','--verbose','--print-certs',apk,capture=True)
    alignment=run(exe(SDK,'zipalign'),'-c','4',apk,capture=True)
    badging=run(exe(SDK,'aapt'),'dump','badging',apk,capture=True)
    digest=hashlib.sha256(apk.read_bytes()).hexdigest()
    (DIST/(apk.name+'.sha256')).write_text(digest+'  '+apk.name+'\n',encoding='ascii')
    (BUILD/'apk-signature.txt').write_text(signature,encoding='utf-8')
    (BUILD/'apk-badging.txt').write_text(badging,encoding='utf-8')
    result={'apk':apk.name,'sha256':digest,'bytes':apk.stat().st_size,'signature_verified':True,'zipalign_verified':True,'package':'com.pilipala.marcomovie','version':version,'min_sdk':23,'target_sdk':28,'device_install_tested':False,'device_playback_tested':False,'signing':'independent local development key; not a store release'}
    (BUILD/'build-validation.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
