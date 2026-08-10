#ifndef CODEXBAR_CQUICKJS_HOST_H
#define CODEXBAR_CQUICKJS_HOST_H

#include "quickjs.h"
#include <stdbool.h>
#include <stdint.h>

typedef JSValue (*CQJSHostCallback)(
    void *opaque,
    JSContext *context,
    int32_t magic,
    int argc,
    JSValueConst *argv);

typedef struct CQJSWatchdog CQJSWatchdog;

CQJSWatchdog *CQJSWatchdogCreate(CQJSHostCallback callback, void *opaque);
void CQJSWatchdogDestroy(CQJSWatchdog *watchdog);
void CQJSWatchdogInstall(CQJSWatchdog *watchdog, JSRuntime *runtime, JSContext *context);
void CQJSWatchdogArm(CQJSWatchdog *watchdog, uint64_t timeout_milliseconds);
void CQJSWatchdogDisarm(CQJSWatchdog *watchdog);
void CQJSWatchdogInterrupt(CQJSWatchdog *watchdog);
bool CQJSWatchdogIsInterrupted(CQJSWatchdog *watchdog);

JSValue CQJSNewHostFunction(JSContext *context, int32_t magic, const char *name, int argument_count);
JSValue CQJSUndefined(void);
JSValue CQJSNull(void);
JSValue CQJSBool(bool value);
JSValue CQJSDupValue(JSContext *context, JSValueConst value);
void CQJSFreeValue(JSContext *context, JSValue value);
bool CQJSIsException(JSValueConst value);
bool CQJSIsUndefined(JSValueConst value);
bool CQJSIsNull(JSValueConst value);
bool CQJSIsString(JSValueConst value);
bool CQJSIsNumber(JSValueConst value);
bool CQJSIsObject(JSValueConst value);
JSValue CQJSThrowError(JSContext *context, const char *message);

// Lowercase spellings keep Clang's Swift importer from treating CQJS as a removable type prefix.
static inline CQJSWatchdog *cqjs_watchdog_create(CQJSHostCallback callback, void *opaque) {
    return CQJSWatchdogCreate(callback, opaque);
}
static inline void cqjs_watchdog_destroy(CQJSWatchdog *watchdog) { CQJSWatchdogDestroy(watchdog); }
static inline void cqjs_watchdog_install(CQJSWatchdog *watchdog, JSRuntime *runtime, JSContext *context) {
    CQJSWatchdogInstall(watchdog, runtime, context);
}
static inline void cqjs_watchdog_arm(CQJSWatchdog *watchdog, uint64_t timeout_milliseconds) {
    CQJSWatchdogArm(watchdog, timeout_milliseconds);
}
static inline void cqjs_watchdog_disarm(CQJSWatchdog *watchdog) { CQJSWatchdogDisarm(watchdog); }
static inline void cqjs_watchdog_interrupt(CQJSWatchdog *watchdog) { CQJSWatchdogInterrupt(watchdog); }
static inline bool cqjs_watchdog_is_interrupted(CQJSWatchdog *watchdog) {
    return CQJSWatchdogIsInterrupted(watchdog);
}
static inline JSValue cqjs_new_host_function(
    JSContext *context,
    int32_t magic,
    const char *name,
    int argument_count) {
    return CQJSNewHostFunction(context, magic, name, argument_count);
}
static inline JSValue cqjs_undefined(void) { return CQJSUndefined(); }
static inline JSValue cqjs_null(void) { return CQJSNull(); }
static inline JSValue cqjs_bool(bool value) { return CQJSBool(value); }
static inline JSValue cqjs_dup_value(JSContext *context, JSValueConst value) { return CQJSDupValue(context, value); }
static inline void cqjs_free_value(JSContext *context, JSValue value) { CQJSFreeValue(context, value); }
static inline bool cqjs_is_exception(JSValueConst value) { return CQJSIsException(value); }
static inline bool cqjs_is_undefined(JSValueConst value) { return CQJSIsUndefined(value); }
static inline bool cqjs_is_null(JSValueConst value) { return CQJSIsNull(value); }
static inline bool cqjs_is_string(JSValueConst value) { return CQJSIsString(value); }
static inline bool cqjs_is_number(JSValueConst value) { return CQJSIsNumber(value); }
static inline bool cqjs_is_object(JSValueConst value) { return CQJSIsObject(value); }
static inline JSValue cqjs_throw_error(JSContext *context, const char *message) {
    return CQJSThrowError(context, message);
}

#endif
