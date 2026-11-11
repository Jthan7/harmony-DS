import { webSocket } from '@kit.NetworkKit';
import { audio } from '@kit.AudioKit';
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { requestTtsTicket } from './DeepSeekWebClient';

const TAG: string = 'DsTtsService';
const DOMAIN: number = 0x0000;
const WS_TTS_BASE: string = 'wss://chat.deepseek.com/api/v0/chat/tts/';
const TTS_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
// 24kHz * 2 字节(S16LE) = 48 字节/毫秒
const BYTES_PER_MS: number = 48;

interface TtsEventRaw {
  event?: string;
  audio_id?: string;
  format?: string;
  code?: number;
  msg?: string;
}

interface TtsAckPayload {
  event: string;
  received_seq: number;
  played_seq: number;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 待播放 PCM 分片：记录原始负载与已消费偏移，供 writeData 拉模式回调按需填充。
 */
class PendingChunk {
  data: ArrayBuffer;
  offset: number = 0;

  constructor(data: ArrayBuffer) {
    this.data = data;
  }
}

/**
 * DeepSeek 服务端语音合成（自然人声）。
 * 协议：POST /api/v0/auth/ticket 取票据（必要时带 PoW 重试）→
 * WebSocket wss://chat.deepseek.com/api/v0/chat/tts/ 拉取 PCM 流 → AudioRenderer 播放。
 * 二进制帧：4 字节大端 uint32 序号 + s16le 单声道 24kHz PCM。
 *
 * syscap 告警说明：ets-loader checkSyscapAbility 不剥离 @syscap 标签的
 * `[since ...]` 后缀导致误报 "not supported on all devices"（工具链 bug，
 * 见 tools/syscap-check-patch/patch-syscap-check.js，SDK 更新后需重跑）；
 * @SuppressWarnings(SYSCAP) 注解仅为前向兼容保留，运行期异常由 try/catch 兜底。
 */
@SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
export class DeepSeekTtsService {
  private static instance: DeepSeekTtsService | null = null;
  private ws: webSocket.WebSocket | null = null;
  private renderer: audio.AudioRenderer | null = null;
  private currentMsgId: string = '';
  private stateListeners: ((msgId: string, isPlaying: boolean) => void)[] = [];
  private ackTimer: number = -1;
  private drainTimer: number = -1;
  private receivedCount: number = 0;
  private writtenCount: number = 0;
  private receivedBytes: number = 0;
  private firstWriteWallMs: number = 0;
  private writeChain: Promise<void> = Promise.resolve();
  private pendingChunks: PendingChunk[] = [];
  private serverFinished: boolean = false;
  private drainQueued: boolean = false;
  private stopped: boolean = true;

  static getInstance(): DeepSeekTtsService {
    if (DeepSeekTtsService.instance === null) {
      DeepSeekTtsService.instance = new DeepSeekTtsService();
    }
    return DeepSeekTtsService.instance;
  }

  addListener(listener: (msgId: string, isPlaying: boolean) => void): void {
    this.stateListeners.push(listener);
  }

  removeListener(listener: (msgId: string, isPlaying: boolean) => void): void {
    const idx: number = this.stateListeners.indexOf(listener);
    if (idx >= 0) {
      this.stateListeners.splice(idx, 1);
    }
  }

  getPlayingMsgId(): string {
    return this.currentMsgId;
  }

  private notifyState(msgId: string, isPlaying: boolean): void {
    for (const l of this.stateListeners) {
      l(msgId, isPlaying);
    }
  }

  /**
   * 播放一条服务端消息。返回 false 表示启动失败（可回退到端侧 TTS）。
   */
  async speak(msgId: string, token: string, sessionId: string, serverMessageId: number): Promise<boolean> {
    if (this.currentMsgId.length > 0) {
      this.stop();
    }
    this.currentMsgId = msgId;
    this.stopped = false;
    this.serverFinished = false;
    this.drainQueued = false;
    this.receivedCount = 0;
    this.writtenCount = 0;
    this.receivedBytes = 0;
    this.firstWriteWallMs = 0;
    this.writeChain = Promise.resolve();
    this.pendingChunks = [];
    this.notifyState(msgId, true);

    try {
      const ticket: string = await requestTtsTicket(token);
      if (this.stopped || this.currentMsgId !== msgId) {
        return true;
      }
      hilog.info(DOMAIN, TAG, 'ticket acquired, connecting ws...');

      await this.setupRenderer();
      if (this.stopped || this.currentMsgId !== msgId) {
        this.teardown();
        return true;
      }

      await this.connectWs(token, sessionId, serverMessageId, ticket);
      if (this.stopped || this.currentMsgId !== msgId) {
        this.teardown();
        return true;
      }
      hilog.info(DOMAIN, TAG, 'tts ws connected, waiting audio stream');
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'speak failed: %{public}s', err.message ?? JSON.stringify(e));
      const errId: string = this.currentMsgId;
      this.teardown();
      this.currentMsgId = '';
      if (errId.length > 0) {
        this.notifyState(errId, false);
      }
      return false;
    }
  }

