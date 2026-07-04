#ifndef C2S_MULTITOUCH_SHIM_H
#define C2S_MULTITOUCH_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 私有 MultitouchSupport 帧回调的稳定最小投影。
/// 只转发独立参数 finger_count / timestamp，绝不暴露跨系统易变的 MTTouch 布局。
typedef void (*C2SMTFrameHandler)(int32_t finger_count,
                                  double timestamp,
                                  void *context);

/// 运行时加载私有框架、枚举并启动全部触控板。
/// 成功返回设备数；失败返回负数，并可用 C2SMTLastError() 取得说明。
int32_t C2SMTStart(C2SMTFrameHandler handler, void *context);

/// 停止设备、注销回调并卸载私有框架。可重复调用。
void C2SMTStop(void);

/// 最近一次启动失败的静态 UTF-8 错误串；下次 C2SMTStart 会覆盖。
const char *C2SMTLastError(void);

#ifdef __cplusplus
}
#endif

#endif
