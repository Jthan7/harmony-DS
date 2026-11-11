import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DSLogin';
const AES_KEY_LEN: number = 16;
const AES_IV_LEN: number = 16;
const RSA_CIPHER_SPEC: string = 'RSA2048|PKCS1_OAEP|SHA256|MGF1_SHA256';
const AES_CIPHER_SPEC: string = 'AES128|CBC|PKCS7';
const RSA_CIPHERTEXT_LEN: number = 256;

/**
 * DeepSeek 生产环境 RSA-2048 公钥（SPKI/X.509 base64）。
 * 来源：fe-static.deepseek.com main bundle `eL.production`，
 * Web Crypto importKey("spki", ..., {name:"RSA-OAEP", hash:"SHA-256"})。
 * 取证：spec/login-glass/evidence/api-analysis.md §4。
 */
const RSA_PUBLIC_KEY_SPKI_B64: string =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0RLAhx1TOJhAQBHS1LHXlnkfOg86O' +
  '+uhsmKWNNkmugVrRqO6cl13SnjBs2otRYZGJd50xpBG4We2i6/oCJCwxA/49YZfIwaeDmTx' +
  '+WBIN7qrwhwP7vGCi6Osesmn/Ddgdye6mifYkRpRMonQjGY6VPaUMTw1jjOAIKph5YZn0bDV' +
  'mGLvs5eH6CoQYHM5/Z1Nfhj36VL28eZi3elJHoz/L6Tzi2wY1rCYqYHfepq3Ysy8y5Y5BeFJ' +
  'XN60RYLlbs+MRC+2kyJqcfApUnn1O/W2om9dhxc6Rc5dqas1YB4X4CWCttrKk/suhpIx9zpQ' +
  'Y9kqtotbe5zweYaKv0rCVeqx8wIDAQAB';

/**
 * 加密请求结果模型：
 * - body: AES-128-CBC(PKCS7) 密文（ArrayBuffer 请求体）
 * - encryptionKey: RSA-2048-OAEP(SHA-256/MGF1-SHA-256) 加密 key||IV 后的 base64，
 *   作为请求头 `x-request-encryption-key` 携带
 */
export class CipherRequest {
  body: Uint8Array = new Uint8Array(0);
  encryptionKey: string = '';
}

/**
 * DeepSeek 请求体加密器（复刻 Web 端 bundle 拦截器 eO 的双层加密，evidence §4）：
 * 1. 明文 JSON → UTF-8 bytes
 * 2. 随机 16B AES-128 key + 16B IV
 * 3. AES-128-CBC（PKCS7）加密明文 → 密文 body
 * 4. 拼接 key(16B) || IV(16B) 共 32 字节
 * 5. RSA-2048-OAEP(SHA-256, MGF1-SHA-256) 加密 32 字节 → base64 → encryptionKey
 *
 * 规格串查证（T001）：HarmonyOS cryptoFramework OAEP 规格串为 4 段式
 * `RSA2048|PKCS1_OAEP|SHA256|MGF1_SHA256`（MGF1 必须显式 SHA-256 与 WebCrypto 一致，
 * 否则服务端解密失败）；AES 用 `AES128|CBC|PKCS7`（PKCS5/PKCS7 同实现，AES 16B 填充）。
 *
 * syscap 告警说明：ets-loader checkSyscapAbility 不剥离 @syscap 标签的
 * `[since ...]` 后缀导致误报 "not supported on all devices"（工具链 bug，
 * 见 tools/syscap-check-patch/patch-syscap-check.js，SDK 更新后需重跑）；
 * @SuppressWarnings(SYSCAP) 注解仅为前向兼容保留，运行期异常由各方法 try/catch 兜底。
 */
@SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
export class RequestCipher {
  private static pubKey: cryptoFramework.PubKey | null = null;

  private static async ensurePubKey(): Promise<cryptoFramework.PubKey> {
    if (RequestCipher.pubKey !== null) {
      return RequestCipher.pubKey;
    }
    try {
      const keyBytes: Uint8Array = new util.Base64Helper().decodeSync(RSA_PUBLIC_KEY_SPKI_B64);
      const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
      // @SuppressWarnings syscap
      const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const keyPair: cryptoFramework.KeyPair = await generator.convertKey(keyBlob, null);
      RequestCipher.pubKey = keyPair.pubKey;
      return keyPair.pubKey;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      throw new Error(`RSA public key import failed: ${err.message ?? 'unknown'}`);
    }
  }

