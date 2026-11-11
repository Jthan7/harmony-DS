/*
 * DeepSeekHashV1 原生求解器（C 移植，与 ArkTS DeepSeekHash.ets 逐行对应）。
 * 算法：SHA3-256 填充（pad 0x06，rate=136，输出 32 字节），
 * keccak-f[1600] 跳过 round 0（仅执行 rounds 1..23），32 位字实现（50 words）。
 * 返回值：>=0 命中的 n；-1 未找到；-2 参数/内部错误（调用方回退 ArkTS 求解）。
 */
#include "deepseek_pow.h"

#include <stdint.h>
#include <stddef.h>
#include <string.h>

static const uint32_t RC[48] = {
    1u, 0u, 32898u, 0u, 32906u, 2147483648u, 2147516416u, 2147483648u, 32907u, 0u, 2147483649u,
    0u, 2147516545u, 2147483648u, 32777u, 2147483648u, 138u, 0u, 136u, 0u, 2147516425u, 0u,
    2147483658u, 0u, 2147516555u, 0u, 139u, 2147483648u, 32905u, 2147483648u, 32771u,
    2147483648u, 32770u, 2147483648u, 128u, 2147483648u, 32778u, 0u, 2147483658u, 2147483648u,
    2147516545u, 2147483648u, 32896u, 2147483648u, 2147483649u, 0u, 2147516424u, 2147483648u
};

