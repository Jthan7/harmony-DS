import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SseParser } from './SseParser';
import { PowChallengeInfo } from './PowChallenge';
import { PowSolver } from './PowSolver';
import { ChatMessage, MessageRole, SearchResultInfo, SessionSummary } from '../model/ChatModels';

const BASE_URL: string = 'https://chat.deepseek.com';
const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const X_CLIENT_VERSION: string = '2.7.0';
const POW_TARGET_PATH: string = '/api/v0/chat/completion';
const DEFAULT_MODEL_TYPE: string = 'default';
const AUTH_BIZ_CODES: number[] = [40001, 40002, 40003];

export enum DsErrorKind {
  AuthExpired = 0,
  RateLimit = 1,
  Network = 2,
  Server = 3,
  Unknown = 4
}

export class DsApiError extends Error {
  readonly kind: DsErrorKind;

  constructor(kind: DsErrorKind, message: string) {
    super(message);
    this.name = 'DsApiError';
    this.kind = kind;
  }
}

export function toDsError(e: object | undefined | null): DsApiError {
  if (e === null || e === undefined) {
    return new DsApiError(DsErrorKind.Network, '未知错误');
  }
  if (e instanceof DsApiError) {
    return e;
  }
  const err: BusinessError = e as BusinessError;
  return new DsApiError(DsErrorKind.Network, err.message ?? '未知错误');
}

export function authExpired(): DsApiError {
  return new DsApiError(DsErrorKind.AuthExpired, '登录已过期，请重新登录');
}

function isAuthBizCode(code: number): boolean {
  for (const c of AUTH_BIZ_CODES) {
    if (c === code) {
      return true;
    }
  }
  return false;
}

// ---------- 响应原始结构（仅用于 JSON.parse 后的一次性映射） ----------

interface BizIdRaw {
  id?: string;
}

interface CreateSessionBizRaw {
  id?: string;
  chat_session?: BizIdRaw;
}

