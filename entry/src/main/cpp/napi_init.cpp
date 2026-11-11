#include "napi/native_api.h"
#include "deepseek_pow.h"

#include <string.h>

/*
 * 原生 PoW 求解（同步接口，调用方在 taskpool 线程执行）。
 * 参数：salt, challenge(64 hex), difficulty, expireAt（秒级时间戳）。
 * 返回：>=0 命中的 n；-1 未找到；-2 参数/内部错误（ArkTS 侧回退纯 TS 求解）。
 */
static napi_value SolvePow(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc != 4) {
        napi_throw_error(env, nullptr, "solvePowNative expects 4 arguments");
        return nullptr;
    }

    char salt[256];
    size_t saltLen = 0;
    status = napi_get_value_string_utf8(env, args[0], salt, sizeof(salt), &saltLen);
    if (status != napi_ok || saltLen == 0 || saltLen >= sizeof(salt)) {
        napi_throw_error(env, nullptr, "invalid salt");
        return nullptr;
    }

    char challenge[128];
    size_t challengeLen = 0;
    status = napi_get_value_string_utf8(env, args[1], challenge, sizeof(challenge), &challengeLen);
    if (status != napi_ok || challengeLen != 64) {
        napi_throw_error(env, nullptr, "invalid challenge");
        return nullptr;
    }

    int32_t difficulty = 0;
    status = napi_get_value_int32(env, args[2], &difficulty);
    if (status != napi_ok || difficulty <= 0) {
        napi_throw_error(env, nullptr, "invalid difficulty");
        return nullptr;
    }

    int64_t expireAt = 0;
    status = napi_get_value_int64(env, args[3], &expireAt);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "invalid expireAt");
        return nullptr;
    }

    int32_t answer = solvePowNativeC(salt, challenge, difficulty, expireAt);

    napi_value result = nullptr;
    napi_create_int32(env, answer, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "solvePowNative", nullptr, SolvePow, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module powModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&powModule);
}
