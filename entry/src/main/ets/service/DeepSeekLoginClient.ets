/**
 * DeepSeek 原生短信登录客户端（login-glass US1）。
 *
 * 端点契约索引（证据：spec/login-glass/evidence/api-analysis.md，样本 sniff_sms.json / sniff_login.json）：
 * - POST /api/v0/users/create_guest_challenge      明文 {"target_path":"<目标端点>"}        → evidence §1/§3
 * - POST /api/v0/users/create_sms_verification_code 加密 ArrayBuffer + PoW 头 + 密钥头      → evidence §1/§3/§4/§5
 * - POST /api/v0/users/login_by_mobile_sms          加密 ArrayBuffer + PoW 头 + 密钥头      → evidence §1/§3/§4/§5
 * - POST /api/v0/users/auth_token/check_device      明文 JSON + Bearer（尽力而为）          → evidence §1
 * - 公共请求头（x-device-id / x-client-version 2.7.0 / x-client-locale zh_CN /
 *   x-client-timezone-offset 28800 等）                                       → evidence §2
 * - Guest PoW：n ∈ [0,difficulty) 使 DeepSeekHashV1(`${salt}_${expire_at}_${n}`) === challenge，
 *   携带 x-ds-guest-pow-response: base64({"salt":"<salt>","answer":<n>})        → evidence §3
 * - 请求体加密：AES-128-CBC(PKCS7) 随机 key/IV 加密明文；key||IV 经 RSA-2048-OAEP(SHA-256,
 *   MGF1-SHA-256) 加密 base64 → x-request-encryption-key（由 RequestCipher 实现） → evidence §4
 * - 明文请求体字段（locale/region "[unset]"/area_code "+86"/os "web" 等）      → evidence §5
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PowChallengeInfo } from './PowChallenge';
import { PowSolver } from './PowSolver';
import { RequestCipher, CipherRequest } from './RequestCipher';
import { DeviceIdStore } from './DeviceIdStore';

const TAG: string = 'DSLogin';
const LOGIN_BASE_URL: string = 'https://chat.deepseek.com';
const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const X_CLIENT_VERSION: string = '2.7.1';
const CLIENT_LOCALE: string = 'zh_CN';
const CLIENT_TIMEZONE_OFFSET: string = '28800';
const CLIENT_REGION_UNSET: string = '[unset]';
const CLIENT_OS_WEB: string = 'web';
const AREA_CODE_CN: string = '+86';
const DEFAULT_SEND_WINDOW_SECS: number = 60;

const PATH_GUEST_CHALLENGE: string = '/api/v0/users/create_guest_challenge';
const PATH_SEND_SMS: string = '/api/v0/users/create_sms_verification_code';
const PATH_LOGIN_SMS: string = '/api/v0/users/login_by_mobile_sms';
const PATH_CHECK_DEVICE: string = '/api/v0/users/auth_token/check_device';

/** 登录业务错误（携带服务端 biz_msg/msg 或兜底文案，供页面内联展示） */
export class LoginApiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LoginApiError';
  }
}

/** guest PoW 挑战模型：复用现有 PowChallengeInfo（同构哈希与求解，evidence §3） */
export class GuestChallengeInfo extends PowChallengeInfo {
}

/**
 * 数美验证码凭证（web 2.7.1 契约，取证自 bundle main.9120333998.js）：
 * 大陆用户（isMainlandChina）发送短信前主动完成数美验证码，
 * 凭证以对象形式放入 body.shumei_verification = {rid, region}（region 取端点区域 "CN"）。
 */
export class ShumeiVerification {
  rid: string = '';
  region: string = 'CN';

  constructor(rid: string, region: string) {
    this.rid = rid;
    this.region = region;
  }
}

/** 发码结果：send_window_secs 缺失兜底 60（RD/任务 T007） */
export class SendSmsResult {
  sendWindowSecs: number = DEFAULT_SEND_WINDOW_SECS;
}

/** 登录结果：token 非空即成功；biz_code=1（LOGIN_TO_EXISTING_ACCOUNT）亦成功（RD-05） */
export class LoginResult {
  token: string = '';
  bizCode: number = 0;
  bizMsg: string = '';
}

// ---------- 请求体（字段名取证自 evidence §5，snake_case） ----------