  /**
   * 加密一个明文 JSON 请求体。
   * @param plainJson 明文 JSON 字符串
   * @returns CipherRequest（AES 密文 body + RSA 密文 base64 encryptionKey）
   */
  @SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
  static async encryptRequest(plainJson: string): Promise<CipherRequest> {
    try {
      // 随机 AES-128 key 与 IV
      const random: cryptoFramework.Random = cryptoFramework.createRandom();
      const keyBytes: Uint8Array = random.generateRandomSync(AES_KEY_LEN).data;
      const ivBytes: Uint8Array = random.generateRandomSync(AES_IV_LEN).data;

      // 第一层：AES-128-CBC(PKCS7) 加密明文
      const symGenerator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
      const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
      const symKey: cryptoFramework.SymKey = await symGenerator.convertKey(keyBlob);
      const aesCipher: cryptoFramework.Cipher = cryptoFramework.createCipher(AES_CIPHER_SPEC);
      const ivSpec: cryptoFramework.IvParamsSpec = {
        iv: { data: ivBytes },
        algName: 'IvParamsSpec'
      };
      await aesCipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
      const plainBlob: cryptoFramework.DataBlob = { data: new util.TextEncoder().encodeInto(plainJson) };
      const aesOut: cryptoFramework.DataBlob = await aesCipher.doFinal(plainBlob);

      // key || IV（32B）作为 RSA 明文
      const keyIv: Uint8Array = new Uint8Array(AES_KEY_LEN + AES_IV_LEN);
      keyIv.set(keyBytes, 0);
      keyIv.set(ivBytes, AES_KEY_LEN);

      // 第二层：RSA-2048-OAEP(SHA-256, MGF1-SHA-256) 加密 key||IV
      const pubKey: cryptoFramework.PubKey = await RequestCipher.ensurePubKey();
      const rsaCipher: cryptoFramework.Cipher = cryptoFramework.createCipher(RSA_CIPHER_SPEC);
      await rsaCipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, pubKey, null);
      const rsaIn: cryptoFramework.DataBlob = { data: keyIv };
      const rsaOut: cryptoFramework.DataBlob = await rsaCipher.doFinal(rsaIn);

      const result: CipherRequest = new CipherRequest();
      result.body = aesOut.data;
      result.encryptionKey = new util.Base64Helper().encodeToStringSync(rsaOut.data);
      return result;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      throw new Error(`request encrypt failed: ${err.message ?? 'unknown'}`);
    }
  }

  /**
   * 本地回环自验（开发期验证用，不参与线上流程）：
   * 固定 key/IV 做 AES-CBC 加密→解密回环比对，并用生产公钥做一次 RSA-OAEP 加密
   * 验证公钥导入与规格串可用（RSA 无私钥不可回环，以密文长度 256B 判定）。
   * @param plain 自验明文
   * @returns 全部通过返回 true
   */
  static async localSelfTest(plain: string): Promise<boolean> {
    try {
      // 固定 key: 0x00..0x0F，固定 IV: 0x10..0x1F
      const keyBytes: Uint8Array = new Uint8Array(AES_KEY_LEN);
      const ivBytes: Uint8Array = new Uint8Array(AES_IV_LEN);
      for (let i: number = 0; i < AES_KEY_LEN; i++) {
        keyBytes[i] = i;
        ivBytes[i] = i + AES_KEY_LEN;
      }
      // AES 回环
      const symGenerator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
      const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
      const symKey: cryptoFramework.SymKey = await symGenerator.convertKey(keyBlob);
      const ivSpec: cryptoFramework.IvParamsSpec = {
        iv: { data: ivBytes },
        algName: 'IvParamsSpec'
      };
      const encCipher: cryptoFramework.Cipher = cryptoFramework.createCipher(AES_CIPHER_SPEC);
      await encCipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
      const plainBlob: cryptoFramework.DataBlob = { data: new util.TextEncoder().encodeInto(plain) };
      const encOut: cryptoFramework.DataBlob = await encCipher.doFinal(plainBlob);
      const decCipher: cryptoFramework.Cipher = cryptoFramework.createCipher(AES_CIPHER_SPEC);
      await decCipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
      const encBlob: cryptoFramework.DataBlob = { data: encOut.data };
      const decOut: cryptoFramework.DataBlob = await decCipher.doFinal(encBlob);
      const roundtrip: string = util.TextDecoder.create('utf-8').decodeToString(decOut.data);
      if (roundtrip !== plain) {
        hilog.error(0x0000, TAG, 'cipher selfTest AES roundtrip mismatch');
        return false;
      }
      // RSA 生产公钥加密可用性
      const pubKey: cryptoFramework.PubKey = await RequestCipher.ensurePubKey();
      const rsaCipher: cryptoFramework.Cipher = cryptoFramework.createCipher(RSA_CIPHER_SPEC);
      await rsaCipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, pubKey, null);
      const keyIv: Uint8Array = new Uint8Array(AES_KEY_LEN + AES_IV_LEN);
      keyIv.set(keyBytes, 0);
      keyIv.set(ivBytes, AES_KEY_LEN);
      const rsaIn: cryptoFramework.DataBlob = { data: keyIv };
      const rsaOut: cryptoFramework.DataBlob = await rsaCipher.doFinal(rsaIn);
      if (rsaOut.data.length !== RSA_CIPHERTEXT_LEN) {
        hilog.error(0x0000, TAG, 'cipher selfTest RSA ciphertext len=%{public}d', rsaOut.data.length);
        return false;
      }
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(0x0000, TAG, 'cipher selfTest exception: %{public}s', err.message ?? 'unknown');
      return false;
    }
  }
}
