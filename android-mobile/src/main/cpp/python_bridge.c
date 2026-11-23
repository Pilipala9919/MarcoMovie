#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <Python.h>

static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_initialized = 0;
static PyObject *g_runner_mod = NULL;

static char *jbytes_to_cstr(JNIEnv *env, jbyteArray arr, jsize *out_len) {
    if (arr == NULL) {
        if (out_len) *out_len = 0;
        char *empty = (char *)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }
    jsize len = (*env)->GetArrayLength(env, arr);
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) return NULL;
    if (len > 0) {
        (*env)->GetByteArrayRegion(env, arr, 0, len, (jbyte *)buf);
    }
    buf[len] = '\0';
    if (out_len) *out_len = len;
    return buf;
}

static jbyteArray cstr_to_jbytes(JNIEnv *env, const char *data, Py_ssize_t len) {
    if (!data || len < 0) len = 0;
    jbyteArray arr = (*env)->NewByteArray(env, (jsize)len);
    if (arr && len > 0) {
        (*env)->SetByteArrayRegion(env, arr, 0, (jsize)len, (const jbyte *)data);
    }
    return arr;
}

static jbyteArray error_json_jbytes(JNIEnv *env, const char *prefix, const char *detail) {
    const char *p = prefix ? prefix : "Python error";
    const char *d = detail ? detail : "";
    size_t cap = strlen(p) + strlen(d) * 2 + 64;
    char *buf = (char *)malloc(cap);
    if (!buf) return NULL;
    char *w = buf;
    w += sprintf(w, "{\"ok\":false,\"error\":\"");
    for (const char *s = p; *s; s++) {
        if (*s == '"' || *s == '\\') *w++ = '\\';
        *w++ = (*s == '\n' || *s == '\r') ? ' ' : *s;
    }
    if (*d) {
        *w++ = ':';
        *w++ = ' ';
        for (const char *s = d; *s; s++) {
            if (*s == '"' || *s == '\\') *w++ = '\\';
            *w++ = (*s == '\n' || *s == '\r') ? ' ' : *s;
        }
    }
    w += sprintf(w, "\"}");
    jbyteArray out = cstr_to_jbytes(env, buf, (Py_ssize_t)(w - buf));
    free(buf);
    return out;
}

static jbyteArray fetch_py_exception_jbytes(JNIEnv *env, const char *fallback) {
    PyObject *ptype = NULL, *pvalue = NULL, *ptrace = NULL;
    PyErr_Fetch(&ptype, &pvalue, &ptrace);
    PyErr_NormalizeException(&ptype, &pvalue, &ptrace);
    const char *msg = fallback;
    PyObject *str_obj = NULL;
    if (pvalue) {
        str_obj = PyObject_Str(pvalue);
        if (str_obj) {
            const char *utf8 = PyUnicode_AsUTF8(str_obj);
            if (utf8 && utf8[0]) msg = utf8;
        }
    }
    jbyteArray result = error_json_jbytes(env, "Python runtime exception", msg);
    Py_XDECREF(str_obj);
    Py_XDECREF(ptype);
    Py_XDECREF(pvalue);
    Py_XDECREF(ptrace);
    return result;
}

static PyObject *py_unicode_from_jbytes(JNIEnv *env, jbyteArray arr) {
    jsize len = 0;
    char *raw = jbytes_to_cstr(env, arr, &len);
    if (!raw) return PyErr_NoMemory();
    PyObject *obj = PyUnicode_DecodeUTF8(raw, (Py_ssize_t)len, "replace");
    free(raw);
    return obj;
}

static int append_wide_path(PyConfig *config, const char *utf8_path) {
    if (!utf8_path || !utf8_path[0]) return 0;
    wchar_t *wpath = Py_DecodeLocale(utf8_path, NULL);
    if (!wpath) return -1;
    PyStatus st = PyWideStringList_Append(&config->module_search_paths, wpath);
    PyMem_RawFree(wpath);
    return PyStatus_Exception(st) ? -1 : 0;
}

JNIEXPORT jbyteArray JNICALL
Java_com_pilipala_marcomovie_NativePythonEngine_nativeInit(
        JNIEnv *env,
        jclass cls,
        jbyteArray homeDir,
        jbyteArray stdlibZip,
        jbyteArray dynloadDir,
        jbyteArray siteDir,
        jbyteArray runnerDir,
        jbyteArray cacertPath) {
    (void)cls;
    pthread_mutex_lock(&g_init_lock);
    if (g_initialized) {
        pthread_mutex_unlock(&g_init_lock);
        return cstr_to_jbytes(env, "{\"ok\":true}", 11);
    }

    char *c_home = jbytes_to_cstr(env, homeDir, NULL);
    char *c_stdlib = jbytes_to_cstr(env, stdlibZip, NULL);
    char *c_dynload = jbytes_to_cstr(env, dynloadDir, NULL);
    char *c_site = jbytes_to_cstr(env, siteDir, NULL);
    char *c_runner = jbytes_to_cstr(env, runnerDir, NULL);
    char *c_cacert = jbytes_to_cstr(env, cacertPath, NULL);

    if (c_cacert && c_cacert[0]) {
        setenv("SSL_CERT_FILE", c_cacert, 1);
        setenv("REQUESTS_CA_BUNDLE", c_cacert, 1);
    }
    if (c_home && c_home[0]) {
        setenv("HOME", c_home, 1);
        setenv("TMPDIR", c_home, 1);
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.parse_argv = 0;
    config.module_search_paths_set = 1;

    int path_err = 0;
    path_err |= append_wide_path(&config, c_runner);
    path_err |= append_wide_path(&config, c_site);
    path_err |= append_wide_path(&config, c_stdlib);
    path_err |= append_wide_path(&config, c_dynload);

    jbyteArray out = NULL;
    if (path_err != 0) {
        PyConfig_Clear(&config);
        out = error_json_jbytes(env, "PyConfig path setup failed", "");
    } else {
        PyStatus status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            out = error_json_jbytes(env, "Py_InitializeFromConfig failed", status.err_msg);
        } else {
            g_runner_mod = PyImport_ImportModule("android_runner");
            if (!g_runner_mod) {
                out = fetch_py_exception_jbytes(env, "Failed to import android_runner");
                PyEval_SaveThread();
            } else {
                g_initialized = 1;
                PyEval_SaveThread();
                out = cstr_to_jbytes(env, "{\"ok\":true}", 11);
            }
        }
    }

    free(c_home);
    free(c_stdlib);
    free(c_dynload);
    free(c_site);
    free(c_runner);
    free(c_cacert);
    pthread_mutex_unlock(&g_init_lock);
    return out;
}