interface SendSmsBody {
  locale: string;
  turnstile_token: string;
  hcaptcha_token: string;
  device_id: string;
  scenario: string;
  mobile_number: string;
  shumei_verification?: ShumeiVerification;
}

interface LoginSmsBody {
  locale: string;
  region: string;
  mobile_number: string;
  area_code: string;
  sms_verification_code: string;
  device_id: string;
  os: string;
}

interface CheckDeviceBody {
  device_id: string;
  device_model: string;
}

interface GuestPowAnswerPayload {
  salt: string;
  answer: number;
}

// ---------- 响应原始结构（仅用于 JSON.parse 后一次性映射，字段全可选、snake_case） ----------

interface GuestChallengeRaw {
  algorithm?: string;
  challenge?: string;
  salt?: string;
  signature?: string;
  difficulty?: number;
  expire_at?: number;
  expire_after?: number;
  target_path?: string;
}

interface GuestChallengeBizRaw {
  guest_challenge?: GuestChallengeRaw;
}

interface GuestDataRaw {
  biz_data?: GuestChallengeBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface GuestRespRaw {
  code?: number;
  msg?: string;
  data?: GuestDataRaw;
}

interface SendSmsBizRaw {
  send_window_secs?: number;
}

interface SendSmsDataRaw {
  biz_data?: SendSmsBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface SendSmsRespRaw {
  code?: number;
  msg?: string;
  data?: SendSmsDataRaw;
}

interface UserRaw {
  id?: string;
  token?: string;
  email?: string;
  mobile_number?: string;
  area_code?: string;
}

interface LoginBizDataRaw {
  code?: number;
  msg?: string;
  user?: UserRaw;
}

interface LoginDataRaw {
  biz_data?: LoginBizDataRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface LoginRespRaw {
  code?: number;
  msg?: string;
  data?: LoginDataRaw;
}

interface ApiErrorRespRaw {
  code?: number;
  msg?: string;
}

/** 服务端文案优先（biz_msg > msg），映射不到用兜底文案 */
function pickServerMessage(msg: string | undefined, bizMsg: string | undefined, fallback: string): string {
  if (bizMsg !== undefined && bizMsg.length > 0) {
    return bizMsg;
  }
  if (msg !== undefined && msg.length > 0) {
    return msg;
  }
  return fallback;
}

/**
 * DeepSeek 短信登录客户端：guest 挑战 → PoW 求解 → 请求体加密 → 发码/登录 → 设备登记。
 * 全部端点/请求头/加密方案以 spec/login-glass/evidence/api-analysis.md 为准。
 */
export class DeepSeekLoginClient {
  private context: common.Context;
  private deviceId: string = '';

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 公共请求头组装（evidence §2；deviceId 来自 DeviceIdStore 持久化） */
  static buildBaseHeaders(deviceId: string): Record<string, string> {
    const header: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'accept': '*/*',
      'content-type': 'application/json',
      'x-device-id': deviceId,
      'x-device-model': '',
      'x-client-bundle-id': 'com.deepseek.chat',
      'x-client-platform': 'web',
      'x-client-version': X_CLIENT_VERSION,
      'x-client-locale': CLIENT_LOCALE,
      'x-client-timezone-offset': CLIENT_TIMEZONE_OFFSET
    };
    return header;
  }

  private async ensureDeviceId(): Promise<string> {
    if (this.deviceId.length > 0) {
      return this.deviceId;
    }
    this.deviceId = await DeviceIdStore.getOrCreate(this.context);
    return this.deviceId;
  }

