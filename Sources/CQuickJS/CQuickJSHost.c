#include "CQuickJSHost.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

struct CQJSWatchdog {
    CQJSHostCallback callback;
    void *opaque;
    _Atomic bool interrupted;
    _Atomic uint64_t deadline_nanoseconds;
};

static uint64_t CQJSMonotonicNanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static int CQJSInterruptHandler(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    CQJSWatchdog *watchdog = opaque;
    if (atomic_load_explicit(&watchdog->interrupted, memory_order_relaxed)) {
        return 1;
    }
    uint64_t deadline = atomic_load_explicit(&watchdog->deadline_nanoseconds, memory_order_relaxed);
    return deadline != 0 && CQJSMonotonicNanoseconds() >= deadline;
}

static JSValue CQJSHostDispatcher(
    JSContext *context,
    JSValueConst this_value,
    int argc,
    JSValueConst *argv,
    int magic) {
    (void)this_value;
    CQJSWatchdog *watchdog = JS_GetContextOpaque(context);
    if (watchdog == NULL || watchdog->callback == NULL) {
        return JS_ThrowInternalError(context, "QuickJS host context is unavailable");
    }
    return watchdog->callback(watchdog->opaque, context, magic, argc, argv);
}

CQJSWatchdog *CQJSWatchdogCreate(CQJSHostCallback callback, void *opaque) {
    CQJSWatchdog *watchdog = calloc(1, sizeof(*watchdog));
    if (watchdog == NULL) {
        return NULL;
    }
    watchdog->callback = callback;
    watchdog->opaque = opaque;
    atomic_init(&watchdog->interrupted, false);
    atomic_init(&watchdog->deadline_nanoseconds, 0);
    return watchdog;
}

void CQJSWatchdogDestroy(CQJSWatchdog *watchdog) {
    free(watchdog);
}

void CQJSWatchdogInstall(CQJSWatchdog *watchdog, JSRuntime *runtime, JSContext *context) {
    JS_SetContextOpaque(context, watchdog);
    JS_SetInterruptHandler(runtime, CQJSInterruptHandler, watchdog);
}

void CQJSWatchdogArm(CQJSWatchdog *watchdog, uint64_t timeout_milliseconds) {
    atomic_store_explicit(&watchdog->interrupted, false, memory_order_relaxed);
    uint64_t timeout_nanoseconds = timeout_milliseconds * UINT64_C(1000000);
    atomic_store_explicit(
        &watchdog->deadline_nanoseconds,
        CQJSMonotonicNanoseconds() + timeout_nanoseconds,
        memory_order_relaxed);
}

void CQJSWatchdogDisarm(CQJSWatchdog *watchdog) {
    atomic_store_explicit(&watchdog->deadline_nanoseconds, 0, memory_order_relaxed);
    atomic_store_explicit(&watchdog->interrupted, false, memory_order_relaxed);
}

void CQJSWatchdogInterrupt(CQJSWatchdog *watchdog) {
    atomic_store_explicit(&watchdog->interrupted, true, memory_order_relaxed);
}

bool CQJSWatchdogIsInterrupted(CQJSWatchdog *watchdog) {
    return atomic_load_explicit(&watchdog->interrupted, memory_order_relaxed);
}

JSValue CQJSNewHostFunction(JSContext *context, int32_t magic, const char *name, int argument_count) {
    return JS_NewCFunctionMagic(context, CQJSHostDispatcher, name, argument_count, JS_CFUNC_generic_magic, magic);
}

JSValue CQJSUndefined(void) {
    return JS_UNDEFINED;
}

JSValue CQJSNull(void) {
    return JS_NULL;
}

JSValue CQJSBool(bool value) {
    return JS_MKVAL(JS_TAG_BOOL, value);
}

JSValue CQJSDupValue(JSContext *context, JSValueConst value) {
    return JS_DupValue(context, value);
}

void CQJSFreeValue(JSContext *context, JSValue value) {
    JS_FreeValue(context, value);
}

bool CQJSIsException(JSValueConst value) {
    return JS_IsException(value);
}

bool CQJSIsUndefined(JSValueConst value) {
    return JS_IsUndefined(value);
}

bool CQJSIsNull(JSValueConst value) {
    return JS_IsNull(value);
}

bool CQJSIsString(JSValueConst value) {
    return JS_IsString(value);
}

bool CQJSIsNumber(JSValueConst value) {
    return JS_IsNumber(value);
}

bool CQJSIsObject(JSValueConst value) {
    return JS_IsObject(value);
}

JSValue CQJSThrowError(JSContext *context, const char *message) {
    return JS_ThrowInternalError(context, "%s", message);
}
