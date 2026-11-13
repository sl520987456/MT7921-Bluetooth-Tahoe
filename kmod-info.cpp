// 手工生成的 kmod_info + 启动/停止胶水（等价于 Xcode libkmod 的 startup.c）
// 用法: 编译时 -DKEXT_BUNDLE_ID='"com.xxx"' -DKEXT_VERSION='"1.0.0"'
//       Lilu 插件再加 -DKEXT_START_SYM=SimpleMtkBtPatcher_kern_start
//
// ★ 重大教训（三次启动卡死的根因）：
//   内核在加载 kext 时会【自动】执行 __mod_init_func 里的 C++ 构造函数
//   （Lilu 插件全靠这个机制注册，从不手动调用 OSRuntimeInitializeCPP）。
//   而且新内核 (xnu-12377) 的 OSRuntimeInitializeCPP 签名是 (OSKext*)，
//   旧 ABI 是 (kmod_info_t*, void*)。若在这里传 kmod_info 调它，
//   内核会把假指针当 OSKext 解引用 → 垃圾地址段扫描 → kext start 阶段挂死。
//   所以这里【绝不】调用 OSRuntimeInitializeCPP！start 只调 _realmain。
#include <mach/kmod.h>
#include <mach/mach_types.h>
#include <stdint.h>

#ifndef KEXT_BUNDLE_ID
#define KEXT_BUNDLE_ID "com.unknown.kext"
#endif
#ifndef KEXT_VERSION
#define KEXT_VERSION "1.0.0"
#endif

extern "C" {

#ifdef KEXT_START_SYM
// Lilu 插件：把 _realmain 接到 Lilu 生成的 kern_start
extern "C" kern_return_t KEXT_START_SYM(kmod_info_t *, void *);
kmod_start_func_t *_realmain = (kmod_start_func_t *)&KEXT_START_SYM;
#else
// 普通 IOKit kext：start 直接成功，构造函数由内核自动跑
kmod_start_func_t *_realmain = 0;
#endif
kmod_stop_func_t *_antimain = 0;

static kern_return_t mod_start(kmod_info_t *ki, void *data)
{
    if (_realmain)
        return (*_realmain)(ki, data);
    return KERN_SUCCESS;
}

static kern_return_t mod_stop(kmod_info_t *ki, void *data)
{
    if (_antimain)
        return (*_antimain)(ki, data);
    return KERN_SUCCESS;
}

__attribute__((visibility("default")))
kmod_info_t kmod_info = {
    nullptr,                       // next
    1,                             // info_version
    0,                             // id (内核加载时分配)
    KEXT_BUNDLE_ID,                // name
    KEXT_VERSION,                  // version
    -1,                            // reference_count
    nullptr,                       // reference_list
    0,                             // address
    0,                             // size
    0,                             // hdr_size
    &mod_start,                    // start  ← 不能是 NULL
    &mod_stop                      // stop   ← 不能是 NULL
};
}
