import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'TtsService';
const DOMAIN: number = 0x0000;

/**
 * 清理 Markdown 标记，转为适合语音播报的纯文本
 */
export function cleanMarkdownForSpeech(md: string): string {
  let text: string = md;
  // 移除代码块，替换为提示语
  text = text.replace(/```[\s\S]*?```/g, ' 代码块 ');
  // 移除行内代码
  text = text.replace(/`([^`]+)`/g, '$1');
  // 移除标题标记
  text = text.replace(/#{1,6}\s+/g, '');
  // 移除粗体和斜体
  text = text.replace(/(\*\*|__)(.*?)\1/g, '$2');
  text = text.replace(/(\*|_)(.*?)\1/g, '$2');
  // 移除删除线
  text = text.replace(/~~(.*?)~~/g, '$1');
  // 移除链接，保留文本
  text = text.replace(/\[([^\]]+)\]\([^\)]+\)/g, '$1');
  // 移除引用和列表标记
  text = text.replace(/^>\s+/gm, '');
  text = text.replace(/^[-*+]\s+/gm, '');
  text = text.replace(/^\d+\.\s+/gm, '');
  // 表格竖线转空格
  text = text.replace(/\|/g, ' ');
  return text.trim();
}

/**
 * 原生文本转语音单例服务（基于 HarmonyOS @kit.CoreSpeechKit）
 */
export class TtsService {
  private static instance: TtsService | null = null;
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private isInitializing: boolean = false;
  private currentMsgId: string = '';
  private stateListeners: ((msgId: string, isPlaying: boolean) => void)[] = [];

  static getInstance(): TtsService {
    if (TtsService.instance === null) {
      TtsService.instance = new TtsService();
    }
    return TtsService.instance;
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

  private notifyState(msgId: string, isPlaying: boolean): void {
    for (const l of this.stateListeners) {
      l(msgId, isPlaying);
    }
  }

  getPlayingMsgId(): string {
    return this.currentMsgId;
  }

  isPlaying(msgId: string): boolean {
    return this.currentMsgId.length > 0 && this.currentMsgId === msgId;
  }

  private async ensureEngine(): Promise<textToSpeech.TextToSpeechEngine | null> {
    if (this.ttsEngine !== null) {
      return this.ttsEngine;
    }
    if (this.isInitializing) {
      return null;
    }
    this.isInitializing = true;
    try {
      const extraParam: Record<string, Object> = {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'name': 'DeepSeekVoiceEngine'
      };
      const initParamsInfo: textToSpeech.CreateEngineParams = {
        language: 'zh-CN',
        person: 0,
        online: 1,
        extraParams: extraParam
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(initParamsInfo);
      const listener: textToSpeech.SpeakListener = {
        onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {
          this.notifyState(this.currentMsgId, true);
        },
        onComplete: (_requestId: string, _response: textToSpeech.CompleteResponse): void => {
          const finishedId: string = this.currentMsgId;
          this.currentMsgId = '';
          this.notifyState(finishedId, false);
        },
        onStop: (_requestId: string, _response: textToSpeech.StopResponse): void => {
          const stoppedId: string = this.currentMsgId;
          this.currentMsgId = '';
          this.notifyState(stoppedId, false);
        },
        onData: (_requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse): void => {
        },
        onError: (_requestId: string, errorCode: number, errorMessage: string): void => {
          hilog.error(DOMAIN, TAG, 'TTS error code=%{public}d msg=%{public}s', errorCode, errorMessage);
          const errId: string = this.currentMsgId;
          this.currentMsgId = '';
          this.notifyState(errId, false);
        }
      };
      engine.setListener(listener);
      this.ttsEngine = engine;
      this.isInitializing = false;
      return engine;
    } catch (e) {
      this.isInitializing = false;
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'createEngine failed: %{public}s', err.message ?? '');
      return null;
    }
  }

  async speak(msgId: string, text: string): Promise<boolean> {
    // 点击同一个正在播报的消息则停止
    if (this.currentMsgId === msgId) {
      this.stop();
      return false;
    }
    if (this.currentMsgId.length > 0) {
      this.stop();
    }
    const cleanText: string = cleanMarkdownForSpeech(text);
    if (cleanText.length === 0) {
      return false;
    }
    const engine: textToSpeech.TextToSpeechEngine | null = await this.ensureEngine();
    if (engine === null) {
      return false;
    }
    this.currentMsgId = msgId;
    this.notifyState(msgId, true);

    const extraParam: Record<string, Object> = {
      'speed': 1,
      'volume': 2,
      'pitch': 1,
      'languageContext': 'zh-CN',
      'audioType': 'pcm',
      'playType': 1
    };
    const speakParams: textToSpeech.SpeakParams = {
      requestId: `${Date.now()}_${msgId}`,
      extraParams: extraParam
    };
    try {
      engine.speak(cleanText, speakParams);
      return true;
    } catch (e) {
      const errId: string = this.currentMsgId;
      this.currentMsgId = '';
      this.notifyState(errId, false);
      return false;
    }
  }

  stop(): void {
    if (this.ttsEngine !== null && this.currentMsgId.length > 0) {
      try {
        this.ttsEngine.stop();
      } catch (e) {
      }
    }
    const oldId: string = this.currentMsgId;
    this.currentMsgId = '';
    if (oldId.length > 0) {
      this.notifyState(oldId, false);
    }
  }
}
