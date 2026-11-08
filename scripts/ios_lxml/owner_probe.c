/* Own-GIL host acceptance stage, deliberately separate from the iOS runtime. */
#include <Python.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static PyInterpreterState *main_interpreter;
static pthread_barrier_t phase;
static pthread_mutex_t closed_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t closed_condition = PTHREAD_COND_INITIALIZER;
static int first_closed;
static const char *package_path;
static const char *fixture_path;

typedef struct {
    const char *label;
    int peer;
    int failed;
    long long interpreter;
} Owner;

static int exercise(PyObject *globals, const char *label, int iterations) {
    PyObject *callable = PyDict_GetItemString(globals, "exercise");
    PyObject *result = callable ? PyObject_CallFunction(callable, "si", label, iterations) : NULL;
    if (!result) {
        PyErr_Print();
        return -1;
    }
    long checks = PyLong_AsLong(result);
    Py_DECREF(result);
    if (checks < 1 || PyErr_Occurred()) { PyErr_Print(); return -1; }
    printf("{\"event\":\"exercise\",\"owner\":\"%s\",\"checks\":%ld}\n", label, checks);
    fflush(stdout);
    return 0;
}

static void *run_owner(void *argument) {
    Owner *owner = argument;
    PyThreadState *bootstrap = PyThreadState_New(main_interpreter);
    if (!bootstrap) abort();
    PyThreadState_Swap(bootstrap);
    PyInterpreterConfig config = {
        .use_main_obmalloc = 0, .allow_fork = 0, .allow_exec = 0,
        .allow_threads = 0, .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1, .gil = PyInterpreterConfig_OWN_GIL,
    };
    PyThreadState *state = NULL;
    PyStatus status = Py_NewInterpreterFromConfig(&state, &config);
    if (PyStatus_Exception(status)) Py_ExitStatusException(status);
    owner->interpreter = PyInterpreterState_GetID(PyThreadState_GetInterpreter(state));
    printf("{\"event\":\"created\",\"owner\":\"%s\",\"interpreter\":%lld}\n",
           owner->label, owner->interpreter);
    fflush(stdout);
    PyObject *path = PyUnicode_FromString(package_path);
    if (!path || PyList_Insert(PySys_GetObject("path"), 0, path)) abort();
    Py_DECREF(path);
    PyObject *globals = PyDict_New();
    PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
    FILE *fixture = fopen(fixture_path, "rb");
    if (!fixture) abort();
    if (owner->peer) {
        state = PyEval_SaveThread();
        pthread_barrier_wait(&phase);
        PyEval_RestoreThread(state);
    }
    PyObject *loaded = PyRun_FileEx(fixture, fixture_path, Py_file_input, globals, globals, 1);
    if (!loaded) { PyErr_Print(); owner->failed = 1; }
    Py_XDECREF(loaded);
    if (!owner->failed && exercise(globals, owner->label, 10)) owner->failed = 1;
    if (owner->peer) {
        state = PyEval_SaveThread();
        pthread_barrier_wait(&phase);
        PyEval_RestoreThread(state);
    }
    if (owner->peer == 2) {
        state = PyEval_SaveThread();
        pthread_mutex_lock(&closed_mutex);
        while (!first_closed) pthread_cond_wait(&closed_condition, &closed_mutex);
        pthread_mutex_unlock(&closed_mutex);
        PyEval_RestoreThread(state);
        if (!owner->failed && exercise(globals, owner->label, 20)) owner->failed = 1;
    }
    Py_DECREF(globals);
    Py_EndInterpreter(state);
    PyThreadState_Swap(bootstrap);
    PyThreadState_Clear(bootstrap);
    PyThreadState_DeleteCurrent();
    printf("{\"event\":\"destroyed\",\"owner\":\"%s\",\"ok\":%s}\n",
           owner->label, owner->failed ? "false" : "true");
    fflush(stdout);
    if (owner->peer == 1) {
        pthread_mutex_lock(&closed_mutex);
        first_closed = 1;
        pthread_cond_signal(&closed_condition);
        pthread_mutex_unlock(&closed_mutex);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    package_path = argv[1]; fixture_path = argv[2];
    Py_Initialize();
    main_interpreter = PyInterpreterState_Get();
    PyThreadState *saved = PyEval_SaveThread();
    pthread_barrier_init(&phase, NULL, 2);
    Owner first = {"alpha", 1, 0, 0}, second = {"beta", 2, 0, 0}, reopened = {"reopened", 0, 0, 0};
    pthread_t a, b, c;
    pthread_create(&a, NULL, run_owner, &first);
    pthread_create(&b, NULL, run_owner, &second);
    pthread_join(a, NULL); pthread_join(b, NULL);
    pthread_create(&c, NULL, run_owner, &reopened); pthread_join(c, NULL);
    pthread_barrier_destroy(&phase);
    PyEval_RestoreThread(saved);
    int finalized = Py_FinalizeEx();
    int failed = first.failed || second.failed || reopened.failed || finalized != 0 ||
        first.interpreter == second.interpreter || first.interpreter == reopened.interpreter ||
        second.interpreter == reopened.interpreter;
    printf("{\"event\":\"completed\",\"ok\":%s}\n", failed ? "false" : "true");
    return failed ? 1 : 0;
}
