/* Shared own-GIL acceptance harness. The embedding host owns Python startup. */
#include <Python.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Darwin has no pthread_barrier_t. This reusable two-owner barrier also lets
   failures release a peer instead of stranding its interpreter indefinitely. */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned waiting, generation;
    int broken;
} OwnerBarrier;

static OwnerBarrier phase = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0, 0};
static PyInterpreterState *main_interpreter;
static pthread_mutex_t closed_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t closed_condition = PTHREAD_COND_INITIALIZER;
static int first_closed;
static const char *package_path;
static const char *fixture_path;

typedef struct {
    const char *label;
    int peer, failed, created, destroyed, after_peer_closed;
    long long interpreter;
    long assertions;
    char *runs[2];
    int run_count;
} Owner;

static void break_barrier(void) {
    pthread_mutex_lock(&phase.mutex);
    phase.broken = 1;
    pthread_cond_broadcast(&phase.condition);
    pthread_mutex_unlock(&phase.mutex);
}

static int meet_peer(void) {
    pthread_mutex_lock(&phase.mutex);
    unsigned generation = phase.generation;
    if (!phase.broken && ++phase.waiting == 2) {
        phase.waiting = 0;
        ++phase.generation;
        pthread_cond_broadcast(&phase.condition);
    } else {
        while (!phase.broken && generation == phase.generation)
            pthread_cond_wait(&phase.condition, &phase.mutex);
    }
    int failed = phase.broken;
    pthread_mutex_unlock(&phase.mutex);
    return failed;
}

static void notify_closed(Owner *owner) {
    if (owner->peer == 1) {
        pthread_mutex_lock(&closed_mutex);
        first_closed = owner->destroyed ? 1 : -1;
        pthread_cond_broadcast(&closed_condition);
        pthread_mutex_unlock(&closed_mutex);
    }
}

static int exercise(PyObject *globals, Owner *owner, int iterations) {
    PyObject *callable = PyDict_GetItemString(globals, "exercise_details");
    PyObject *result = callable ? PyObject_CallFunction(callable, "si", owner->label, iterations) : NULL;
    PyObject *json = NULL, *encoded = NULL;
    if (!result || !PyDict_Check(result)) goto failed;
    PyObject *count = PyDict_GetItemString(result, "assertions");
    long checks = count ? PyLong_AsLong(count) : -1;
    if (checks != iterations * 13 || PyErr_Occurred()) goto failed;
    json = PyImport_ImportModule("json");
    encoded = json ? PyObject_CallMethod(json, "dumps", "O", result) : NULL;
    const char *text = encoded ? PyUnicode_AsUTF8(encoded) : NULL;
    if (!text || owner->run_count >= 2) goto failed;
    size_t size = strlen(text) + 1;
    char *copy = malloc(size);
    if (!copy) { PyErr_NoMemory(); goto failed; }
    memcpy(copy, text, size);
    owner->runs[owner->run_count++] = copy;
    owner->assertions += checks;
    Py_DECREF(encoded); Py_DECREF(json); Py_DECREF(result);
    printf("{\"event\":\"exercise\",\"owner\":\"%s\",\"checks\":%ld}\n", owner->label, checks);
    fflush(stdout);
    return 0;
failed:
    if (PyErr_Occurred()) PyErr_Print();
    Py_XDECREF(encoded); Py_XDECREF(json); Py_XDECREF(result);
    return -1;
}

static void *run_owner(void *argument) {
    Owner *owner = argument;
    PyThreadState *bootstrap = PyThreadState_New(main_interpreter);
    if (!bootstrap) { owner->failed = 1; break_barrier(); notify_closed(owner); return NULL; }
    PyThreadState_Swap(bootstrap);
    PyInterpreterConfig config = {
        .use_main_obmalloc = 0, .allow_fork = 0, .allow_exec = 0,
        .allow_threads = 0, .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1, .gil = PyInterpreterConfig_OWN_GIL,
    };
    PyThreadState *state = NULL;
    PyStatus status = Py_NewInterpreterFromConfig(&state, &config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "Owner %s initialization failed: %s\n", owner->label,
                status.err_msg ? status.err_msg : "unknown Python initialization error");
        owner->failed = 1;
        break_barrier();
        goto release_bootstrap;
    }
    owner->created = 1;
    owner->interpreter = PyInterpreterState_GetID(PyThreadState_GetInterpreter(state));
    printf("{\"event\":\"created\",\"owner\":\"%s\",\"interpreter\":%lld}\n",
           owner->label, owner->interpreter);
    fflush(stdout);
    PyObject *path = PyUnicode_FromString(package_path);
    PyObject *globals = PyDict_New();
    if (!path || !globals || PyList_Insert(PySys_GetObject("path"), 0, path) < 0 ||
            PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins()) < 0) {
        owner->failed = 1;
        if (PyErr_Occurred()) PyErr_Print();
        break_barrier();
    }
    Py_XDECREF(path);
    if (owner->peer) {
        state = PyEval_SaveThread();
        if (meet_peer()) owner->failed = 1;
        PyEval_RestoreThread(state);
    }
    if (!owner->failed) {
        FILE *fixture = fopen(fixture_path, "rb");
        PyObject *loaded = fixture ? PyRun_FileEx(fixture, fixture_path, Py_file_input, globals, globals, 1) : NULL;
        if (!loaded) {
            if (PyErr_Occurred()) PyErr_Print();
            else fprintf(stderr, "Could not open owner fixture: %s\n", fixture_path);
            owner->failed = 1;
        }
        Py_XDECREF(loaded);
    }
    if (!owner->failed && exercise(globals, owner, 10)) owner->failed = 1;
    if (owner->peer) {
        state = PyEval_SaveThread();
        if (meet_peer()) owner->failed = 1;
        PyEval_RestoreThread(state);
    }
    if (owner->peer == 2) {
        state = PyEval_SaveThread();
        pthread_mutex_lock(&closed_mutex);
        while (!first_closed) pthread_cond_wait(&closed_condition, &closed_mutex);
        owner->after_peer_closed = first_closed == 1;
        pthread_mutex_unlock(&closed_mutex);
        PyEval_RestoreThread(state);
        if (!owner->after_peer_closed || (!owner->failed && exercise(globals, owner, 20))) owner->failed = 1;
    }
    Py_XDECREF(globals);
    Py_EndInterpreter(state);
    owner->destroyed = 1;
