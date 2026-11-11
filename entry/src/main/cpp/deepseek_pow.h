#ifndef DEEPSEEK_POW_H
#define DEEPSEEK_POW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 求解 DeepSeek PoW：找 n ∈ [0, difficulty) 使
 * DeepSeekHashV1(`salt_expireAt_n`) === challengeHex（64 位 hex 全等）。
 * 返回 >=0 命中的 n；-1 未找到；-2 参数/内部错误。
 */
int32_t solvePowNativeC(const char *salt, const char *challengeHex, int32_t difficulty, int64_t expireAt);

#ifdef __cplusplus
}
#endif

#endif /* DEEPSEEK_POW_H */