static void keccakF(uint32_t s[50])
{
    uint32_t h = 0;
    uint32_t l = 0;
    uint32_t n = 0;
    uint32_t c0 = 0;
    uint32_t c1 = 0;
    uint32_t c2 = 0;
    uint32_t c3 = 0;
    uint32_t c4 = 0;
    uint32_t c5 = 0;
    uint32_t c6 = 0;
    uint32_t c7 = 0;
    uint32_t c8 = 0;
    uint32_t c9 = 0;
    uint32_t b0 = 0;
    uint32_t b1 = 0;
    uint32_t b2 = 0;
    uint32_t b3 = 0;
    uint32_t b4 = 0;
    uint32_t b5 = 0;
    uint32_t b6 = 0;
    uint32_t b7 = 0;
    uint32_t b8 = 0;
    uint32_t b9 = 0;
    uint32_t b10 = 0;
    uint32_t b11 = 0;
    uint32_t b12 = 0;
    uint32_t b13 = 0;
    uint32_t b14 = 0;
    uint32_t b15 = 0;
    uint32_t b16 = 0;
    uint32_t b17 = 0;
    uint32_t b18 = 0;
    uint32_t b19 = 0;
    uint32_t b20 = 0;
    uint32_t b21 = 0;
    uint32_t b22 = 0;
    uint32_t b23 = 0;
    uint32_t b24 = 0;
    uint32_t b25 = 0;
    uint32_t b26 = 0;
    uint32_t b27 = 0;
    uint32_t b28 = 0;
    uint32_t b29 = 0;
    uint32_t b30 = 0;
    uint32_t b31 = 0;
    uint32_t b32 = 0;
    uint32_t b33 = 0;
    uint32_t b34 = 0;
    uint32_t b35 = 0;
    uint32_t b36 = 0;
    uint32_t b37 = 0;
    uint32_t b38 = 0;
    uint32_t b39 = 0;
    uint32_t b40 = 0;
    uint32_t b41 = 0;
    uint32_t b42 = 0;
    uint32_t b43 = 0;
    uint32_t b44 = 0;
    uint32_t b45 = 0;
    uint32_t b46 = 0;
    uint32_t b47 = 0;
    uint32_t b48 = 0;
    uint32_t b49 = 0;
    for (n = 2; n < 48; n += 2) {
        c0 = s[0] ^ s[10] ^ s[20] ^ s[30] ^ s[40];
        c1 = s[1] ^ s[11] ^ s[21] ^ s[31] ^ s[41];
        c2 = s[2] ^ s[12] ^ s[22] ^ s[32] ^ s[42];
        c3 = s[3] ^ s[13] ^ s[23] ^ s[33] ^ s[43];
        c4 = s[4] ^ s[14] ^ s[24] ^ s[34] ^ s[44];
        c5 = s[5] ^ s[15] ^ s[25] ^ s[35] ^ s[45];
        c6 = s[6] ^ s[16] ^ s[26] ^ s[36] ^ s[46];
        c7 = s[7] ^ s[17] ^ s[27] ^ s[37] ^ s[47];
        c8 = s[8] ^ s[18] ^ s[28] ^ s[38] ^ s[48];
        c9 = s[9] ^ s[19] ^ s[29] ^ s[39] ^ s[49];

        h = c8 ^ ((c2 << 1) | (c3 >> 31));
        l = c9 ^ ((c3 << 1) | (c2 >> 31));
        s[0] ^= h;
        s[1] ^= l;
        s[10] ^= h;
        s[11] ^= l;
        s[20] ^= h;
        s[21] ^= l;
        s[30] ^= h;
        s[31] ^= l;
        s[40] ^= h;
        s[41] ^= l;
        h = c0 ^ ((c4 << 1) | (c5 >> 31));
        l = c1 ^ ((c5 << 1) | (c4 >> 31));
        s[2] ^= h;
        s[3] ^= l;
        s[12] ^= h;
        s[13] ^= l;
        s[22] ^= h;
        s[23] ^= l;
        s[32] ^= h;
        s[33] ^= l;
        s[42] ^= h;
        s[43] ^= l;
        h = c2 ^ ((c6 << 1) | (c7 >> 31));
        l = c3 ^ ((c7 << 1) | (c6 >> 31));
        s[4] ^= h;
        s[5] ^= l;
        s[14] ^= h;
        s[15] ^= l;
        s[24] ^= h;
        s[25] ^= l;
        s[34] ^= h;
        s[35] ^= l;
        s[44] ^= h;
        s[45] ^= l;
        h = c4 ^ ((c8 << 1) | (c9 >> 31));
        l = c5 ^ ((c9 << 1) | (c8 >> 31));
        s[6] ^= h;
        s[7] ^= l;
        s[16] ^= h;
        s[17] ^= l;
        s[26] ^= h;
        s[27] ^= l;
        s[36] ^= h;
        s[37] ^= l;
        s[46] ^= h;
        s[47] ^= l;
        h = c6 ^ ((c0 << 1) | (c1 >> 31));
        l = c7 ^ ((c1 << 1) | (c0 >> 31));
        s[8] ^= h;
        s[9] ^= l;
        s[18] ^= h;
        s[19] ^= l;
        s[28] ^= h;
        s[29] ^= l;
        s[38] ^= h;
        s[39] ^= l;
        s[48] ^= h;
        s[49] ^= l;

        b0 = s[0];
        b1 = s[1];
        b32 = (s[11] << 4) | (s[10] >> 28);
        b33 = (s[10] << 4) | (s[11] >> 28);
        b14 = (s[20] << 3) | (s[21] >> 29);
        b15 = (s[21] << 3) | (s[20] >> 29);
        b46 = (s[31] << 9) | (s[30] >> 23);
        b47 = (s[30] << 9) | (s[31] >> 23);
        b28 = (s[40] << 18) | (s[41] >> 14);
        b29 = (s[41] << 18) | (s[40] >> 14);
        b20 = (s[2] << 1) | (s[3] >> 31);
        b21 = (s[3] << 1) | (s[2] >> 31);
        b2 = (s[13] << 12) | (s[12] >> 20);
        b3 = (s[12] << 12) | (s[13] >> 20);
        b34 = (s[22] << 10) | (s[23] >> 22);
        b35 = (s[23] << 10) | (s[22] >> 22);
        b16 = (s[33] << 13) | (s[32] >> 19);
        b17 = (s[32] << 13) | (s[33] >> 19);
        b48 = (s[42] << 2) | (s[43] >> 30);
        b49 = (s[43] << 2) | (s[42] >> 30);
        b40 = (s[5] << 30) | (s[4] >> 2);
        b41 = (s[4] << 30) | (s[5] >> 2);
        b22 = (s[14] << 6) | (s[15] >> 26);
        b23 = (s[15] << 6) | (s[14] >> 26);
        b4 = (s[25] << 11) | (s[24] >> 21);
        b5 = (s[24] << 11) | (s[25] >> 21);
        b36 = (s[34] << 15) | (s[35] >> 17);
        b37 = (s[35] << 15) | (s[34] >> 17);
        b18 = (s[45] << 29) | (s[44] >> 3);
        b19 = (s[44] << 29) | (s[45] >> 3);
        b10 = (s[6] << 28) | (s[7] >> 4);
        b11 = (s[7] << 28) | (s[6] >> 4);
        b42 = (s[17] << 23) | (s[16] >> 9);
        b43 = (s[16] << 23) | (s[17] >> 9);
        b24 = (s[26] << 25) | (s[27] >> 7);
        b25 = (s[27] << 25) | (s[26] >> 7);
        b6 = (s[36] << 21) | (s[37] >> 11);
        b7 = (s[37] << 21) | (s[36] >> 11);
        b38 = (s[47] << 24) | (s[46] >> 8);
        b39 = (s[46] << 24) | (s[47] >> 8);
        b30 = (s[8] << 27) | (s[9] >> 5);
        b31 = (s[9] << 27) | (s[8] >> 5);
        b12 = (s[18] << 20) | (s[19] >> 12);
        b13 = (s[19] << 20) | (s[18] >> 12);
        b44 = (s[29] << 7) | (s[28] >> 25);
        b45 = (s[28] << 7) | (s[29] >> 25);
        b26 = (s[38] << 8) | (s[39] >> 24);
        b27 = (s[39] << 8) | (s[38] >> 24);
        b8 = (s[48] << 14) | (s[49] >> 18);
        b9 = (s[49] << 14) | (s[48] >> 18);

        s[0] = b0 ^ (~b2 & b4);
        s[1] = b1 ^ (~b3 & b5);
        s[10] = b10 ^ (~b12 & b14);
        s[11] = b11 ^ (~b13 & b15);
        s[20] = b20 ^ (~b22 & b24);
        s[21] = b21 ^ (~b23 & b25);
        s[30] = b30 ^ (~b32 & b34);
        s[31] = b31 ^ (~b33 & b35);
        s[40] = b40 ^ (~b42 & b44);
        s[41] = b41 ^ (~b43 & b45);
        s[2] = b2 ^ (~b4 & b6);
        s[3] = b3 ^ (~b5 & b7);
        s[12] = b12 ^ (~b14 & b16);
        s[13] = b13 ^ (~b15 & b17);
        s[22] = b22 ^ (~b24 & b26);
        s[23] = b23 ^ (~b25 & b27);
        s[32] = b32 ^ (~b34 & b36);
        s[33] = b33 ^ (~b35 & b37);
        s[42] = b42 ^ (~b44 & b46);
        s[43] = b43 ^ (~b45 & b47);
        s[4] = b4 ^ (~b6 & b8);
        s[5] = b5 ^ (~b7 & b9);
        s[14] = b14 ^ (~b16 & b18);
        s[15] = b15 ^ (~b17 & b19);
        s[24] = b24 ^ (~b26 & b28);
        s[25] = b25 ^ (~b27 & b29);
        s[34] = b34 ^ (~b36 & b38);
        s[35] = b35 ^ (~b37 & b39);
        s[44] = b44 ^ (~b46 & b48);
        s[45] = b45 ^ (~b47 & b49);
        s[6] = b6 ^ (~b8 & b0);
        s[7] = b7 ^ (~b9 & b1);
        s[16] = b16 ^ (~b18 & b10);
        s[17] = b17 ^ (~b19 & b11);
        s[26] = b26 ^ (~b28 & b20);
        s[27] = b27 ^ (~b29 & b21);
        s[36] = b36 ^ (~b38 & b30);
        s[37] = b37 ^ (~b39 & b31);
        s[46] = b46 ^ (~b48 & b40);
        s[47] = b47 ^ (~b49 & b41);
        s[8] = b8 ^ (~b0 & b2);
        s[9] = b9 ^ (~b1 & b3);
        s[18] = b18 ^ (~b10 & b12);
        s[19] = b19 ^ (~b11 & b13);
        s[28] = b28 ^ (~b20 & b22);
        s[29] = b29 ^ (~b21 & b23);
        s[38] = b38 ^ (~b30 & b32);
        s[39] = b39 ^ (~b31 & b33);
        s[48] = b48 ^ (~b40 & b42);
        s[49] = b49 ^ (~b41 & b43);

        s[0] ^= RC[n];
        s[1] ^= RC[n + 1];
    }
}

