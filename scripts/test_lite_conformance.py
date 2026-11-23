"""TV Lite Tri-Platform Conformance Test Suite Runner."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
ZXING_URL = 'https://repo.maven.apache.org/maven2/com/google/zxing/core/3.2.1/core-3.2.1.jar'

ANDROID_SHIM_BASE64 = """package android.util;
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int URL_SAFE = 8;
    public static byte[] decode(String str, int flags) {
        String cleaned = str.trim().replace("\\r", "").replace("\\n", "");
        if ((flags & URL_SAFE) != 0 || cleaned.indexOf('-') >= 0 || cleaned.indexOf('_') >= 0) {
            cleaned = cleaned.replace('-', '+').replace('_', '/');
        }
        while (cleaned.length() % 4 != 0) cleaned += "=";
        return java.util.Base64.getDecoder().decode(cleaned);
    }
    public static byte[] decode(byte[] input, int flags) {
        return decode(new String(input, java.nio.charset.StandardCharsets.US_ASCII), flags);
    }
    public static String encodeToString(byte[] input, int flags) {
        java.util.Base64.Encoder enc = ((flags & URL_SAFE) != 0)
            ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) enc = enc.withoutPadding();
        return enc.encodeToString(input);
    }
}
"""

ANDROID_SHIM_LOG = """package android.util;
public final class Log {
    public static int w(String tag, String msg) { return 0; }
    public static int w(String tag, String msg, Throwable tr) { return 0; }
    public static int i(String tag, String msg) { return 0; }
    public static int d(String tag, String msg) { return 0; }
    public static int e(String tag, String msg) { return 0; }
}
"""

ANDROID_SHIM_XML = """package android.util;
import java.io.InputStream;
import java.io.Reader;
import javax.xml.stream.XMLInputFactory;
import javax.xml.stream.XMLStreamConstants;
import javax.xml.stream.XMLStreamReader;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserException;

