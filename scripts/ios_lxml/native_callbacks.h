/* Experiment only: the host probe owns the complete libxml2/libxslt usage.
 * A product build must link private native libraries before using this policy.
 * Install fixed C dispatchers once; Python registries/logs stay in owner state.
 */
#include <pthread.h>

static pthread_once_t mm_lxml_native_once = PTHREAD_ONCE_INIT;
static xmlExternalEntityLoader mm_lxml_original_entity_loader;
static xsltDocLoaderFunc mm_lxml_original_xslt_loader;

static void mm_lxml_initialize_native_once(void) {
    xmlInitParser();
    xsltInit();
    exsltRegisterAll();
    xmlThrDefIndentTreeOutput(1);
    xmlThrDefLineNumbersDefaultValue(1);
    mm_lxml_original_entity_loader = xmlGetExternalEntityLoader();
    mm_lxml_original_xslt_loader = xsltDocDefaultLoader;
    xmlSetExternalEntityLoader(__pyx_f_4lxml_5etree__local_resolver);
    xsltSetLoaderFunc(__pyx_f_4lxml_5etree__xslt_doc_loader);
    xsltSetGenericErrorFunc(NULL, (xmlGenericErrorFunc)__pyx_f_4lxml_5etree__receiveXSLTError);
}

static void mm_lxml_initialize_native(void) {
    pthread_once(&mm_lxml_native_once, mm_lxml_initialize_native_once);
}

static void mm_lxml_keep_entity_loader(xmlExternalEntityLoader loader) {
    assert(loader == __pyx_f_4lxml_5etree__local_resolver);
}

static void mm_lxml_keep_xslt_loader(xsltDocLoaderFunc loader) {
    assert(loader == __pyx_f_4lxml_5etree__xslt_doc_loader);
}

static void mm_lxml_keep_xslt_error(void *context, xmlGenericErrorFunc callback) {
    assert(context == NULL);
    assert(callback == (xmlGenericErrorFunc)__pyx_f_4lxml_5etree__receiveXSLTError);
}

#define xmlInitParser() mm_lxml_initialize_native()
#define exsltRegisterAll() mm_lxml_initialize_native()
#define xmlThrDefIndentTreeOutput(value) ((void)0)
#define xmlThrDefLineNumbersDefaultValue(value) ((void)0)
#define xmlSetExternalEntityLoader(loader) mm_lxml_keep_entity_loader(loader)
#define xsltSetLoaderFunc(loader) mm_lxml_keep_xslt_loader(loader)
#define xsltSetGenericErrorFunc(context, callback) mm_lxml_keep_xslt_error(context, callback)