/* 解析单个 hex 字符，非法返回 -1 */
static int hexVal(char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

/*
 * 求解 PoW：找 n ∈ [0, difficulty) 使
 * DeepSeekHashV1(`${salt}_${expireAt}_${n}`) === challenge（64 位 hex 全等）。
 * 消息为 ASCII 且远小于单块 136 字节，走单块快路径；超长/非法输入返回 -2。
 */
int32_t solvePowNativeC(const char *salt, const char *challengeHex, int32_t difficulty, int64_t expireAt)
{
    if (salt == NULL || challengeHex == NULL || difficulty <= 0) {
        return -2;
    }
    uint32_t target[8];
    /* 按字节小端组装 8 个 32 位目标字（与 parseDeepSeekHashWords 一致） */
    for (int w = 0; w < 8; w++) {
        uint32_t b0 = 0;
        uint32_t b1 = 0;
        uint32_t b2 = 0;
        uint32_t b3 = 0;
        int hv;
        hv = hexVal(challengeHex[w * 8 + 0]);
        b0 = (uint32_t)hv << 4;
        hv = hexVal(challengeHex[w * 8 + 1]);
        b0 |= (uint32_t)hv;
        hv = hexVal(challengeHex[w * 8 + 2]);
        b1 = (uint32_t)hv << 4;
        hv = hexVal(challengeHex[w * 8 + 3]);
        b1 |= (uint32_t)hv;
        hv = hexVal(challengeHex[w * 8 + 4]);
        b2 = (uint32_t)hv << 4;
        hv = hexVal(challengeHex[w * 8 + 5]);
        b2 |= (uint32_t)hv;
        hv = hexVal(challengeHex[w * 8 + 6]);
        b3 = (uint32_t)hv << 4;
        hv = hexVal(challengeHex[w * 8 + 7]);
        b3 |= (uint32_t)hv;
        target[w] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    }

    /* 前缀 `salt_expireAt_`，一次性写入块模板 */
    uint8_t tmpl[136];
    memset(tmpl, 0, sizeof(tmpl));
    size_t off = 0;
    while (salt[off] != '\0') {
        if (off >= sizeof(tmpl) - 24) { /* 预留 n 数字 + 填充空间 */
            return -2;
        }
        tmpl[off] = (uint8_t)salt[off];
        off++;
    }
    if (off >= sizeof(tmpl) - 24) {
        return -2;
    }
    tmpl[off++] = '_';
    /* expireAt 十进制 */
    {
        char digits[24];
        int dl = 0;
        uint64_t v = (uint64_t)expireAt;
        if (v == 0) {
            digits[dl++] = '0';
        }
        while (v > 0 && dl < 24) {
            digits[dl++] = (char)('0' + (int)(v % 10));
            v /= 10;
        }
        for (int k = dl - 1; k >= 0; k--) {
            if (off >= sizeof(tmpl) - 12) {
                return -2;
            }
            tmpl[off++] = (uint8_t)digits[k];
        }
    }
    if (off >= sizeof(tmpl) - 12) {
        return -2;
    }
    tmpl[off++] = '_';
    size_t numOff = off;
    /* 尾部 0x80（字节 135），SHA3-256 填充常量部分 */
    tmpl[135] = 0x80;

    uint8_t blk[136];
    uint32_t s[50];
    for (int32_t n = 0; n < difficulty; n++) {
        memcpy(blk, tmpl, sizeof(blk));
        /* 写入 n 的十进制数字 */
        size_t p = numOff;
        char nd[12];
        int ndl = 0;
        int32_t v = n;
        if (v == 0) {
            nd[ndl++] = '0';
        }
        while (v > 0 && ndl < 12) {
            nd[ndl++] = (char)('0' + (int)(v % 10));
            v /= 10;
        }
        for (int k = ndl - 1; k >= 0; k--) {
            blk[p++] = (uint8_t)nd[k];
        }
        blk[p] = 0x06; /* SHA3 pad 首字节 */
        /* 组装 32 位字状态并吸收单块 */
        for (int i = 0; i < 50; i++) {
            s[i] = 0;
        }
        for (int i = 0; i < 34; i++) {
            size_t b = (size_t)(i * 4);
            s[i] = (uint32_t)blk[b] | ((uint32_t)blk[b + 1] << 8) |
                   ((uint32_t)blk[b + 2] << 16) | ((uint32_t)blk[b + 3] << 24);
        }
        keccakF(s);
        if (s[0] == target[0] && s[1] == target[1] && s[2] == target[2] && s[3] == target[3] &&
            s[4] == target[4] && s[5] == target[5] && s[6] == target[6] && s[7] == target[7]) {
            return n;
        }
    }
    return -1;
}