interface CreateSessionDataRaw {
  biz_data?: CreateSessionBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface CreateSessionRespRaw {
  code?: number;
  msg?: string;
  data?: CreateSessionDataRaw;
}

interface PowChallengeRaw {
  algorithm?: string;
  challenge?: string;
  salt?: string;
  signature?: string;
  difficulty?: number;
  expire_at?: number;
  target_path?: string;
}

interface PowBizRaw {
  challenge?: PowChallengeRaw;
}

interface PowDataRaw {
  biz_data?: PowBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface PowRespRaw {
  code?: number;
  msg?: string;
  data?: PowDataRaw;
}

interface SessionItemRaw {
  id?: string;
  title?: string;
  title_type?: string;
  pinned?: boolean;
  updated_at?: number;
}

interface SessionBizRaw {
  chat_sessions?: SessionItemRaw[];
  has_more?: boolean;
}

interface SessionListDataRaw {
  biz_data?: SessionBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface SessionListRespRaw {
  code?: number;
  msg?: string;
  data?: SessionListDataRaw;
}

interface HistoryMessageRaw {
  message_id?: number;
  parent_id?: number;
  role?: string;
  status?: string;
  fragments?: FragmentRaw[];
}

interface HistoryBizRaw {
  chat_messages?: HistoryMessageRaw[];
}

interface HistoryDataRaw {
  biz_data?: HistoryBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface HistoryRespRaw {
  code?: number;
  msg?: string;
  data?: HistoryDataRaw;
}

/** SEARCH fragment 的 results 数组元素（联网搜索结果条目） */
interface SearchResultRaw {
  url?: string;
  title?: string;
  snippet?: string;
  cite_index?: number;
  site_name?: string;
  published_at?: string;
}

/** fragment 的 queries 数组元素（联网搜索查询词） */
interface QueryRaw {
  query?: string;
}

interface FragmentRaw {
  id?: number;
  type?: string;
  status?: string;
  content?: string;
  results?: SearchResultRaw[];
  queries?: QueryRaw[];
}

/** BATCH 包装 chunk 的子操作：{p: 子路径, o?: 操作, v: 值} */
interface BatchOpRaw {
  p?: string;
  o?: string;
  v?: string | number | boolean | object;
}

// /api/v0/users 响应：biz_data 可能为 {user:{...}} 或直接为用户对象，字段全部可选
interface UserIdProfileRaw {
  name?: string;
  given_name?: string;
  family_name?: string;
  picture?: string;
}

interface UserProfileRaw {
  name?: string;
  nickname?: string;
  email?: string;
  mobile?: string;
  user?: UserProfileRaw;
  id_profile?: UserIdProfileRaw;
}

interface UserDataRaw {
  biz_data?: UserProfileRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface UserRespRaw {
  code?: number;
  msg?: string;
  data?: UserDataRaw;
}

export interface DeepSeekUserProfile {
  displayName: string;
  email: string;
  avatarUrl: string;
}

interface CompletionChunkRaw {
  v?: string | number | boolean | object;
  t?: string;
  p?: string;
  o?: string;
  code?: string;
  response_message_id?: number;
}

interface PowHeaderPayload {
  algorithm: string;
  challenge: string;
  salt: string;
  answer: number;
  signature: string;
  target_path: string;
}

interface CompletionBody {
  chat_session_id: string;
  model_type: string;
  parent_message_id: number | null;
  prompt: string;
  ref_file_ids: string[];
  thinking_enabled: boolean;
  search_enabled: boolean;
}

export interface CompletionRequest {
  sessionId: string;
  prompt: string;
  thinkingEnabled: boolean;
  searchEnabled: boolean;
  parentMessageId: number | null;
  /** 随消息引用的已上传文件 id（服务端字段 ref_file_ids） */
  refFileIds: string[];
}

export interface CompletionCallbacks {
  onThinkingDelta: (text: string) => void;
  onAnswerDelta: (text: string) => void;
  /** 服务端 fragment 提交后的思考权威全文替换（校正增量未覆盖的种子/前缀文本） */
  onThinkingReplace: (text: string) => void;
  /** 服务端 fragment 提交后的答案权威全文替换 */
  onAnswerReplace: (text: string) => void;
  /** SEARCH fragment 到达的搜索结果（增量推送，可能多次回调） */
  onSearchResults: (results: SearchResultInfo[]) => void;
  /** 搜索阶段切换：searching=true 进入联网搜索（hint 为过程提示文本，可为空）；false 表示搜索阶段结束 */
  onSearchState: (searching: boolean, hint: string) => void;
  onMessageId: (id: number) => void;
  onDone: () => void;
  onError: (err: DsApiError) => void;
}

// ---------- 公共请求 ----------

function buildBaseHeaders(token: string): Record<string, string> {
  const header: Record<string, string> = {
    'User-Agent': USER_AGENT,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'accept-charset': 'UTF-8',
    'Content-Type': 'application/json',
    'x-client-platform': 'web',
    'x-client-version': X_CLIENT_VERSION,
    'authorization': `Bearer ${token}`,
    'Cookie': `userToken=${token}`
  };
  return header;
}

function httpRequest(token: string, method: http.RequestMethod, path: string,
  body: string | null, extraHeader?: Record<string, string>): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const req: http.HttpRequest = http.createHttp();
    const baseHeader: Record<string, string> = buildBaseHeaders(token);
    if (extraHeader !== undefined) {
      const keys: string[] = Object.keys(extraHeader);
      for (const k of keys) {
        baseHeader[k] = extraHeader[k];
      }
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: baseHeader,
      extraData: body ?? '',
      connectTimeout: 15000,
      readTimeout: 30000,
      expectDataType: http.HttpDataType.STRING
    };
    req.request(`${BASE_URL}${path}`, options).then((resp: http.HttpResponse) => {
      req.destroy();
      const code: number = resp.responseCode;
      const text: string = typeof resp.result === 'string' ? resp.result : '';
      if (code === 401 || code === 403) {
        reject(authExpired());
        return;
      }
      if (code === 429) {
        reject(new DsApiError(DsErrorKind.RateLimit, '请求过于频繁，请稍后再试'));
        return;
      }
      if (code !== 200) {
        reject(new DsApiError(DsErrorKind.Server, `服务异常(${code})`));
        return;
      }
      resolve(text);
    }).catch((err: BusinessError) => {
      req.destroy();
      reject(new DsApiError(DsErrorKind.Network, `网络错误：${err.message}`));
    });
  });
}

function checkBizResult(code: number | undefined, msg: string | undefined,
  bizCode: number | undefined, bizMsg: string | undefined): void {
  const c: number = code ?? -1;
  const bc: number = bizCode ?? 0;
  if (c === 0 && bc === 0) {
    return;
  }
  if (isAuthBizCode(c) || isAuthBizCode(bc)) {
    throw authExpired();
  }
  const message: string = (bizMsg && bizMsg.length > 0) ? bizMsg : ((msg && msg.length > 0) ? msg : `业务错误(${c})`);
  throw new DsApiError(DsErrorKind.Server, message);
}

// ---------- 业务接口 ----------

export async function createSession(token: string): Promise<string> {
  const text: string = await httpRequest(token, http.RequestMethod.POST, '/api/v0/chat_session/create',
    '{"agent":"chat"}');
  const raw: CreateSessionRespRaw = JSON.parse(text) as CreateSessionRespRaw;
  checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
  const id: string = raw.data?.biz_data?.id ?? raw.data?.biz_data?.chat_session?.id ?? '';
  if (id.length === 0) {
    throw new DsApiError(DsErrorKind.Server, '创建会话失败');
  }
  return id;
}

export async function listSessions(token: string): Promise<SessionSummary[]> {
  const result: SessionSummary[] = [];
  const seen: Set<string> = new Set<string>();
  let cursor: number = 0;
  for (let page: number = 0; page < 10; page++) {
    // 游标为复合键（pinned, updated_at），续页时两者都要带，字段名与 Web 端一致
    let path: string = '/api/v0/chat_session/fetch_page?lte_cursor.pinned=false';
    if (cursor > 0) {
      path += `&lte_cursor.updated_at=${cursor}`;
    }
    const text: string = await httpRequest(token, http.RequestMethod.GET, path, null);
    const raw: SessionListRespRaw = JSON.parse(text) as SessionListRespRaw;
    checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
    const items: SessionItemRaw[] = raw.data?.biz_data?.chat_sessions ?? [];
    if (items.length === 0) {
      break;
    }
    // 本页最小 updated_at 作为下一页游标（服务端按 updated_at 倒序返回）
    let minUpdatedAt: number = Number.MAX_SAFE_INTEGER;
    let added: number = 0;
    for (const it of items) {
      const id: string = it.id ?? '';
      if (id.length === 0 || seen.has(id)) {
        continue;
      }
      seen.add(id);
      added++;
      result.push({
        id: id,
        title: it.title && it.title.length > 0 ? it.title : '新对话',
        updatedAtMs: Math.floor((it.updated_at ?? 0) * 1000),
        pinned: it.pinned === true
      });
      const ua: number = it.updated_at ?? 0;
      if (ua > 0 && ua < minUpdatedAt) {
        minUpdatedAt = ua;
      }
    }
    if (raw.data?.biz_data?.has_more !== true) {
      break;
    }
    // 本页无新增（全部重复）说明游标未推进，终止防止死循环
    if (added === 0 || minUpdatedAt === Number.MAX_SAFE_INTEGER || minUpdatedAt >= cursor) {
      break;
    }
    cursor = minUpdatedAt;
  }
  return result;
}

export async function fetchUserProfile(token: string): Promise<DeepSeekUserProfile> {
  // web 端实际端点为 /api/v0/users/current（见 bundle: http.get(baseUrl + "/current")）
  const text: string = await httpRequest(token, http.RequestMethod.GET, '/api/v0/users/current', null);
  hilog.info(0x0000, 'DSWeb', 'users resp len=%{public}d head=%{public}s',
    text.length, text.substring(0, 400));
  let raw: UserRespRaw;
  try {
    raw = JSON.parse(text) as UserRespRaw;
  } catch (e) {
    throw new DsApiError(DsErrorKind.Server, '用户信息响应解析失败');
  }
  checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
  const biz: UserProfileRaw | undefined = raw.data?.biz_data;
  // biz_data 可能为 {user:{...}}，也可能直接就是用户对象
  const u: UserProfileRaw = biz?.user ?? biz ?? {};
  const email: string = u.email ?? '';
  const profileName: string = u.id_profile?.name ?? u.id_profile?.given_name ?? '';
  const rawName: string = u.name ?? u.nickname ?? '';
  let displayName: string = rawName.length > 0 ? rawName : profileName;
  if (displayName.length === 0 && email.length > 0) {
    const atIdx: number = email.indexOf('@');
    displayName = atIdx > 0 ? email.substring(0, atIdx) : email;
  }
  if (displayName.length === 0) {
    displayName = 'DeepSeek 用户';
  }
  return {
    displayName: displayName,
    email: email,
    avatarUrl: u.id_profile?.picture ?? ''
  };
}

export async function loadMessages(token: string, sessionId: string): Promise<ChatMessage[]> {
  const path: string = `/api/v0/chat/history_messages?chat_session_id=${sessionId}`;
  const text: string = await httpRequest(token, http.RequestMethod.GET, path, null);
  let raw: HistoryRespRaw;
  try {
    raw = JSON.parse(text) as HistoryRespRaw;
  } catch (e) {
    hilog.error(0x0000, 'DSWeb', 'history_messages resp parse failed, len=%{public}d head=%{public}s',
      text.length, text.substring(0, 300));
    throw new DsApiError(DsErrorKind.Server, '消息响应解析失败');
  }
  checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
  const items: HistoryMessageRaw[] = raw.data?.biz_data?.chat_messages ?? [];
  const result: ChatMessage[] = [];
  for (const it of items) {
    // 从 fragments 提取正文、思考与搜索结果
    let content: string = '';
    let thinking: string = '';
    const searchResults: SearchResultInfo[] = [];
    const frags: FragmentRaw[] = it.fragments ?? [];
    for (const frag of frags) {
      const tp: string = (frag.type ?? '').toUpperCase();
      // 搜索结果：任何 fragment 携带 results 都收集（主路径为 SEARCH/TOOL_SEARCH 类型）
      const fragResults: SearchResultRaw[] = frag.results ?? [];
      for (const r of fragResults) {
        const rUrl: string = r.url ?? '';
        if (rUrl.length === 0) {
          continue;
        }
        searchResults.push(new SearchResultInfo(rUrl, r.title ?? '', r.snippet ?? '',
          r.cite_index ?? 0, r.site_name ?? '', r.published_at ?? ''));
      }
      const c: string = frag.content ?? '';
      if (c.length === 0) {
        continue;
      }
      if (tp === 'THINK' || tp === 'THINKING') {
        thinking += c;
      } else if (tp === 'REQUEST' || tp === 'RESPONSE' || tp === 'TEMPLATE_RESPONSE') {
        content += c;
      }
    }
    if (content.length === 0 && thinking.length === 0) {
      continue;
    }
    const roleStr: string = (it.role ?? '').toUpperCase();
    const role: MessageRole = roleStr === 'USER' ? MessageRole.User : MessageRole.Assistant;
    const msgId: number = it.message_id ?? 0;
    const id: string = msgId > 0 ? `m_${msgId}` : `m_${Date.now()}_${result.length}`;
    const msg: ChatMessage = new ChatMessage(id, role, content);
    msg.thinking = thinking;
    msg.serverMessageId = msgId;
    msg.searchResults = searchResults;
    result.push(msg);
  }
  return result;
}

async function createPowChallenge(token: string, targetPath: string): Promise<PowChallengeInfo> {
  const body: string = `{"target_path":"${targetPath}"}`;
  const text: string = await httpRequest(token, http.RequestMethod.POST, '/api/v0/chat/create_pow_challenge', body);
  const raw: PowRespRaw = JSON.parse(text) as PowRespRaw;
  checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
  const ch: PowChallengeRaw | undefined = raw.data?.biz_data?.challenge;
  if (ch === undefined) {
    throw new DsApiError(DsErrorKind.Server, 'PoW 挑战获取失败');
  }
  const info: PowChallengeInfo = new PowChallengeInfo();
  info.algorithm = ch.algorithm && ch.algorithm.length > 0 ? ch.algorithm : 'DeepSeekHashV1';
  info.challenge = ch.challenge ?? '';
  info.salt = ch.salt ?? '';
  info.difficulty = ch.difficulty ?? 0;
  info.expireAt = ch.expire_at ?? 0;
  info.signature = ch.signature ?? '';
  info.targetPath = ch.target_path && ch.target_path.length > 0 ? ch.target_path : targetPath;
  if (info.challenge.length === 0 || info.salt.length === 0) {
    throw new DsApiError(DsErrorKind.Server, 'PoW 挑战数据不完整');
  }
  return info;
}

function buildPowHeader(ch: PowChallengeInfo, answer: number): string {
  const payload: PowHeaderPayload = {
    algorithm: ch.algorithm,
    challenge: ch.challenge,
    salt: ch.salt,
    answer: answer,
    signature: ch.signature,
    target_path: ch.targetPath
  };
  const json: string = JSON.stringify(payload);
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(json);
  return new util.Base64Helper().encodeToStringSync(bytes);
}

// ---------- PoW 票据预取（消除每条消息串行的挑战获取+求解延迟） ----------

/** 已求解的 PoW 票据：组装完成的 x-ds-pow-response 头值及其有效期（秒） */
class PowTicket {
  header: string;
  expireAtSec: number;