JNIEXPORT jbyteArray JNICALL
Java_com_pilipala_marcomovie_NativePythonEngine_nativeCall(
        JNIEnv *env,
        jclass cls,
        jbyteArray siteKey,
        jbyteArray scriptPath,
        jbyteArray extJson,
        jbyteArray proxyBase,
        jbyteArray methodName,
        jbyteArray argsJson) {
    (void)cls;
    if (!g_initialized || !g_runner_mod) {
        return error_json_jbytes(env, "Python runtime not initialized", "");
    }
    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *fn = PyObject_GetAttrString(g_runner_mod, "call_spider");
    if (!fn) {
        jbyteArray err = fetch_py_exception_jbytes(env, "Missing call_spider");
        PyGILState_Release(gstate);
        return err;
    }

    PyObject *a0 = py_unicode_from_jbytes(env, siteKey);
    PyObject *a1 = py_unicode_from_jbytes(env, scriptPath);
    PyObject *a2 = py_unicode_from_jbytes(env, extJson);
    PyObject *a3 = py_unicode_from_jbytes(env, proxyBase);
    PyObject *a4 = py_unicode_from_jbytes(env, methodName);
    PyObject *a5 = py_unicode_from_jbytes(env, argsJson);

    PyObject *ret = NULL;
    if (a0 && a1 && a2 && a3 && a4 && a5) {
        ret = PyObject_CallFunctionObjArgs(fn, a0, a1, a2, a3, a4, a5, NULL);
    }
    Py_XDECREF(a0);
    Py_XDECREF(a1);
    Py_XDECREF(a2);
    Py_XDECREF(a3);
    Py_XDECREF(a4);
    Py_XDECREF(a5);
    Py_DECREF(fn);

    jbyteArray out;
    if (!ret) {
        out = fetch_py_exception_jbytes(env, "call_spider failed");
    } else {
        Py_ssize_t len = 0;
        const char *utf8 = PyUnicode_AsUTF8AndSize(ret, &len);
        if (!utf8) {
            out = fetch_py_exception_jbytes(env, "Non-string call_spider result");
        } else {
            out = cstr_to_jbytes(env, utf8, len);
        }
        Py_DECREF(ret);
    }
    PyGILState_Release(gstate);
    return out;
}

JNIEXPORT jbyteArray JNICALL
Java_com_pilipala_marcomovie_NativePythonEngine_nativeProxy(
        JNIEnv *env,
        jclass cls,
        jbyteArray siteKey,
        jbyteArray paramsJson) {
    (void)cls;
    if (!g_initialized || !g_runner_mod) {
        return error_json_jbytes(env, "Python runtime not initialized", "");
    }
    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *fn = PyObject_GetAttrString(g_runner_mod, "call_proxy");
    if (!fn) {
        jbyteArray err = fetch_py_exception_jbytes(env, "Missing call_proxy");
        PyGILState_Release(gstate);
        return err;
    }

    PyObject *a0 = py_unicode_from_jbytes(env, siteKey);
    PyObject *a1 = py_unicode_from_jbytes(env, paramsJson);
    PyObject *ret = (a0 && a1) ? PyObject_CallFunctionObjArgs(fn, a0, a1, NULL) : NULL;
    Py_XDECREF(a0);
    Py_XDECREF(a1);
    Py_DECREF(fn);

    jbyteArray out;
    if (!ret) {
        out = fetch_py_exception_jbytes(env, "call_proxy failed");
    } else {
        Py_ssize_t len = 0;
        const char *utf8 = PyUnicode_AsUTF8AndSize(ret, &len);
        if (!utf8) {
            out = fetch_py_exception_jbytes(env, "Non-string call_proxy result");
        } else {
            out = cstr_to_jbytes(env, utf8, len);
        }
        Py_DECREF(ret);
    }
    PyGILState_Release(gstate);
    return out;
}

JNIEXPORT void JNICALL
Java_com_pilipala_marcomovie_NativePythonEngine_nativeRelease(
        JNIEnv *env,
        jclass cls,
        jbyteArray siteKey) {
    (void)cls;
    if (!g_initialized || !g_runner_mod) return;
    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *fn = PyObject_GetAttrString(g_runner_mod, "release_spider");
    if (fn) {
        PyObject *a0 = py_unicode_from_jbytes(env, siteKey);
        if (a0) {
            PyObject *ret = PyObject_CallFunctionObjArgs(fn, a0, NULL);
            Py_XDECREF(ret);
            Py_DECREF(a0);
        }
        Py_DECREF(fn);
    }
    PyErr_Clear();
    PyGILState_Release(gstate);
}
