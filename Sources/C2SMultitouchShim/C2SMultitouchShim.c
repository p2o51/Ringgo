#include "C2SMultitouchShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void *MTDeviceRef;
typedef void MTTouch;
typedef int (*MTContactCallback)(int, MTTouch *, int, double, int);
typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef MTDeviceRef (*MTDeviceCreateDefaultFn)(void);
typedef void (*MTRegisterFn)(MTDeviceRef, MTContactCallback);
typedef void (*MTUnregisterFn)(MTDeviceRef, MTContactCallback);
typedef void (*MTStartFn)(MTDeviceRef, int);
typedef void (*MTStopFn)(MTDeviceRef);

static const char *kFrameworkPath =
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

static void *g_handle = NULL;
static CFArrayRef g_devices = NULL;
static MTDeviceRef g_default_device = NULL;

static MTDeviceCreateListFn g_create_list = NULL;
static MTDeviceCreateDefaultFn g_create_default = NULL;
static MTRegisterFn g_register = NULL;
static MTUnregisterFn g_unregister = NULL;
static MTStartFn g_start = NULL;
static MTStopFn g_stop = NULL;

static C2SMTFrameHandler g_handler = NULL;
static void *g_context = NULL;
static char g_error[256] = {0};

static void set_error(const char *message) {
    if (!message) {
        g_error[0] = '\0';
        return;
    }
    snprintf(g_error, sizeof(g_error), "%s", message);
}

static int contact_callback(int device,
                            MTTouch *touches,
                            int finger_count,
                            double timestamp,
                            int frame) {
    (void)device;
    (void)touches;
    (void)frame;
    C2SMTFrameHandler handler = g_handler;
    if (handler) {
        handler((int32_t)finger_count, timestamp, g_context);
    }
    return 0;
}

static void clear_symbols(void) {
    g_create_list = NULL;
    g_create_default = NULL;
    g_register = NULL;
    g_unregister = NULL;
    g_start = NULL;
    g_stop = NULL;
}

static int load_symbols(void) {
    g_handle = dlopen(kFrameworkPath, RTLD_NOW | RTLD_LOCAL);
    if (!g_handle) {
        set_error(dlerror());
        return -1;
    }

    g_create_list = (MTDeviceCreateListFn)dlsym(g_handle, "MTDeviceCreateList");
    g_create_default =
        (MTDeviceCreateDefaultFn)dlsym(g_handle, "MTDeviceCreateDefault");
    g_register = (MTRegisterFn)dlsym(g_handle, "MTRegisterContactFrameCallback");
    g_unregister =
        (MTUnregisterFn)dlsym(g_handle, "MTUnregisterContactFrameCallback");
    g_start = (MTStartFn)dlsym(g_handle, "MTDeviceStart");
    g_stop = (MTStopFn)dlsym(g_handle, "MTDeviceStop");

    if (!g_register || !g_unregister || !g_start || !g_stop ||
        (!g_create_list && !g_create_default)) {
        set_error("当前 macOS 缺少必要的 MultitouchSupport 符号。");
        return -2;
    }
    return 0;
}

static void start_device(MTDeviceRef device) {
    if (!device) {
        return;
    }
    g_register(device, contact_callback);
    g_start(device, 0);
}

static void stop_device(MTDeviceRef device) {
    if (!device) {
        return;
    }
    g_stop(device);
    g_unregister(device, contact_callback);
}

int32_t C2SMTStart(C2SMTFrameHandler handler, void *context) {
    C2SMTStop();
    set_error(NULL);

    if (!handler) {
        set_error("三指触控回调为空。");
        return -3;
    }
    if (load_symbols() != 0) {
        C2SMTStop();
        return -4;
    }

    g_handler = handler;
    g_context = context;

    if (g_create_list) {
        g_devices = g_create_list();
    }
    CFIndex count = g_devices ? CFArrayGetCount(g_devices) : 0;
    if (count > 0) {
        for (CFIndex index = 0; index < count; index++) {
            start_device((MTDeviceRef)CFArrayGetValueAtIndex(g_devices, index));
        }
        return (int32_t)count;
    }

    if (g_create_default) {
        g_default_device = g_create_default();
    }
    if (g_default_device) {
        start_device(g_default_device);
        return 1;
    }

    set_error("未发现内建触控板或已连接的 Magic Trackpad。");
    C2SMTStop();
    return -5;
}

void C2SMTStop(void) {
    // 先让设备停止产帧，再清回调上下文，避免尾帧访问已释放的 Swift 对象。
    if (g_devices && g_stop && g_unregister) {
        CFIndex count = CFArrayGetCount(g_devices);
        for (CFIndex index = 0; index < count; index++) {
            stop_device((MTDeviceRef)CFArrayGetValueAtIndex(g_devices, index));
        }
    } else if (g_default_device && g_stop && g_unregister) {
        stop_device(g_default_device);
    }

    g_handler = NULL;
    g_context = NULL;
    g_default_device = NULL;

    if (g_devices) {
        CFRelease(g_devices);
        g_devices = NULL;
    }
    clear_symbols();
    if (g_handle) {
        dlclose(g_handle);
        g_handle = NULL;
    }
}

const char *C2SMTLastError(void) {
    return g_error;
}