  constructor(header: string, expireAtSec: number) {
    this.header = header;
    this.expireAtSec = expireAtSec;
  }
}

/**
 * PoW 票据管理：后台预取+预解下一张票据，发送时直接消费缓存票据，
 * 将首字延迟中的 create_pow_challenge 往返与本地暴力求解完全移出关键路径。
 */
export class PowTicketManager {
  private static ticket: PowTicket | null = null;
  private static inFlight: Promise<PowTicket> | null = null;

  private static nowSec(): number {
    return Math.floor(Date.now() / 1000);
  }

  /** 统一过期秒值（服务端为秒级时间戳；毫秒值兜底转换） */
  private static toSec(expireAt: number): number {
    return expireAt > 1000000000000 ? Math.floor(expireAt / 1000) : expireAt;
  }

  /** 取当前缓存票据，过期（或距过期不足 30 秒）返回 null */
  private static usableTicket(): PowTicket | null {
    const t: PowTicket | null = PowTicketManager.ticket;
    if (t !== null && t.expireAtSec > PowTicketManager.nowSec() + 30) {
      return t;
    }
    return null;
  }

  private static async fetchAndSolve(token: string, lowPriority: boolean): Promise<PowTicket> {
    const challenge: PowChallengeInfo = await createPowChallenge(token, POW_TARGET_PATH);
    const answer: number = await PowSolver.solve(challenge, lowPriority);
    return new PowTicket(buildPowHeader(challenge, answer), PowTicketManager.toSec(challenge.expireAt));
  }