public final class Xml {
    public static XmlPullParser newPullParser() { return new StaxPullParser(); }
    private static final class StaxPullParser implements XmlPullParser {
        private XMLStreamReader reader;
        private int eventType = START_DOCUMENT;
        @Override public void setInput(Reader in) throws XmlPullParserException {
            try {
                XMLInputFactory f = XMLInputFactory.newInstance();
                f.setProperty(XMLInputFactory.IS_COALESCING, Boolean.TRUE);
                reader = f.createXMLStreamReader(in);
                eventType = START_DOCUMENT;
            } catch (Exception e) { throw new XmlPullParserException(e.getMessage()); }
        }
        @Override public int getEventType() { return eventType; }
        @Override public int next() throws XmlPullParserException {
            try {
                while (reader.hasNext()) {
                    int code = reader.next();
                    if (code == XMLStreamConstants.START_ELEMENT) return eventType = START_TAG;
                    if (code == XMLStreamConstants.END_ELEMENT) return eventType = END_TAG;
                    if (code == XMLStreamConstants.CHARACTERS || code == XMLStreamConstants.CDATA) return eventType = TEXT;
                    if (code == XMLStreamConstants.END_DOCUMENT) return eventType = END_DOCUMENT;
                }
                return eventType = END_DOCUMENT;
            } catch (Exception e) { throw new XmlPullParserException(e.getMessage()); }
        }
        @Override public String getName() { return reader.getLocalName(); }
        @Override public String getAttributeValue(String namespace, String name) { return reader.getAttributeValue(namespace, name); }
        @Override public String nextText() throws XmlPullParserException {
            try { return reader.getElementText(); } catch (Exception e) { throw new XmlPullParserException(e.getMessage()); } finally { eventType = END_TAG; }
        }
        @Override public void setFeature(String name, boolean state) {}
        @Override public boolean getFeature(String name) { return false; }
        @Override public void setProperty(String name, Object value) {}
        @Override public Object getProperty(String name) { return null; }
        @Override public void setInput(InputStream inputStream, String inputEncoding) {}
        @Override public String getInputEncoding() { return "UTF-8"; }
        @Override public void defineEntityReplacementText(String entityName, String replacementText) {}
        @Override public int getNamespaceCount(int depth) { return 0; }
        @Override public String getNamespacePrefix(int pos) { return null; }
        @Override public String getNamespaceUri(int pos) { return null; }
        @Override public String getNamespace(String prefix) { return null; }
        @Override public int getDepth() { return 0; }
        @Override public String getPositionDescription() { return ""; }
        @Override public int getLineNumber() { return 0; }
        @Override public int getColumnNumber() { return 0; }
        @Override public boolean isWhitespace() { return false; }
        @Override public String getText() { return reader.getText(); }
        @Override public char[] getTextCharacters(int[] holderForStartAndLength) { return new char[0]; }
        @Override public String getNamespace() { return ""; }
        @Override public String getPrefix() { return null; }
        @Override public boolean isEmptyElementTag() { return false; }
        @Override public int getAttributeCount() { return reader.getAttributeCount(); }
        @Override public String getAttributeNamespace(int index) { return ""; }
        @Override public String getAttributeName(int index) { return reader.getAttributeLocalName(index); }
        @Override public String getAttributePrefix(int index) { return null; }
        @Override public String getAttributeType(int index) { return "CDATA"; }
        @Override public boolean isAttributeDefault(int index) { return false; }
        @Override public String getAttributeValue(int index) { return reader.getAttributeValue(index); }
        @Override public int nextToken() throws XmlPullParserException { return next(); }
        @Override public void require(int type, String namespace, String name) {}
        @Override public int nextTag() throws XmlPullParserException { return next(); }
    }
}
"""

XMLPULL_PARSER = """package org.xmlpull.v1;
import java.io.InputStream;
import java.io.Reader;
public interface XmlPullParser {
    int START_DOCUMENT = 0, END_DOCUMENT = 1, START_TAG = 2, END_TAG = 3, TEXT = 4;
    void setFeature(String name, boolean state) throws XmlPullParserException;
    boolean getFeature(String name);
    void setProperty(String name, Object value) throws XmlPullParserException;
    Object getProperty(String name);
    void setInput(Reader in) throws XmlPullParserException;
    void setInput(InputStream inputStream, String inputEncoding) throws XmlPullParserException;
    String getInputEncoding();
    void defineEntityReplacementText(String entityName, String replacementText) throws XmlPullParserException;
    int getNamespaceCount(int depth) throws XmlPullParserException;
    String getNamespacePrefix(int pos) throws XmlPullParserException;
    String getNamespaceUri(int pos) throws XmlPullParserException;
    String getNamespace(String prefix);
    int getDepth();
    String getPositionDescription();
    int getLineNumber();
    int getColumnNumber();
    boolean isWhitespace() throws XmlPullParserException;
    String getText();
    char[] getTextCharacters(int[] holderForStartAndLength);
    String getNamespace();
    String getName();
    String getPrefix();
    boolean isEmptyElementTag() throws XmlPullParserException;
    int getAttributeCount();
    String getAttributeNamespace(int index);
    String getAttributeName(int index);
    String getAttributePrefix(int index);
    String getAttributeType(int index);
    boolean isAttributeDefault(int index);
    String getAttributeValue(int index);
    String getAttributeValue(String namespace, String name);
    int getEventType() throws XmlPullParserException;
    int next() throws XmlPullParserException;
    int nextToken() throws XmlPullParserException;
    void require(int type, String namespace, String name) throws XmlPullParserException;
    String nextText() throws XmlPullParserException;
    int nextTag() throws XmlPullParserException;
}
"""

XMLPULL_EXCEPTION = """package org.xmlpull.v1;
public class XmlPullParserException extends Exception {
    public XmlPullParserException(String s) { super(s); }
}
"""

def compile_aosp_json(aosp_classes_dir: Path) -> Path:
    aosp_root = ROOT / 'android-tv/tests/lib/aosp-json'
    sources = sorted((aosp_root / 'src/org/json').glob('*.java'))
    if not sources:
        raise RuntimeError(f'Missing AOSP org.json sources in {aosp_root}')
    aosp_classes_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            exe('javac'), '-encoding', 'UTF-8',
            '-sourcepath', str(aosp_root / 'annotations'),
            '-d', str(aosp_classes_dir),
            *[str(s) for s in sources],
        ],
        check=True,
    )
    return aosp_classes_dir


def prepare_zxing_jar() -> Path:
    jar = ROOT / 'tools/java-dependencies/core-3.2.1.jar'
    pin = ROOT / 'lite/zxing.sha256'
    expected_sha = pin.read_text(encoding='utf-8').strip()
    if not jar.exists():
        jar.parent.mkdir(parents=True, exist_ok=True)
        jar.write_bytes(urllib.request.urlopen(ZXING_URL, timeout=30).read())
    if hashlib.sha256(jar.read_bytes()).hexdigest() != expected_sha:
        raise RuntimeError('ZXing core-3.2.1.jar digest mismatch')
    return jar


def prepare_android_jar() -> Path:
    override = os.environ.get('MARCOMOVIE_ANDROID_JAR')
    if override and Path(override).is_file():
        return Path(override)
    local_jar = ROOT / 'tools/android-35/android.jar'
    if local_jar.is_file():
        return local_jar
    sys.path.insert(0, str(ROOT / 'scripts'))
    from prepare_android_platform import prepare
    return prepare()


def exe(name):
    return str(JDK / 'bin' / (name + ('.exe' if os.name == 'nt' else '')))

def main():
    conformance_dir = ROOT / 'shared/conformance'
    if not conformance_dir.exists():
        print(f"Skipping TV Lite conformance checks: {conformance_dir} does not exist yet.")
        return 0

    zxing_jar = prepare_zxing_jar()
    android_jar = prepare_android_jar()
    with tempfile.TemporaryDirectory(prefix='lite-conformance-') as tmp:
        work = Path(tmp)
        aosp_classes_dir = compile_aosp_json(work / 'aosp-json-classes')
        classes_dir = work / 'classes'
        classes_dir.mkdir()

        # Write shims
        shim_dir = work / 'shims'
        (shim_dir / 'android/util').mkdir(parents=True)
        (shim_dir / 'org/xmlpull/v1').mkdir(parents=True)
        (shim_dir / 'android/util/Base64.java').write_text(ANDROID_SHIM_BASE64, encoding='utf-8')
        (shim_dir / 'android/util/Log.java').write_text(ANDROID_SHIM_LOG, encoding='utf-8')
        (shim_dir / 'android/util/Xml.java').write_text(ANDROID_SHIM_XML, encoding='utf-8')
        (shim_dir / 'org/xmlpull/v1/XmlPullParser.java').write_text(XMLPULL_PARSER, encoding='utf-8')
        (shim_dir / 'org/xmlpull/v1/XmlPullParserException.java').write_text(XMLPULL_EXCEPTION, encoding='utf-8')

        lite_sources = sorted((ROOT / 'lite/src/main/java').rglob('*.java'))
        shared_sources = [
            p
            for pkg in ('emby', 'source', 'glass')
            for p in sorted((ROOT / 'shared/java/com/pilipala' / pkg).rglob('*.java'))
        ]
        sources = [
            shim_dir / 'org/xmlpull/v1/XmlPullParser.java',
            shim_dir / 'org/xmlpull/v1/XmlPullParserException.java',
            shim_dir / 'android/util/Base64.java',
            shim_dir / 'android/util/Log.java',
            shim_dir / 'android/util/Xml.java',
            *shared_sources,
            *lite_sources,
            ROOT / 'lite/tests/LiteConformanceChecks.java',
        ]

        compile_cp = os.pathsep.join([str(aosp_classes_dir), str(zxing_jar), str(android_jar)])
        compile_cmd = [
            exe('javac'), '-encoding', 'UTF-8',
            '-source', '8', '-target', '8', '-Xlint:-options',
            '-cp', compile_cp,
            '-d', str(classes_dir),
            *[str(s) for s in sources],
        ]
        subprocess.run(compile_cmd, check=True)

        run_cp = os.pathsep.join([str(classes_dir), str(aosp_classes_dir), str(zxing_jar), str(android_jar)])
        run_cmd = [
            exe('java'), '-Dfile.encoding=UTF-8',
            '-cp', run_cp,
            'com.pilipala.marcomovie.lite.LiteConformanceChecks',
            str(conformance_dir),
        ]
        res = subprocess.run(run_cmd, check=True, text=True, encoding='utf-8', errors='replace')
        return res.returncode

if __name__ == '__main__':
    sys.exit(main() or 0)
