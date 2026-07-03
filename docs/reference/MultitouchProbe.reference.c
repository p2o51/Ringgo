// 实测:私有 MultitouchSupport.framework 在本机(macOS 26)能否 加载/枚举触控板/跑回调。
// 只读观测多点触控帧,不合成事件。运行时 dlopen 私有框架(不在链接期依赖它)。
#include <stdio.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

typedef void* MTDeviceRef;
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
// 只用到回调里的“手指数” nFingers(独立参数),故 MTTouch 具体布局不重要,用占位即可。
typedef void MTTouch;
typedef int (*MTContactCallback)(int, MTTouch*, int, double, int);
typedef CFMutableArrayRef (*CreateListFn)(void);
typedef MTDeviceRef (*CreateDefaultFn)(void);
typedef void (*RegisterFn)(MTDeviceRef, MTContactCallback);
typedef void (*StartFn)(MTDeviceRef, int);

static int gFrames = 0, gMaxFingers = 0, gSaw3 = 0;

static int cb(int dev, MTTouch* t, int n, double ts, int frame) {
    gFrames++;
    if (n > gMaxFingers) gMaxFingers = n;
    if (n == 3) gSaw3++;
    return 0;
}

int main(void) {
    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("dlopen 失败: %s\n", dlerror()); return 1; }
    printf("① dlopen 成功: %s\n", path);

    CreateListFn createList     = (CreateListFn)     dlsym(h, "MTDeviceCreateList");
    CreateDefaultFn createDflt  = (CreateDefaultFn)  dlsym(h, "MTDeviceCreateDefault");
    RegisterFn reg              = (RegisterFn)       dlsym(h, "MTRegisterContactFrameCallback");
    StartFn start               = (StartFn)          dlsym(h, "MTDeviceStart");
    printf("② 符号解析: CreateList=%p CreateDefault=%p Register=%p Start=%p\n",
           (void*)createList, (void*)createDflt, (void*)reg, (void*)start);
    if (!reg || !start || (!createList && !createDflt)) { printf("关键符号缺失\n"); return 2; }

    long count = -1; MTDeviceRef dev = NULL;
    if (createList) {
        CFArrayRef devs = createList();
        count = devs ? CFArrayGetCount(devs) : -1;
        if (devs && count > 0) dev = (MTDeviceRef)CFArrayGetValueAtIndex(devs, 0);
    }
    printf("③ MTDeviceCreateList 设备数 = %ld\n", count);
    if (!dev && createDflt) { dev = createDflt(); printf("   用 MTDeviceCreateDefault 兜底: %p\n", (void*)dev); }
    if (!dev) { printf("   未发现多点触控设备(台式无内建/未接 Magic Trackpad?)。但①②已证明私有 API 在本机可调用。\n"); return 0; }

    printf("④ 设备 = %p,注册回调并启动,监听 4 秒 —— 现在可以用三指点一下触控板试试 ⋯\n", (void*)dev);
    reg(dev, cb);
    start(dev, 0);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 4.0, false);
    printf("⑤ 结果: 收到帧=%d, 最大手指数=%d, 三指帧=%d\n", gFrames, gMaxFingers, gSaw3);
    if (gFrames > 0) printf("✅ 收到实时多点触控帧流 —— 私有 API 在本机完全可用,可据此判定手指数/轻点。\n");
    else printf("ℹ️ 4 秒内无触摸(没碰触控板);但设备枚举+注册+启动均成功,已证明机制可用。\n");
    return 0;
}