  /** 获取一张票据头值：优先消费缓存，其次等待在途预热，最后现场获取+求解；消费后自动预热下一张 */
  static async getHeader(token: string): Promise<string> {
    const cached: PowTicket | null = PowTicketManager.usableTicket();
    if (cached !== null) {
      PowTicketManager.ticket = null;
      PowTicketManager.warm(token);
      return cached.header;
    }
    PowTicketManager.ticket = null;
    const pending: Promise<PowTicket> | null = PowTicketManager.inFlight;
    if (pending !== null) {
      try {
        await pending;
      } catch (e) {
        // 预热失败：回退现场获取
      }
      const warmed: PowTicket | null = PowTicketManager.usableTicket();
      if (warmed !== null) {
        PowTicketManager.ticket = null;
        PowTicketManager.warm(token);
        return warmed.header;
      }
    }
    const t: PowTicket = await PowTicketManager.fetchAndSolve(token, false);
    PowTicketManager.warm(token);
    return t.header;
  }

  /** 后台预热下一张票据（已有缓存或在途预热时忽略；失败静默，下次发送走现场获取） */
  static warm(token: string): void {
    if (token.length === 0 || PowTicketManager.ticket !== null || PowTicketManager.inFlight !== null) {
      return;
    }
    const p: Promise<PowTicket> = PowTicketManager.fetchAndSolve(token, true);
    PowTicketManager.inFlight = p;
    p.then((t: PowTicket): void => {
      if (PowTicketManager.inFlight === p) {
        PowTicketManager.inFlight = null;
      }
      if (PowTicketManager.ticket === null) {
        PowTicketManager.ticket = t;
      }
    }).catch((): void => {
      if (PowTicketManager.inFlight === p) {
        PowTicketManager.inFlight = null;
      }
    });
  }
}

// ---------- TTS ticket（服务端语音合成鉴权票据） ----------

const TTS_TICKET_PATH: string = '/api/v0/auth/ticket';
const POW_BIZ_CODES: number[] = [40300, 40301, 40303, 40304];

interface TicketBizRaw {
  ticket?: string;
}

interface TicketDataRaw {
  biz_data?: TicketBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface TicketRespRaw {
  code?: number;
  msg?: string;
  data?: TicketDataRaw;
}

function isPowBizCode(code: number): boolean {
  for (const c of POW_BIZ_CODES) {
    if (c === code) {
      return true;
    }
  }
  return false;
}

/**
 * 获取服务端 TTS 票据：POST /api/v0/auth/ticket {"scope":"tts"}
 * 若服务端要求 PoW（biz_code 40300/40301/40303/40304），求解挑战后带 x-ds-pow-response 重试。
 */
export async function requestTtsTicket(token: string): Promise<string> {
  const body: string = '{"scope":"tts"}';
  let text: string = await httpRequest(token, http.RequestMethod.POST, TTS_TICKET_PATH, body);
  let raw: TicketRespRaw = JSON.parse(text) as TicketRespRaw;
  if (isPowBizCode(raw.data?.biz_code ?? 0)) {
    const challenge: PowChallengeInfo = await createPowChallenge(token, TTS_TICKET_PATH);
    const answer: number = await PowSolver.solve(challenge);
    const powHeader: Record<string, string> = {
      'x-ds-pow-response': buildPowHeader(challenge, answer)
    };
    text = await httpRequest(token, http.RequestMethod.POST, TTS_TICKET_PATH, body, powHeader);
    raw = JSON.parse(text) as TicketRespRaw;
  }
  checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
  const ticket: string = raw.data?.biz_data?.ticket ?? '';
  if (ticket.length === 0) {
    throw new DsApiError(DsErrorKind.Server, 'TTS ticket 获取失败');
  }
  return ticket;
}

// ---------- 文件上传（/api/v0/file/upload_file，取证自 Web bundle main.9120333998.js） ----------

const UPLOAD_TARGET_PATH: string = '/api/v0/file/upload_file';
const FETCH_FILES_PATH: string = '/api/v0/file/fetch_files';
// 服务端默认上限：单文件 100MB（bundle: cU={maxCount:50,maxSizeMB:cB(0x6400000)}）
export const MAX_UPLOAD_FILE_BYTES: number = 0x6400000;

/** 服务端文件解析状态（bundle: FileParseStatus 枚举） */
export class DsFileStatus {
  static readonly PENDING: string = 'PENDING';
  static readonly PARSING: string = 'PARSING';
  static readonly SUCCESS: string = 'SUCCESS';
  static readonly FAILED: string = 'FAILED';
  static readonly CONTENT_FILTER: string = 'CONTENT_FILTER';
  static readonly CONTENT_TOO_LONG: string = 'CONTENT_TOO_LONG';
  static readonly CANCELLED: string = 'CANCELLED';
  static readonly CONTENT_EMPTY: string = 'CONTENT_EMPTY';
}

/** 解析是否已到终态（bundle: fileParseStatusMeaning[x].isFinished） */
export function isParseFinished(status: string): boolean {
  const finished: string[] = [DsFileStatus.SUCCESS, DsFileStatus.FAILED, DsFileStatus.CONTENT_FILTER,
    DsFileStatus.CONTENT_TOO_LONG, DsFileStatus.CANCELLED, DsFileStatus.CONTENT_EMPTY];
  for (const s of finished) {
    if (s === status) {
      return true;
    }
  }
  return false;
}

/** 上传/轮询返回的服务端文件信息 */
export interface DsUploadedFile {
  id: string;
  fileName: string;
  fileSize: number;
  status: string;
  isImage: boolean;
}

interface DsFileBizRaw {
  id?: string;
  file_name?: string;
  file_size?: number;
  status?: string;
  is_image?: boolean;
  error_code?: string;
}

interface DsFileDataRaw {
  biz_data?: DsFileBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface DsFileRespRaw {
  code?: number;
  msg?: string;
  data?: DsFileDataRaw;
}

interface DsFileListBizRaw {
  files?: DsFileBizRaw[];
}

interface DsFileListDataRaw {
  biz_data?: DsFileListBizRaw;
  biz_code?: number;
  biz_msg?: string;
}

interface DsFileListRespRaw {
  code?: number;
  msg?: string;
  data?: DsFileListDataRaw;
}

function mapDsFile(biz: DsFileBizRaw): DsUploadedFile | null {
  const id: string = biz.id ?? '';
  if (id.length === 0) {
    return null;
  }
  return {
    id: id,
    fileName: biz.file_name ?? '',
    fileSize: biz.file_size ?? 0,
    status: biz.status ?? '',
    isImage: biz.is_image === true
  };
}

/** multipart/form-data 请求体：--boundary 头 + 文件字节 + --boundary-- 尾 */
function buildMultipartBody(boundary: string, fileName: string, mimeType: string,
  fileBytes: ArrayBuffer): ArrayBuffer {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const head: Uint8Array = encoder.encodeInto(
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\n` +
    `Content-Type: ${mimeType}\r\n\r\n`);
  const tail: Uint8Array = encoder.encodeInto(`\r\n--${boundary}--\r\n`);
  const fileArr: Uint8Array = new Uint8Array(fileBytes);
  const total: number = head.byteLength + fileArr.byteLength + tail.byteLength;
  const out: Uint8Array = new Uint8Array(new ArrayBuffer(total));
  out.set(head, 0);
  out.set(fileArr, head.byteLength);
  out.set(tail, head.byteLength + fileArr.byteLength);
  return out.buffer;
}

/**
 * 上传单个文件：PoW（upload_file 场景）→ multipart POST /api/v0/file/upload_file。
 * onProgress 回调上传百分比（0-100）。
 */
export function uploadFile(token: string, fileName: string, mimeType: string,
  fileBytes: ArrayBuffer, thinkingEnabled: boolean,
  onProgress: (percent: number) => void): Promise<DsUploadedFile> {
  const uploadInner = async (): Promise<DsUploadedFile> => {
    const challenge: PowChallengeInfo = await createPowChallenge(token, UPLOAD_TARGET_PATH);
    const answer: number = await PowSolver.solve(challenge);
    const powHeader: string = buildPowHeader(challenge, answer);
    const boundary: string = `----DsForm${Date.now().toString(36)}`;
    const body: ArrayBuffer = buildMultipartBody(boundary, fileName, mimeType, fileBytes);
    const header: Record<string, string> = buildBaseHeaders(token);
    header['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
    header['x-ds-pow-response'] = powHeader;
    header['x-thinking-enabled'] = thinkingEnabled ? '1' : '0';
    header['x-model-type'] = DEFAULT_MODEL_TYPE;
    header['x-file-size'] = String(fileBytes.byteLength);
    return new Promise<DsUploadedFile>((resolve, reject) => {
      const req: http.HttpRequest = http.createHttp();
      req.on('dataSendProgress', (info: http.DataSendProgressInfo) => {
        const total: number = info.totalSize;
        if (total > 0) {
          onProgress(Math.min(99, Math.floor(info.sendSize * 100 / total)));
        }
      });
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        connectTimeout: 15000,
        readTimeout: 300000,
        expectDataType: http.HttpDataType.STRING
      };
      req.request(`${BASE_URL}${UPLOAD_TARGET_PATH}`, options).then((resp: http.HttpResponse) => {
        req.destroy();
        const code: number = resp.responseCode;
        const text: string = typeof resp.result === 'string' ? resp.result : '';
        if (code === 401 || code === 403) {
          reject(authExpired());
          return;
        }
        if (code === 429) {
          reject(new DsApiError(DsErrorKind.RateLimit, '请求过于频繁，请稍后再试'));
          return;
        }
        if (code !== 200) {
          reject(new DsApiError(DsErrorKind.Server, `上传失败(${code})`));
          return;
        }
        try {
          const raw: DsFileRespRaw = JSON.parse(text) as DsFileRespRaw;
          checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
          const file: DsUploadedFile | null = mapDsFile(raw.data?.biz_data ?? {});
          if (file === null) {
            throw new DsApiError(DsErrorKind.Server, '上传响应缺少文件信息');
          }
          onProgress(100);
          resolve(file);
        } catch (e) {
          reject(toDsError(e));
        }
      }).catch((err: BusinessError) => {
        req.destroy();
        reject(new DsApiError(DsErrorKind.Network, `网络错误：${err.message}`));
      });
    });
  };
  return uploadInner();
}

/** 查询文件解析状态：GET /api/v0/file/fetch_files?file_ids=a,b,c */
export async function fetchFiles(token: string, fileIds: string[]): Promise<DsUploadedFile[]> {
  const path: string = `${FETCH_FILES_PATH}?file_ids=${fileIds.join(',')}`;
  const text: string = await httpRequest(token, http.RequestMethod.GET, path, null);
  let raw: DsFileListRespRaw;
  try {
    raw = JSON.parse(text) as DsFileListRespRaw;
  } catch (e) {
    throw new DsApiError(DsErrorKind.Server, '文件信息响应解析失败');
  }
  checkBizResult(raw.code, raw.msg, raw.data?.biz_code, raw.data?.biz_msg);
  const items: DsFileBizRaw[] = raw.data?.biz_data?.files ?? [];
  const result: DsUploadedFile[] = [];
  for (const it of items) {
    const file: DsUploadedFile | null = mapDsFile(it);
    if (file !== null) {
      result.push(file);
    }
  }
  return result;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 轮询等待文件解析到终态（SUCCESS 或各类失败状态）。
 * 超时抛 DsApiError(Server)。
 */
export async function waitForFileReady(token: string, fileId: string,
  timeoutMs: number): Promise<DsUploadedFile> {
  const deadline: number = Date.now() + timeoutMs;
  let first: boolean = true;
  while (Date.now() < deadline) {
    if (!first) {
      await sleep(2000);
    }
    first = false;
    const files: DsUploadedFile[] = await fetchFiles(token, [fileId]);
    if (files.length > 0 && isParseFinished(files[0].status)) {
      return files[0];
    }
  }
  throw new DsApiError(DsErrorKind.Server, '文件解析超时，请稍后重试');
}

// ---------- 流式对话 ----------

function shouldSkipPath(path: string): boolean {
  if (path === 'response/search_status') {
    return true;
  }
  const skipContains: string[] = ['quasi_status', 'elapsed_secs', 'pending_fragment', 'conversation_mode'];
  for (const kw of skipContains) {
    if (path.indexOf(kw) >= 0) {
      return true;
    }
  }
  if (path.length === 0 || path === 'response/status' || path === 'status') {
    return false;
  }
  if (path.startsWith('response/fragments/') && path.endsWith('/status')) {
    return true;
  }
  return false;
}

/**
 * 一次流式补全。start() 后通过回调推送增量；abort() 停止生成。
 * 内部流程：PoW 挑战 → 求解 → SSE 流式请求 completion → 增量解析（新旧双格式）。
 */
export class CompletionStream {
  private httpReq: http.HttpRequest | null = null;
  private parser: SseParser = new SseParser();
  private finished: boolean = false;
  private cb: CompletionCallbacks | null = null;
  /** 旧协议正向下标 → fragment 类型（大写），用于识别 SEARCH fragment 并防止其内容混入答案 */
  private fragmentTypes: Map<number, string> = new Map();
  /** 新协议 fragment 模型：已提交 fragment 的类型（大写）按数组顺序，末元素即当前流式目标 */
  private fragModelTypes: string[] = [];
  /** 搜索阶段状态：SEARCH fragment 置 true，首个非 SEARCH 内容片段回到 false */
  private searchPhase: boolean = false;
  /** 搜索过程提示累积缓冲（SEARCH fragment 的 content 增量拼接，新阶段重置） */
  private searchHintBuf: string = '';
  /** 上次 fragment 提交时已回放的思考/答案权威全文（变更才回调） */
  private lastThinkAll: string = '';
  private lastAnswerAll: string = '';
  /** 请求开关缓存：首个 fragment 提交前按深度思考开关推断流式目标类型 */
  private reqThinkingEnabled: boolean = false;
  /** 旧协议 t=finish 标记：思考阶段结束，此后无类型标记的增量归属答案 */
  private thinkEnded: boolean = false;

  start(token: string, req: CompletionRequest, cb: CompletionCallbacks, powHeader: string): void {
    this.cb = cb;
    this.fragmentTypes.clear();
    this.fragModelTypes = [];
    this.searchPhase = false;
    this.searchHintBuf = '';
    this.lastThinkAll = '';
    this.lastAnswerAll = '';
    this.reqThinkingEnabled = req.thinkingEnabled;
    this.thinkEnded = false;
    this.run(token, req, powHeader).catch((err: BusinessError) => {
      this.emitError(toDsError(err));
    });
  }

  abort(): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    if (this.httpReq !== null) {
      this.httpReq.destroy();
      this.httpReq = null;
    }
    if (this.cb !== null) {
      this.cb.onDone();
    }
  }

  private async run(token: string, req: CompletionRequest, powHeader: string): Promise<void> {
    const body: CompletionBody = {
      chat_session_id: req.sessionId,
      model_type: DEFAULT_MODEL_TYPE,
      parent_message_id: req.parentMessageId,
      prompt: req.prompt,
      ref_file_ids: req.refFileIds,
      thinking_enabled: req.thinkingEnabled,
      search_enabled: req.searchEnabled
    };
    const header: Record<string, string> = buildBaseHeaders(token);
    header['Accept'] = 'text/event-stream';
    header['x-ds-pow-response'] = powHeader;

    return new Promise<void>((resolve, reject) => {
      const instance: http.HttpRequest = http.createHttp();
      this.httpReq = instance;
      instance.on('dataReceive', (data: ArrayBuffer) => {
        this.handleChunk(data);
      });
      instance.on('dataEnd', () => {
        if (this.finished) {
          return;
        }
        this.finished = true;
        this.httpReq = null;
        const tailEvents: string[] = this.parser.flush();
        for (const ev of tailEvents) {
          this.handleEvent(ev);
        }
        if (this.cb !== null) {
          this.cb.onDone();
        }
        resolve();
      });
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(body),
        connectTimeout: 15000,
        readTimeout: 300000,
        expectDataType: http.HttpDataType.STRING
      };
      instance.requestInStream(`${BASE_URL}${POW_TARGET_PATH}`, options,
        (err: BusinessError, responseCode: number) => {
          if (err) {
            if (this.finished) {
              return;
            }
            this.finished = true;
            this.httpReq = null;
            reject(new DsApiError(DsErrorKind.Network, `连接失败：${err.message}`));
            return;
          }
          if (responseCode !== 200) {
            if (this.finished) {
              return;
            }
            this.finished = true;
            instance.destroy();
            this.httpReq = null;
            if (responseCode === 401 || responseCode === 403) {
              reject(authExpired());
            } else if (responseCode === 429) {
              reject(new DsApiError(DsErrorKind.RateLimit, '请求过于频繁，请稍后再试'));
            } else {
              reject(new DsApiError(DsErrorKind.Server, `服务异常(${responseCode})`));
            }
          }
        });
    });
  }

  private handleChunk(data: ArrayBuffer): void {
    if (this.finished) {
      return;
    }
    const events: string[] = this.parser.push(data);
    for (const ev of events) {
      this.handleEvent(ev);
    }
  }

  private handleEvent(ev: string): void {
    if (this.cb === null) {
      return;
    }
    if (ev.length === 0 || ev === '[DONE]') {
      return;
    }
    let raw: CompletionChunkRaw;
    try {
      raw = JSON.parse(ev) as CompletionChunkRaw;
    } catch (e) {
      return;
    }
    if (raw.code === 'content_filter') {
      this.emitError(new DsApiError(DsErrorKind.Server, '内容审查限制，请调整提问后重试'));
      return;
    }
    const msgId: number = raw.response_message_id ?? 0;
    if (msgId > 0) {
      this.cb.onMessageId(msgId);
    }
    const path: string = raw.p ?? '';
    if (path.length > 0) {
      this.handleNewFormatChunk(raw, path);
      return;
    }
    const v: string = typeof raw.v === 'string' ? raw.v : '';
    const t: string = raw.t ?? '';
    if (v.length === 0) {
      return;
    }
    if (t === 'think') {
      this.cb.onThinkingDelta(v);
    } else if (t === 'finish') {
      // 思考阶段结束标记：此后无类型标记的增量归属答案
      this.thinkEnded = true;
    } else {
      // 旧格式无类型标记：按当前流式 fragment 类型路由（DEEP_SEARCH 思考增量也走此通道）
      this.routeContentByType(this.currentFragType(), v);
    }
  }

  /** 将 raw 搜索结果映射为 SearchResultInfo[]（跳过无 url 项） */
  private mapSearchResults(rawResults: SearchResultRaw[]): SearchResultInfo[] {
    const mapped: SearchResultInfo[] = [];
    for (const r of rawResults) {
      const rUrl: string = r.url ?? '';
      if (rUrl.length === 0) {
        continue;
      }
      mapped.push(new SearchResultInfo(rUrl, r.title ?? '', r.snippet ?? '',
        r.cite_index ?? 0, r.site_name ?? '', r.published_at ?? ''));
    }
    return mapped;
  }

  /** 推送搜索结果回调（空数组不推送） */
  private emitSearchResults(rawResults: SearchResultRaw[]): void {
    if (this.cb === null || rawResults.length === 0) {
      return;
    }
    const mapped: SearchResultInfo[] = this.mapSearchResults(rawResults);
    if (mapped.length > 0) {
      this.cb.onSearchResults(mapped);
    }
  }

  /** 切换搜索阶段：content 增量累积为过程提示（防无限增长截尾 120 字符），false 仅在阶段翻转时回调一次 */
  private setSearchPhase(active: boolean, hint: string): void {
    if (this.cb === null) {
      return;
    }
    if (active) {
      if (!this.searchPhase) {
        this.searchPhase = true;
        this.searchHintBuf = '';
      }
      if (hint.length > 0) {
        this.searchHintBuf += hint;
        if (this.searchHintBuf.length > 120) {
          this.searchHintBuf = this.searchHintBuf.substring(this.searchHintBuf.length - 120);
        }
      }
      this.cb.onSearchState(true, this.searchHintBuf);
      return;
    }
    if (this.searchPhase) {
      this.searchPhase = false;
      this.cb.onSearchState(false, '');
    }
  }

  /** 结束搜索阶段（首个思考/回答内容片段到达时调用） */
  private endSearchPhase(): void {
    this.setSearchPhase(false, '');
  }

  /** 当前流式目标 fragment 类型：模型末元素；模型为空（首个 fragment 未提交）时按 t=finish/思考开关推断 */
  private currentFragType(): string {
    if (this.fragModelTypes.length > 0) {
      return this.fragModelTypes[this.fragModelTypes.length - 1];
    }
    if (this.thinkEnded || !this.reqThinkingEnabled) {
      return 'RESPONSE';
    }
    return 'THINK';
  }

  /** 按 fragment 类型路由一段内容增量（思考/搜索提示/答案） */
  private routeContentByType(tp: string, text: string): void {
    if (this.cb === null || text.length === 0) {
      return;
    }
    if (tp === 'THINK' || tp === 'THINKING') {
      this.endSearchPhase();
      this.cb.onThinkingDelta(text);
      return;
    }
    if (tp === 'SEARCH' || tp === 'TOOL_SEARCH') {
      this.setSearchPhase(true, text);
      return;
    }
    if (tp === 'TOOL_OPEN') {
      // 打开网页阶段无正文增量，防御性忽略
      return;
    }
    this.endSearchPhase();
    this.cb.onAnswerDelta(text);
  }

  /**
   * 服务端 fragment 数组提交（全量替换）：重建模型并回放权威全文。
   * 提交内容包含增量未覆盖的种子/前缀文本（如 THINK 的"用户"前缀），经 Replace 回调校正；
   * 末元素为预创建的下一个流式 fragment（仅含种子），后续增量在其上继续追加。
   */
  private applyFragmentsArray(frags: FragmentRaw[]): void {
    if (this.cb === null || frags.length === 0) {
      return;
    }
    this.fragModelTypes = [];
    let thinkAll: string = '';
    let answerAll: string = '';
    for (const frag of frags) {
      const tp: string = (frag.type ?? '').toUpperCase();
      this.fragModelTypes.push(tp);
      const c: string = frag.content ?? '';
      if (tp === 'THINK' || tp === 'THINKING') {
        thinkAll += c;
      } else if (tp === 'REQUEST' || tp === 'RESPONSE' || tp === 'TEMPLATE_RESPONSE') {
        answerAll += c;
        this.thinkEnded = true;
      } else if (tp === 'SEARCH' || tp === 'TOOL_SEARCH') {
        // 搜索 fragment：queries 为过程提示
        const qs: QueryRaw[] = frag.queries ?? [];
        let joined: string = '';
        for (const q of qs) {
          joined += (joined.length > 0 ? '、' : '') + (q.query ?? '');
        }
        this.setSearchPhase(true, joined);
      }
      this.emitSearchResults(frag.results ?? []);
    }
    if (thinkAll !== this.lastThinkAll) {
      this.lastThinkAll = thinkAll;
      this.cb.onThinkingReplace(thinkAll);
    }
    if (answerAll !== this.lastAnswerAll) {
      this.lastAnswerAll = answerAll;
      this.cb.onAnswerReplace(answerAll);
    }
    // 末元素进入思考/回答阶段时结束搜索阶段
    const lastTp: string = this.fragModelTypes[this.fragModelTypes.length - 1] ?? '';
    if (lastTp === 'THINK' || lastTp === 'THINKING' || lastTp === 'REQUEST' ||
      lastTp === 'RESPONSE' || lastTp === 'TEMPLATE_RESPONSE') {
      this.endSearchPhase();
    }
  }

  private handleNewFormatChunk(raw: CompletionChunkRaw, path: string): void {
    if (this.cb === null) {
      return;
    }
    if (shouldSkipPath(path)) {
      return;
    }
    if (path === 'response/status' || path === 'status') {
      // FINISHED 等状态值：等待 dataEnd
      return;
    }
    // response BATCH 包装：v 为子操作数组，逐个按相对路径应用（主路径为 fragments 全量提交）
    if (path === 'response' && raw.o === 'BATCH' && Array.isArray(raw.v)) {
      const ops: BatchOpRaw[] = raw.v as BatchOpRaw[];
      for (const op of ops) {
        if ((op.p ?? '') === 'fragments' && Array.isArray(op.v)) {
          this.applyFragmentsArray(op.v as FragmentRaw[]);
        }
      }
      return;
    }
    // fragments 数组：APPEND 为旧协议增量列表，否则（o 省略/SET）为新协议全量提交
    if (path === 'response/fragments' && Array.isArray(raw.v)) {
      if (raw.o === 'APPEND') {
        const frags: FragmentRaw[] = raw.v as FragmentRaw[];
        for (const frag of frags) {
          const type: string = (frag.type ?? '').toUpperCase();
          if (type === 'SEARCH' || type === 'TOOL_SEARCH') {
            this.setSearchPhase(true, frag.content ?? '');
            this.emitSearchResults(frag.results ?? []);
            continue;
          }
          this.endSearchPhase();
          const content: string = frag.content ?? '';
          if (content.length > 0) {
            this.routeContentByType(type, content);
          }
        }
        return;
      }
      this.applyFragmentsArray(raw.v as FragmentRaw[]);
      return;
    }
    // fragment 级 BATCH：v 为针对该 fragment 的子操作数组（content 追加/results 设置）
    const fragBatchMatch: RegExpMatchArray | null = path.match(/^response\/fragments\/(-?\d+)$/);
    if (fragBatchMatch !== null && raw.o === 'BATCH' && Array.isArray(raw.v)) {
      const ops: BatchOpRaw[] = raw.v as BatchOpRaw[];
      for (const op of ops) {
        const opP: string = op.p ?? '';
        if (opP === 'content' && typeof op.v === 'string') {
          this.routeContentByType(this.currentFragType(), op.v);
        } else if (opP === 'results' && Array.isArray(op.v)) {
          this.emitSearchResults(op.v as SearchResultRaw[]);
        }
      }
      return;
    }
    // fragment 整体 SET 对象（旧协议正向下标）：记录类型并捕获其携带的搜索结果
    const fragSetMatch: RegExpMatchArray | null = path.match(/^response\/fragments\/(\d+)$/);
    if (fragSetMatch !== null && raw.o === 'SET' &&
      typeof raw.v === 'object' && raw.v !== null && !Array.isArray(raw.v)) {
      const fragObj: FragmentRaw = raw.v as FragmentRaw;
      const fragIdx: number = Number(fragSetMatch[1]) || 0;
      const fragType: string = (fragObj.type ?? '').toUpperCase();
      this.fragmentTypes.set(fragIdx, fragType);
      if (fragType === 'SEARCH' || fragType === 'TOOL_SEARCH') {
        // 搜索 fragment：内容为查询/状态文本，不进答案
        this.setSearchPhase(true, fragObj.content ?? '');
      } else {
        // 思考/回答 fragment 开始：结束搜索阶段
        this.endSearchPhase();
      }
      this.emitSearchResults(fragObj.results ?? []);
      return;
    }
    // fragment results 数组 APPEND/SET（含负下标）：搜索结果增量到达
    const fragResultsMatch: RegExpMatchArray | null = path.match(/^response\/fragments\/(-?\d+)\/results$/);
    if (fragResultsMatch !== null) {
      if (Array.isArray(raw.v)) {
        this.emitSearchResults(raw.v as SearchResultRaw[]);
      } else if (typeof raw.v === 'object' && raw.v !== null) {
        const single: SearchResultRaw = raw.v as SearchResultRaw;
        if ((single.url ?? '').length > 0) {
          this.emitSearchResults([single]);
        }
      }
      return;
    }
    if (typeof raw.v === 'string') {
      const v: string = raw.v;
      if (v.length === 0) {
        return;
      }
      // fragment content 增量：负下标为新协议流式目标（模型末元素），正下标按旧协议记录的类型路由
      const fragContentMatch: RegExpMatchArray | null = path.match(/^response\/fragments\/(-?\d+)\/content$/);
      if (fragContentMatch !== null) {
        const idxStr: string = fragContentMatch[1];
        if (idxStr.startsWith('-')) {
          this.routeContentByType(this.currentFragType(), v);
        } else {
          const legacyTp: string = this.fragmentTypes.get(Number(idxStr) || 0) ?? '';
          this.routeContentByType(legacyTp.length > 0 ? legacyTp : this.currentFragType(), v);
        }
        return;
      }
      if (path === 'response/thinking_content') {
        this.endSearchPhase();
        this.cb.onThinkingDelta(v);
      } else if (path === 'response/content') {
        this.endSearchPhase();
        this.cb.onAnswerDelta(v);
      } else if (!path.endsWith('/status')) {
        this.endSearchPhase();
        this.cb.onAnswerDelta(v);
      }
    }
  }

  private emitError(err: DsApiError): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    if (this.httpReq !== null) {
      this.httpReq.destroy();
      this.httpReq = null;
    }
    if (this.cb !== null) {
      this.cb.onError(err);
    }
  }
}
