import { speechRecognizer } from '@kit.CoreSpeechKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'AsrService';
const DOMAIN: number = 0x0000;

export interface AsrCallbacks {
  onPartial: (text: string) => void;
  onComplete: (fullText: string) => void;
  onError: (errorCode: number, errorMessage: string) => void;
}

/**
 * 原生语音识别单例服务（基于 HarmonyOS @kit.CoreSpeechKit speechRecognizer）
 * 采用实时录音识别模式（recognitionMode=0），由系统采集麦克风音频。
 */
export class AsrService {
  private static instance: AsrService | null = null;
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private sessionId: string = '';
  private callbacks: AsrCallbacks | null = null;
  private finalText: string = '';
  private partialText: string = '';
  private listening: boolean = false;
  private sessionStarted: boolean = false;
  private finishPending: boolean = false;
  private cancelPending: boolean = false;

  static getInstance(): AsrService {
    if (AsrService.instance === null) {
      AsrService.instance = new AsrService();
    }
    return AsrService.instance;
  }

  /**
   * 请求麦克风权限（user_grant），已授权时不弹窗直接返回
   */
  async requestMicrophonePermission(context: common.Context): Promise<boolean> {
    const atm: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    try {
      const result = await atm.requestPermissionsFromUser(context, perms);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'request mic permission failed: %{public}s', err.message ?? '');
      return false;
    }
  }

  private notifyLive(): void {
    if (this.callbacks !== null) {
      this.callbacks.onPartial(this.finalText + this.partialText);
    }
  }

  private async ensureEngine(): Promise<speechRecognizer.SpeechRecognitionEngine | null> {
    if (this.engine !== null) {
      return this.engine;
    }
    try {
      const extraParams: Record<string, Object> = {
        'locate': 'CN',
        'recognizerMode': 'long'
      };
      const createParams: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1,
        extraParams: extraParams
      };
      const engine: speechRecognizer.SpeechRecognitionEngine = await speechRecognizer.createEngine(createParams);
      const listener: speechRecognizer.RecognitionListener = {
        onStart: (sessionId: string, eventMessage: string): void => {
          hilog.info(DOMAIN, TAG, 'asr onStart sid=%{public}s msg=%{public}s', sessionId, eventMessage);
          this.sessionStarted = true;
          if (this.finishPending) {
            this.finishPending = false;
            this.doFinish();
          }
          if (this.cancelPending) {
            this.cancelPending = false;
            this.doCancel();
          }
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
          hilog.info(DOMAIN, TAG, 'asr onEvent code=%{public}d msg=%{public}s', eventCode, eventMessage);
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (result.isFinal) {
            this.finalText += result.result;
            this.partialText = '';
          } else {
            this.partialText = result.result;
          }
          this.notifyLive();
        },
        onComplete: (sessionId: string, eventMessage: string): void => {
          hilog.info(DOMAIN, TAG, 'asr onComplete msg=%{public}s', eventMessage);
          this.listening = false;
          const fullText: string = (this.finalText + this.partialText).trim();
          const cb: AsrCallbacks | null = this.callbacks;
          this.callbacks = null;
          if (cb !== null) {
            cb.onComplete(fullText);
          }
        },
        onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
          hilog.error(DOMAIN, TAG, 'asr onError code=%{public}d msg=%{public}s', errorCode, errorMessage);
          this.listening = false;
          const cb: AsrCallbacks | null = this.callbacks;
          this.callbacks = null;
          if (cb !== null) {
            cb.onError(errorCode, errorMessage);
          }
        }
      };
      engine.setListener(listener);
      this.engine = engine;
      return engine;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'createEngine failed: %{public}s', err.message ?? '');
      return null;
    }
  }

  /**
   * 开始一次识别会话（按住时调用）
   */
  async start(callbacks: AsrCallbacks): Promise<boolean> {
    if (this.listening) {
      return false;
    }
    const engine: speechRecognizer.SpeechRecognitionEngine | null = await this.ensureEngine();
    if (engine === null) {
      return false;
    }
    this.callbacks = callbacks;
    this.finalText = '';
    this.partialText = '';
    this.sessionStarted = false;
    this.finishPending = false;
    this.cancelPending = false;
    this.sessionId = `asr_${Date.now()}`;
    const extraParams: Record<string, Object> = {
      'recognitionMode': 0,
      // 按住说话模式：静音检测放宽到上限，会话只由松手 finish / 60s maxAudioDuration 终止，
      // 避免按下后未立即开口、说话停顿或静音输入时约 2 秒被 VAD 提前掐断
      'vadEnd': 60000,
      'maxAudioDuration': 60000
    };
    const startParams: speechRecognizer.StartParams = {
      sessionId: this.sessionId,
      audioInfo: {
        audioType: 'pcm',
        sampleRate: 16000,
        soundChannel: 1,
        sampleBit: 16
      },
      extraParams: extraParams
    };
    try {
      engine.startListening(startParams);
      this.listening = true;
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startListening failed: %{public}s', err.message ?? '');
      this.callbacks = null;
      return false;
    }
  }

  /**
   * 结束识别并等待最终结果（松开时调用）。
   * 若会话尚未真正启动（onStart 未回调），则排队到启动后执行，避免 finish 丢失。
   */
  finish(): void {
    if (this.listening && !this.sessionStarted) {
      this.finishPending = true;
      return;
    }
    this.doFinish();
  }

  private doFinish(): void {
    if (this.engine !== null && this.listening && this.sessionId.length > 0) {
      try {
        this.engine.finish(this.sessionId);
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'finish failed: %{public}s', err.message ?? '');
      }
    }
  }

  /**
   * 取消本次识别，丢弃结果（上滑取消/页面销毁时调用）
   */
  cancel(): void {
    if (this.listening && !this.sessionStarted) {
      this.cancelPending = true;
    }
    this.doCancel();
    this.listening = false;
    this.callbacks = null;
  }

  private doCancel(): void {
    if (this.engine !== null && this.sessionId.length > 0) {
      try {
        this.engine.cancel(this.sessionId);
      } catch (e) {
      }
    }
  }
}