  stop(): void {
    const oldId: string = this.currentMsgId;
    hilog.info(DOMAIN, TAG, 'tts stop requested, msg=%{public}s frames=%{public}d', oldId, this.receivedCount);
    this.stopped = true;
    this.sendJson('{"event":"abort","reason":"user_stopped"}');
    this.teardown();
    this.currentMsgId = '';
    if (oldId.length > 0) {
      this.notifyState(oldId, false);
    }
  }

  // ---------- 内部流程 ----------

  private async setupRenderer(): Promise<void> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const rendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: rendererInfo
    };
    const renderer: audio.AudioRenderer = await audio.createAudioRenderer(options);
    // 拉模式：音频服务需要数据时通过 writeData 回调取数（替代已废弃的 write 推模式）
    try {
      renderer.on('writeData', (data: ArrayBuffer) => {
        this.fillAudioBuffer(data);
      });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      throw new Error(`renderer writeData register failed: ${err.message ?? 'unknown'}`);
    }
    await renderer.start();
    this.renderer = renderer;
  }

  private connectWs(token: string, sessionId: string, serverMessageId: number, ticket: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      this.ws = ws;
      let opened: boolean = false;
      ws.on('open', (err: BusinessError, _value: Object) => {
        if (err) {
          reject(new Error(`ws open error: ${err.message}`));
          return;
        }
        opened = true;
        resolve();
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err) {
          return;
        }
        this.handleWsMessage(value);
      });
      ws.on('close', (err: BusinessError, _value: webSocket.CloseResult) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'ws close err: %{public}s', err.message);
        }
        if (!opened) {
          reject(new Error('ws closed before open'));
          return;
        }
        this.handleWsClosed();
      });
      ws.on('error', (err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'ws error: %{public}s', err.message);
        if (!opened) {
          reject(new Error(`ws error: ${err.message}`));
          return;
        }
        this.handleFailure();
      });
      const url: string = `${WS_TTS_BASE}?chat_session_id=${sessionId}` +
        `&message_id=${serverMessageId}&ticket=${encodeURIComponent(ticket)}` +
        `&mode=manual&format=pcm`;
      const header: Record<string, string> = {
        'User-Agent': TTS_USER_AGENT,
        'x-client-platform': 'web',
        'x-client-version': '2.7.0',
        'authorization': `Bearer ${token}`,
        'Cookie': `userToken=${token}`
      };
      const reqOptions: webSocket.WebSocketRequestOptions = {
        header: header
      };
      ws.connect(url, reqOptions, (err: BusinessError, _value: boolean) => {
        if (err) {
          reject(new Error(`ws connect failed: ${err.message}`));
        }
      });
    });
  }

  private handleWsMessage(value: string | ArrayBuffer): void {
    if (this.stopped) {
      return;
    }
    if (typeof value === 'string') {
      this.handleTextFrame(value);
      return;
    }
    if (!(value instanceof ArrayBuffer) || value.byteLength <= 4) {
      return;
    }
    // 二进制帧：4 字节大端序号 + PCM 负载
    const view: DataView = new DataView(value);
    const seq: number = view.getUint32(0, false);
    const payload: ArrayBuffer = value.slice(4);
    if (this.receivedCount === 0) {
      this.startAckTimer();
    }
    this.receivedCount++;
    this.receivedBytes += payload.byteLength;
    if (this.renderer === null) {
      return;
    }
    // 入待播队列，由 writeData 回调按需拉取填充
    this.pendingChunks.push(new PendingChunk(payload));
  }

  /**
   * writeData 拉模式回调：从待播队列按需填充缓冲；数据不足时补 0（S16LE 静音）。
   * 约束：回调内只写 data，不调用其他 AudioRenderer 接口。
   */
  private fillAudioBuffer(data: ArrayBuffer): void {
    let filled: number = 0;
    while (filled < data.byteLength && this.pendingChunks.length > 0) {
      const chunk: PendingChunk = this.pendingChunks[0];
      const remain: number = chunk.data.byteLength - chunk.offset;
      const need: number = data.byteLength - filled;
      const copyLen: number = Math.min(remain, need);
      const dst: Uint8Array = new Uint8Array(data, filled, copyLen);
      dst.set(new Uint8Array(chunk.data, chunk.offset, copyLen));
      chunk.offset += copyLen;
      filled += copyLen;
      if (this.firstWriteWallMs === 0) {
        this.firstWriteWallMs = Date.now();
      }
      if (chunk.offset >= chunk.data.byteLength) {
        this.pendingChunks.shift();
        this.writtenCount++;
      }
    }
    if (filled < data.byteLength) {
      const pad: Uint8Array = new Uint8Array(data, filled, data.byteLength - filled);
      pad.fill(0);
    }
  }

  private handleTextFrame(text: string): void {
    let ev: TtsEventRaw;
    try {
      ev = JSON.parse(text) as TtsEventRaw;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bad text frame: %{public}s', text.substring(0, 120));
      return;
    }
    const kind: string = ev.event ?? '';
    if (kind === 'ready') {
      hilog.info(DOMAIN, TAG, 'tts ready audio_id=%{public}s format=%{public}s',
        ev.audio_id ?? '', ev.format ?? '');
      return;
    }
    if (kind === 'finish') {
      hilog.info(DOMAIN, TAG, 'server finish, frames=%{public}d', this.receivedCount);
      this.serverFinished = true;
      // 服务端已结束音频流，无需再发送 ack，避免向即将关闭的 ws 循环发送失败
      this.stopAckTimer();
      this.sendJson('{"event":"finish"}');
      this.queueDrain();
      return;
    }
    if (kind === 'error') {
      hilog.error(DOMAIN, TAG, 'tts stream error code=%{public}d msg=%{public}s', ev.code ?? 0, ev.msg ?? '');
      this.handleFailure();
      return;
    }
    hilog.debug(DOMAIN, TAG, 'text frame event=%{public}s', kind);
  }

  /**
   * 排队等待已写入数据播完后再收尾；重复调用（finish 与 close 事件先后到达）只排队一次。
   */
  private queueDrain(): void {
    if (this.drainQueued) {
      return;
    }
    this.drainQueued = true;
    this.writeChain = this.writeChain.then(async (): Promise<void> => {
      await this.waitDrain();
      this.completePlayback();
    });
  }

  private startAckTimer(): void {
    this.ackTimer = setInterval(() => {
      const ack: TtsAckPayload = {
        event: 'ack',
        received_seq: this.receivedCount,
        played_seq: this.writtenCount
      };
      this.sendJson(JSON.stringify(ack));
    }, 1000);
  }

  /**
   * 估算剩余播放时长并等待：24kHz S16LE 每毫秒 48 字节。
   */
  private async waitDrain(): Promise<void> {
    if (this.firstWriteWallMs === 0 || this.receivedBytes === 0) {
      return;
    }
    const totalMs: number = Math.floor(this.receivedBytes / BYTES_PER_MS);
    const elapsed: number = Date.now() - this.firstWriteWallMs;
    const waitMs: number = Math.max(200, totalMs - elapsed + 250);
    hilog.info(DOMAIN, TAG, 'drain wait=%{public}dms total=%{public}dms', waitMs, totalMs);
    await delay(waitMs);
  }

  private completePlayback(): void {
    if (this.stopped) {
      return;
    }
    const doneId: string = this.currentMsgId;
    hilog.info(DOMAIN, TAG, 'tts playback complete, msg=%{public}s', doneId);
    this.stopped = true;
    this.teardown();
    this.currentMsgId = '';
    if (doneId.length > 0) {
      this.notifyState(doneId, false);
    }
  }

  private handleWsClosed(): void {
    if (this.stopped) {
      return;
    }
    // 服务端主动断开：若音频已收完则等待播完，否则视为失败
    if (this.serverFinished) {
      this.queueDrain();
      return;
    }
    hilog.error(DOMAIN, TAG, 'ws closed before finish, frames=%{public}d', this.receivedCount);
    this.handleFailure();
  }

  private handleFailure(): void {
    if (this.stopped) {
      return;
    }
    const failId: string = this.currentMsgId;
    this.stopped = true;
    this.teardown();
    this.currentMsgId = '';
    if (failId.length > 0) {
      this.notifyState(failId, false);
    }
  }

  private sendJson(text: string): void {
    const ws: webSocket.WebSocket | null = this.ws;
    if (ws === null) {
      return;
    }
    ws.send(text).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'ws send failed: %{public}s', err.message);
    });
  }

  /**
   * 停止 ack 心跳；服务端 finish 后调用，避免向已关闭的 ws 持续发送。
   */
  private stopAckTimer(): void {
    if (this.ackTimer >= 0) {
      clearInterval(this.ackTimer);
      this.ackTimer = -1;
    }
  }

  private teardown(): void {
    this.stopAckTimer();
    const ws: webSocket.WebSocket | null = this.ws;
    this.ws = null;
    if (ws !== null) {
      try {
        ws.off('open');
        ws.off('message');
        ws.off('close');
        ws.off('error');
        ws.close((err: BusinessError) => {
          // 关闭失败可忽略，套接字随实例回收
        });
      } catch (e) {
      }
    }
    const renderer: audio.AudioRenderer | null = this.renderer;
    this.renderer = null;
    if (renderer !== null) {
      try {
        renderer.off('writeData');
      } catch (e) {
        // off 失败可忽略，release 时统一回收
      }
      renderer.stop().then((): Promise<void> => {
        return renderer.release();
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'renderer release failed: %{public}s', err.message);
      });
    }
    this.pendingChunks = [];
    this.writeChain = Promise.resolve();
  }
}