  /**
   * POST JSON（body 可为明文字符串或加密后的 ArrayBuffer，content-type 均为 application/json，
   * 与取证一致——加密请求体同样携带该头，evidence §1/嗅探样本）。
   * 非 200 响应尝试解析服务端 msg 后抛 LoginApiError。
   */
  private postJson(deviceId: string, path: string, body: string | ArrayBuffer,
    extraHeaders?: Record<string, string>): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const req: http.HttpRequest = http.createHttp();
      const header: Record<string, string> = DeepSeekLoginClient.buildBaseHeaders(deviceId);
      if (extraHeaders !== undefined) {
        const keys: string[] = Object.keys(extraHeaders);
        for (const k of keys) {
          header[k] = extraHeaders[k];
        }
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      };
      req.request(`${LOGIN_BASE_URL}${path}`, options).then((resp: http.HttpResponse) => {
        req.destroy();
        const code: number = resp.responseCode;
        const text: string = typeof resp.result === 'string' ? resp.result : '';
        if (code !== 200) {
          let serverMsg: string = '';
          try {
            const errRaw: ApiErrorRespRaw = JSON.parse(text) as ApiErrorRespRaw;
            serverMsg = errRaw.msg ?? '';
          } catch (e) {
            serverMsg = '';
          }
          reject(new LoginApiError(serverMsg.length > 0 ? serverMsg : `服务异常(${code})`));
          return;
        }
        resolve(text);
      }).catch((err: BusinessError) => {
        req.destroy();
        reject(new LoginApiError(`网络错误：${err.message}`));
      });
    });
  }

  /** guest 挑战获取与映射（明文 body，target_path 为目标端点全路径，evidence §3） */
  private async fetchGuestChallenge(targetPath: string): Promise<GuestChallengeInfo> {
    const deviceId: string = await this.ensureDeviceId();
    const body: string = `{"target_path":"${targetPath}"}`;
    const text: string = await this.postJson(deviceId, PATH_GUEST_CHALLENGE, body);
    let raw: GuestRespRaw;
    try {
      raw = JSON.parse(text) as GuestRespRaw;
    } catch (e) {
      throw new LoginApiError('挑战响应解析失败');
    }
    const topCode: number = raw.code ?? -1;
    if (topCode !== 0) {
      throw new LoginApiError(pickServerMessage(raw.msg, raw.data?.biz_msg, `挑战获取失败(${topCode})`));
    }
    const ch: GuestChallengeRaw | undefined = raw.data?.biz_data?.guest_challenge;
    if (ch === undefined) {
      throw new LoginApiError('挑战数据缺失');
    }
    const info: GuestChallengeInfo = new GuestChallengeInfo();
    info.algorithm = ch.algorithm !== undefined && ch.algorithm.length > 0 ? ch.algorithm : 'DeepSeekHashV1';
    info.challenge = ch.challenge ?? '';
    info.salt = ch.salt ?? '';
    info.difficulty = ch.difficulty ?? 0;
    info.expireAt = ch.expire_at ?? 0;
    info.signature = ch.signature ?? '';
    info.targetPath = ch.target_path !== undefined && ch.target_path.length > 0 ? ch.target_path : targetPath;
    if (info.challenge.length === 0 || info.salt.length === 0 || info.difficulty <= 0) {
      throw new LoginApiError('挑战数据不完整');
    }
    return info;
  }

  /**
   * guest PoW 求解并构造请求头值（evidence §3）：
   * 求解 n ∈ [0, difficulty) 使 DeepSeekHashV1(`${salt}_${expire_at}_${n}`) === challenge，
   * 返回 base64({"salt":"<salt>","answer":<n>}) 作为 x-ds-guest-pow-response 头。
   */
  private async solveGuestPow(targetPath: string): Promise<string> {
    const challenge: GuestChallengeInfo = await this.fetchGuestChallenge(targetPath);
    const answer: number = await PowSolver.solve(challenge);
    const payload: GuestPowAnswerPayload = {
      salt: challenge.salt,
      answer: answer
    };
    const json: string = JSON.stringify(payload);
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(json);
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  /**
   * 发送短信验证码（evidence §1/§5 + web 2.7.1 数美验证码契约）：
   * 大陆用户先完成数美验证码，凭证对象放入 body.shumei_verification；
   * 请求体经 RequestCipher 加密 → 携带 PoW 头与 x-request-encryption-key 头 POST；
   * 响应 send_window_secs 映射，缺失兜底 60。
   */
  async sendSmsCode(mobile: string, shumei?: ShumeiVerification): Promise<SendSmsResult> {
    const deviceId: string = await this.ensureDeviceId();
    const powHeader: string = await this.solveGuestPow(PATH_SEND_SMS);
    const payload: SendSmsBody = {
      locale: CLIENT_LOCALE,
      turnstile_token: '',
      hcaptcha_token: '',
      device_id: deviceId,
      scenario: 'login',
      mobile_number: mobile,
      shumei_verification: shumei
    };
    const cipherReq: CipherRequest = await RequestCipher.encryptRequest(JSON.stringify(payload));
    const extra: Record<string, string> = {
      'x-ds-guest-pow-response': powHeader,
      'x-request-encryption-key': cipherReq.encryptionKey
    };
    const text: string = await this.postJson(deviceId, PATH_SEND_SMS, cipherReq.body.buffer as ArrayBuffer, extra);
    let raw: SendSmsRespRaw;
    try {
      raw = JSON.parse(text) as SendSmsRespRaw;
    } catch (e) {
      throw new LoginApiError('发码响应解析失败');
    }
    const topCode: number = raw.code ?? -1;
    const bizCode: number = raw.data?.biz_code ?? 0;
    if (topCode !== 0 || bizCode !== 0) {
      const bizMsg: string = raw.data?.biz_msg ?? '';
      if (bizMsg === 'RECAPTCHA_VERIFY_FAILED') {
        throw new LoginApiError('人机验证未通过，请重试；多次失败可使用下方网页登录');
      }
      throw new LoginApiError(pickServerMessage(raw.msg, bizMsg, '验证码发送失败'));
    }
    const result: SendSmsResult = new SendSmsResult();
    const window: number = raw.data?.biz_data?.send_window_secs ?? DEFAULT_SEND_WINDOW_SECS;
    result.sendWindowSecs = window > 0 ? window : DEFAULT_SEND_WINDOW_SECS;
    return result;
  }

  /**
   * 短信验证码登录（evidence §1/§5，RD-05）：
   * 登录体加密后 POST /api/v0/users/login_by_mobile_sms；
   * 成功判定 = data.biz_data.user.token 非空（biz_code=1 LOGIN_TO_EXISTING_ACCOUNT 亦成功）。
   */
  async loginBySms(mobile: string, smsCode: string): Promise<LoginResult> {
    const deviceId: string = await this.ensureDeviceId();
    const powHeader: string = await this.solveGuestPow(PATH_LOGIN_SMS);
    const payload: LoginSmsBody = {
      locale: CLIENT_LOCALE,
      region: CLIENT_REGION_UNSET,
      mobile_number: mobile,
      area_code: AREA_CODE_CN,
      sms_verification_code: smsCode,
      device_id: deviceId,
      os: CLIENT_OS_WEB
    };
    const cipherReq: CipherRequest = await RequestCipher.encryptRequest(JSON.stringify(payload));
    const extra: Record<string, string> = {
      'x-ds-guest-pow-response': powHeader,
      'x-request-encryption-key': cipherReq.encryptionKey
    };
    const text: string = await this.postJson(deviceId, PATH_LOGIN_SMS, cipherReq.body.buffer as ArrayBuffer, extra);
    let raw: LoginRespRaw;
    try {
      raw = JSON.parse(text) as LoginRespRaw;
    } catch (e) {
      throw new LoginApiError('登录响应解析失败');
    }
    const topCode: number = raw.code ?? -1;
    const bizCode: number = raw.data?.biz_code ?? 0;
    if (topCode !== 0) {
      throw new LoginApiError(pickServerMessage(raw.msg, raw.data?.biz_msg, `登录失败(${topCode})`));
    }
    if (bizCode !== 0 && bizCode !== 1) {
      throw new LoginApiError(pickServerMessage(raw.msg, raw.data?.biz_msg, '登录失败'));
    }
    const token: string = raw.data?.biz_data?.user?.token ?? '';
    if (token.length === 0) {
      throw new LoginApiError(pickServerMessage(raw.msg, raw.data?.biz_msg, '登录成功但未返回凭证'));
    }
    const result: LoginResult = new LoginResult();
    result.token = token;
    result.bizCode = bizCode;
    result.bizMsg = raw.data?.biz_msg ?? '';
    return result;
  }

  /**
   * 登录后设备登记（evidence §1：明文 JSON + Bearer 新 token，尽力而为，失败静默）。
   */
  async checkDevice(token: string): Promise<boolean> {
    try {
      const deviceId: string = await this.ensureDeviceId();
      const payload: CheckDeviceBody = {
        device_id: deviceId,
        device_model: ''
      };
      const extra: Record<string, string> = {
        'authorization': `Bearer ${token}`
      };
      await this.postJson(deviceId, PATH_CHECK_DEVICE, JSON.stringify(payload), extra);
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0x0000, TAG, 'checkDevice best-effort failed: %{public}s', err.message);
      return false;
    }
  }
}