release_bootstrap:
    PyThreadState_Swap(bootstrap);
    PyThreadState_Clear(bootstrap);
    PyThreadState_DeleteCurrent();
    printf("{\"event\":\"destroyed\",\"owner\":\"%s\",\"ok\":%s}\n",
           owner->label, owner->destroyed && !owner->failed ? "true" : "false");
    fflush(stdout);
    notify_closed(owner);
    return NULL;
}

/* Called once by an attached embedding thread. Cross-interpreter transport is
   UTF-8 JSON only; no Python objects are shared or retained after owner exit. */
PyObject *run_owners(const char *packages, const char *fixture) {
    package_path = packages; fixture_path = fixture;
    first_closed = 0; phase.waiting = 0; phase.generation = 0; phase.broken = 0;
    main_interpreter = PyInterpreterState_Get();
    PyThreadState *saved = PyEval_SaveThread();
    Owner owners[3] = {{.label="alpha", .peer=1, .interpreter=-1},
                       {.label="beta", .peer=2, .interpreter=-1},
                       {.label="reopened", .peer=0, .interpreter=-1}};
    pthread_t a, b, c;
    int started_a = pthread_create(&a, NULL, run_owner, &owners[0]) == 0;
    int started_b = pthread_create(&b, NULL, run_owner, &owners[1]) == 0;
    if (!started_a || !started_b) {
        break_barrier();
        if (!started_a) { owners[0].failed = 1; notify_closed(&owners[0]); }
        if (!started_b) owners[1].failed = 1;
    }
    if (started_a) pthread_join(a, NULL);
    if (started_b) pthread_join(b, NULL);
    int started_c = pthread_create(&c, NULL, run_owner, &owners[2]) == 0;
    if (started_c) pthread_join(c, NULL); else owners[2].failed = 1;
    PyEval_RestoreThread(saved);
    PyObject *records = PyList_New(0), *json = PyImport_ImportModule("json"), *report = NULL;
    int failed = !records || !json || !owners[1].after_peer_closed;
    long assertions = 0;
    for (int index = 0; index < 3; ++index) {
        Owner *owner = &owners[index];
        assertions += owner->assertions;
        failed |= owner->failed || !owner->created || !owner->destroyed;
        for (int previous = 0; previous < index; ++previous)
            failed |= owner->interpreter == owners[previous].interpreter;
        PyObject *runs = PyList_New(0);
        for (int run = 0; run < owner->run_count; ++run) {
            PyObject *details = json ? PyObject_CallMethod(json, "loads", "s", owner->runs[run]) : NULL;
            if (!details || !runs || PyList_Append(runs, details) < 0) failed = 1;
            Py_XDECREF(details); free(owner->runs[run]);
        }
        PyObject *entry = runs ? Py_BuildValue("{s:s,s:L,s:O,s:O,s:O,s:l,s:O}",
            "owner", owner->label, "interpreter", owner->interpreter,
            "created", owner->created ? Py_True : Py_False,
            "destroyed", owner->destroyed ? Py_True : Py_False,
            "passed", !owner->failed && owner->created && owner->destroyed ? Py_True : Py_False,
            "assertions", owner->assertions, "runs", runs) : NULL;
        if (!entry || !records || PyList_Append(records, entry) < 0) failed = 1;
        Py_XDECREF(entry); Py_XDECREF(runs);
    }
    if (!PyErr_Occurred() && records) report = Py_BuildValue("{s:O,s:O,s:l,s:O,s:s}",
        "passed", !failed && assertions == 650 ? Py_True : Py_False,
        "owners", records, "assertions", assertions,
        "peer_used_after_alpha_destroyed", owners[1].after_peer_closed ? Py_True : Py_False,
        "gil", "OWN_GIL");
    Py_XDECREF(records); Py_XDECREF(json);
    return report;
}

#ifndef MM_LXML_EMBEDDED
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    Py_Initialize();
    PyObject *report = run_owners(argv[1], argv[2]);
    int failed = !report || PyDict_GetItemString(report, "passed") != Py_True;
    if (PyErr_Occurred()) PyErr_Print();
    Py_XDECREF(report);
    if (Py_FinalizeEx() != 0) failed = 1;
    printf("{\"event\":\"completed\",\"ok\":%s}\n", failed ? "false" : "true");
    return failed ? 1 : 0;
}
#endif
