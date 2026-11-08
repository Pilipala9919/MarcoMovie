/* Experimental generated-C support. Included after __pyx_mstatetype exists.
 * No PyGILState automatic attachment: native callbacks retain their owner.
 * This is not used by the product runtime.
 */
#include <assert.h>

static _Thread_local PyThreadState *mm_lxml_detached_owner;
static _Thread_local __pyx_mstatetype *mm_lxml_detached_module;

static __pyx_mstatetype *mm_lxml_module_state(void) {
    if (PyThreadState_GetUnchecked()) {
        return __Pyx_PyModule_GetState(__Pyx_State_FindModule(&__pyx_moduledef));
    }
    assert(mm_lxml_detached_owner && mm_lxml_detached_module);
    return mm_lxml_detached_module;
}

static PyThreadState *mm_lxml_save_thread(void) {
    mm_lxml_detached_module = mm_lxml_module_state();
    mm_lxml_detached_owner = PyEval_SaveThread();
    return mm_lxml_detached_owner;
}

static void mm_lxml_restore_thread(PyThreadState *owner) {
    PyEval_RestoreThread(owner);
    mm_lxml_detached_owner = owner;
    mm_lxml_detached_module = mm_lxml_module_state();
}

static PyGILState_STATE mm_lxml_ensure_owner(void) {
    PyThreadState *attached = PyThreadState_GetUnchecked();
    if (attached) {
        mm_lxml_detached_owner = attached;
        return PyGILState_LOCKED;
    }
    /* A foreign native thread must not silently attach to the main interpreter.
     * Every tested callback has to originate inside a scoped lxml operation.
     */
    assert(mm_lxml_detached_owner);
    mm_lxml_restore_thread(mm_lxml_detached_owner);
    return PyGILState_UNLOCKED;
}

static void mm_lxml_release_owner(PyGILState_STATE previous) {
    if (previous == PyGILState_UNLOCKED) {
        (void)mm_lxml_save_thread();
    }
}

#undef __pyx_mstate_global
#define __pyx_mstate_global mm_lxml_module_state()
#define PyEval_SaveThread() mm_lxml_save_thread()
#define PyEval_RestoreThread(owner) mm_lxml_restore_thread(owner)
#define PyGILState_Ensure() mm_lxml_ensure_owner()
#define PyGILState_Release(previous) mm_lxml_release_owner(previous)
