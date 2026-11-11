import { ChatAttachment, AttachmentStatus, ChatMessage, MessageRole, MessageStatus, SearchResultInfo, SessionSummary } from '../model/ChatModels';
import { TokenStore } from '../service/TokenStore';
import {
  CompletionStream,
  CompletionCallbacks,
  CompletionRequest,
  DsApiError,
  DsErrorKind,
  DsFileStatus,
  DsUploadedFile,
  DeepSeekUserProfile,
  MAX_UPLOAD_FILE_BYTES,
  createSession,
  fetchUserProfile,
  listSessions,
  loadMessages,
  PowTicketManager,
  toDsError,
  uploadFile,
  waitForFileReady
} from '../service/DeepSeekWebClient';
import { InputBar } from '../components/InputBar';
import { MessageItem } from '../components/MessageItem';
import { HistoryDrawer } from '../components/HistoryDrawer';
import { QaNavRail } from '../components/QaNavRail';
import { TtsService } from '../service/TtsService';
import { DeepSeekTtsService } from '../service/DeepSeekTtsService';
import { AsrService } from '../service/AsrService';
import { SettingsStore } from '../service/SettingsStore';
import { picker, fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { curves, LengthMetrics, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

// 文件选择器后缀过滤（描述|后缀列表），与服务端支持的文档/图片格式对齐
const FILE_SUFFIX_FILTERS: string[] = [
  '文档|pdf,doc,docx,ppt,pptx,xls,xlsx,csv,txt,md,json,xml,html',
  '图片|png,jpg,jpeg,webp,gif,bmp'
];
// 单条消息最多携带的附件数（服务端默认上限 50，客户端收紧保证可读性）
const MAX_ATTACHMENTS: number = 10;
// 距底部小于该偏移视为"在底部"（上翻超过即显示回底按钮、停止流式跟随）
const NEAR_BOTTOM_THRESHOLD: number = 120;
// 抽屉 push 模式参数：面板宽度 / 景深缩放 / 拖动起手距离与速度判定阈值（vp、px/s）
const DRAWER_WIDTH: number = 288;
const DRAWER_MAX_SCALE: number = 0.94;
const DRAWER_DRAG_DISTANCE: number = 12;
const DRAWER_FLING_SPEED: number = 500;

@ComponentV2
export struct ChatPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local messages: ChatMessage[] = [];
  @Local isStreaming: boolean = false;
  @Local thinkingEnabled: boolean = false;
  @Local searchEnabled: boolean = false;
  // 抽屉打开进度 0（关）~1（开）：拖动中为连续值，驱动聊天页整体位移/景深
  @Local drawerProgress: number = 0;
  @Local currentSessionId: string = '';
  @Local sessions: SessionSummary[] = [];
  @Local loadingHistory: boolean = false;
  @Local speakingMsgId: string = '';
  @Local voiceRecording: boolean = false;
  @Local voiceLiveText: string = '';
  @Local currentTitle: string = '';
  @Local autoRead: boolean = false;
  @Local userName: string = '';
  @Local avatarUrl: string = '';
  @Local attachments: ChatAttachment[] = [];
  // 用户上翻离开底部时显示的液态玻璃回底按钮
  @Local showScrollBottom: boolean = false;
  // 输入栏实际高度（onAreaChange 动态量取，用于回底按钮定位）
  @Local inputBarHeight: number = 100;
  // 右侧问答导航条：用户消息索引集合与当前激活项
  @Local qaMarks: number[] = [];
  @Local activeQaIndex: number = 0;
  /** 跳转守卫截止时刻（ms）：窗口内 updateActiveQa 直接忽略，防止跳转落定被滚动回退 */
  private qaJumpGuardUntil: number = 0;
  /** 系统状态栏高度（vp）：List 全屏沉浸扩展后，标题渐变上移盖住状态栏、首部占位同步加高 */
  @Local statusBarVp: number = 0;
  /** 系统导航区高度（vp）：List 底部扩展进导航区，尾部占位同步加高保持消息停位 */
  @Local navBarVp: number = 0;

  private stream: CompletionStream | null = null;
  // 抽屉拖动起手时的进度基准（onActionStart 记录，onActionUpdate 增量累加）
  private drawerDragBase: number = 0;
  private scroller: Scroller = new Scroller();
  private thinkingBuf: string = '';
  private answerBuf: string = '';
  private flushTimer: number = -1;
  private thinkingStartMs: number = 0;
  private treeTipMsgId: number = 0;
  private turnParentMsgId: number = 0;
  private voiceCancelled: boolean = false;
  private voiceStarted: boolean = false;
  private voiceStopRequested: boolean = false;
  private voiceGuardTimer: number = -1;
  // 用户是否停留在列表底部附近：仅在底部时流式输出才自动跟随滚动
  // 通过 onScroll 偏移累积估算距底部距离（0=底部）；条目索引法在单条长回答内滚动时不变化，不可用
  private nearBottom: boolean = true;
  private distFromBottom: number = 0;
  // 最近一次用户消息携带的文件引用（重新生成时复用）
  private lastRefFileIds: string[] = [];
  private ttsStateHandler: ((msgId: string, isPlaying: boolean) => void) | null = null;
  private dsTtsStateHandler: ((msgId: string, isPlaying: boolean) => void) | null = null;

  aboutToAppear(): void {
    this.ttsStateHandler = (msgId: string, isPlaying: boolean): void => {
      this.onTtsState(msgId, isPlaying);
    };
    TtsService.getInstance().addListener(this.ttsStateHandler);
    this.dsTtsStateHandler = (msgId: string, isPlaying: boolean): void => {
      this.onTtsState(msgId, isPlaying);
    };
    DeepSeekTtsService.getInstance().addListener(this.dsTtsStateHandler);
    // 恢复持久化的自动朗读设置
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      SettingsStore.getAutoRead(ctx).then((v: boolean): void => {
        this.autoRead = v;
      });
      // 恢复持久化的深度思考/联网搜索开关
      SettingsStore.getThinkingEnabled(ctx).then((v: boolean): void => {
        this.thinkingEnabled = v;
      });
      SettingsStore.getSearchEnabled(ctx).then((v: boolean): void => {
        this.searchEnabled = v;
      });
      // 全屏沉浸：窗口扩展至整屏，消息文字滚入状态栏/导航区；系统避让改由布局按实测安全区自行补偿
      window.getLastWindow(ctx).then((win: window.Window): void => {
        win.setWindowLayoutFullScreen(true).then((): void => {
          // 状态栏透明化：文字从时钟/图标后方穿过，仅保留系统图标
          win.setWindowSystemBarProperties({
            statusBarColor: '#00000000',
            statusBarContentColor: '#000000'
          }).catch((barErr: BusinessError): void => {
            hilog.error(0x0000, 'ChatPage', 'setWindowSystemBarProperties failed: %{public}s', barErr.message);
          });
          this.measureAvoidArea(win);
        }).catch((fsErr: BusinessError): void => {
          hilog.error(0x0000, 'ChatPage', 'setWindowLayoutFullScreen failed: %{public}s', fsErr.message);
          this.measureAvoidArea(win);
        });
      }).catch((err: BusinessError): void => {
        hilog.error(0x0000, 'ChatPage', 'getLastWindow failed: %{public}s', err.message);
      });
    }
    this.loadUserProfile();
    // 预热 PoW 票据：登录态下提前获取+求解，消除首条消息的等待
    PowTicketManager.warm(TokenStore.get());
  }

  private async loadUserProfile(): Promise<void> {
    const token: string = TokenStore.get();
    if (token.length === 0) {
      return;
    }
    try {
      const profile: DeepSeekUserProfile = await fetchUserProfile(token);
      this.userName = profile.displayName;
      this.avatarUrl = profile.avatarUrl;
    } catch (e) {
      hilog.error(0x0000, 'ChatPage', 'fetchUserProfile failed: %{public}s', JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    if (this.flushTimer >= 0) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
    if (this.ttsStateHandler !== null) {
      TtsService.getInstance().removeListener(this.ttsStateHandler);
      this.ttsStateHandler = null;
    }
    if (this.dsTtsStateHandler !== null) {
      DeepSeekTtsService.getInstance().removeListener(this.dsTtsStateHandler);
      this.dsTtsStateHandler = null;
    }
    TtsService.getInstance().stop();
    DeepSeekTtsService.getInstance().stop();
    AsrService.getInstance().cancel();
    this.clearVoiceGuard();
    this.voiceRecording = false;
  }

  private onTtsState(msgId: string, isPlaying: boolean): void {
    if (isPlaying) {
      this.speakingMsgId = msgId;
    } else if (this.speakingMsgId === msgId) {
      this.speakingMsgId = '';
    }
  }

  // ---------- 对话流程 ----------

  private send(text: string): void {
    if (this.isStreaming) {
      return;
    }
    const prompt: string = text.trim();
    if (prompt.length === 0) {
      return;
    }
    const token: string = TokenStore.get();
    if (token.length === 0) {
      this.requireLogin();
      return;
    }
    // 附件仍在上传/解析时阻断发送；失败附件自动忽略
    for (const att of this.attachments) {
      if (att.status !== AttachmentStatus.Ready && att.status !== AttachmentStatus.Failed) {
        this.showToast('文件还在处理中，请稍候');
        return;
      }
    }
    const refIds: string[] = [];
    const names: string[] = [];
    for (const att of this.attachments) {
      if (att.status === AttachmentStatus.Ready) {
        refIds.push(att.fileId);
        names.push(att.fileName);
      }
    }
    const userMsg: ChatMessage = new ChatMessage(`u_${Date.now()}`, MessageRole.User, prompt);
    userMsg.attachmentNames = names;
    this.messages.push(userMsg);
    this.rebuildQaMarks();
    this.attachments = [];
    this.lastRefFileIds = refIds;
    this.beginAssistantTurn(token, prompt, refIds);
  }

  private regenerate(): void {
    if (this.isStreaming) {
      return;
    }
    const token: string = TokenStore.get();
    if (token.length === 0) {
      this.requireLogin();
      return;
    }
    let lastUserPrompt: string = '';
    for (const m of this.messages) {
      if (m.role === MessageRole.User) {
        lastUserPrompt = m.content;
      }
    }
    if (lastUserPrompt.length === 0) {
      return;
    }
    if (this.messages.length > 0 && this.messages[this.messages.length - 1].role === MessageRole.Assistant) {
      const removed: ChatMessage = this.messages[this.messages.length - 1];
      if (removed.serverMessageId === this.treeTipMsgId) {
        this.treeTipMsgId = this.turnParentMsgId;
      }
      this.messages.pop();
    }
    this.beginAssistantTurn(token, lastUserPrompt, this.lastRefFileIds);
  }

  private beginAssistantTurn(token: string, prompt: string, refFileIds: string[]): void {
    const assistant: ChatMessage = new ChatMessage(`a_${Date.now()}`, MessageRole.Assistant, '');
    assistant.status = MessageStatus.Streaming;
    this.messages.push(assistant);
    this.rebuildQaMarks();
    this.thinkingBuf = '';
    this.answerBuf = '';
    this.thinkingStartMs = 0;
    this.isStreaming = true;
    // 用户主动发消息：强制回到底部跟随
    this.nearBottom = true;
    this.distFromBottom = 0;
    this.setScrollBottomVisible(false);
    this.scrollBottom();
    this.runStream(token, assistant, prompt, refFileIds);
  }

  private async runStream(token: string, assistant: ChatMessage, prompt: string,
    refFileIds: string[]): Promise<void> {
    // PoW 票据获取与建会话并行，避免挑战获取+求解阻塞首字
    const powHeaderPromise: Promise<string> = PowTicketManager.getHeader(token);
    powHeaderPromise.catch((): void => {
    });
    if (this.currentSessionId.length === 0) {
      try {
        this.currentSessionId = await createSession(token);
      } catch (e) {
        this.finishStream(assistant, toDsError(e));
        return;
      }
    }
    let powHeader: string = '';
    try {
      powHeader = await powHeaderPromise;
    } catch (e) {
      this.finishStream(assistant, toDsError(e));
      return;
    }
    this.startFlushTimer(assistant);
    const callbacks: CompletionCallbacks = {
      onThinkingDelta: (t: string): void => {
        if (this.thinkingStartMs === 0) {
          this.thinkingStartMs = Date.now();
        }
        this.thinkingBuf += t;
      },
      onAnswerDelta: (t: string): void => {
        if (this.thinkingStartMs > 0 && assistant.thinkingElapsedMs === 0) {
          assistant.thinkingElapsedMs = Date.now() - this.thinkingStartMs;
        }
        this.answerBuf += t;
      },
      onThinkingReplace: (t: string): void => {
        this.thinkingBuf = t;
      },
      onAnswerReplace: (t: string): void => {
        if (this.thinkingStartMs > 0 && assistant.thinkingElapsedMs === 0) {
          assistant.thinkingElapsedMs = Date.now() - this.thinkingStartMs;
        }
        this.answerBuf = t;
      },
      onSearchResults: (results: SearchResultInfo[]): void => {
        this.appendSearchResults(assistant, results);
      },
      onSearchState: (searching: boolean, hint: string): void => {
        if (assistant.searching !== searching) {
          assistant.searching = searching;
        }
        if (hint.length > 0 && assistant.searchHint !== hint) {
          assistant.searchHint = hint;
        }
      },
      onMessageId: (id: number): void => {
        assistant.serverMessageId = id;
      },
      onDone: (): void => {
        this.finishStream(assistant, null);
      },
      onError: (err: DsApiError): void => {
        this.finishStream(assistant, err);
      }
    };
    const request: CompletionRequest = {
      sessionId: this.currentSessionId,
      prompt: prompt,
      thinkingEnabled: this.thinkingEnabled,
      searchEnabled: this.searchEnabled,
      parentMessageId: this.treeTipMsgId > 0 ? this.treeTipMsgId : null,
      refFileIds: refFileIds
    };
    this.turnParentMsgId = this.treeTipMsgId;
    const stream: CompletionStream = new CompletionStream();
    this.stream = stream;
    stream.start(token, request, callbacks, powHeader);
  }

  private finishStream(assistant: ChatMessage, err: DsApiError | null): void {
    this.stopFlushTimer(assistant);
    this.isStreaming = false;
    this.stream = null;
    // 兜底清除搜索进行中状态（正常路径已由首个思考/回答片段清除）
    assistant.searching = false;
    if (err !== null) {
      assistant.status = MessageStatus.Error;
      assistant.errorMsg = err.message;
      if (err.kind === DsErrorKind.AuthExpired) {
        TokenStore.remove();
        this.requireLogin();
      }
    } else {
      assistant.status = MessageStatus.Done;
      if (assistant.serverMessageId > 0) {
        this.treeTipMsgId = assistant.serverMessageId;
      }
      // 自动朗读回答
      if (this.autoRead && assistant.content.length > 0) {
        this.speakMessage(assistant);
      }
      // 刷新会话标题（服务端在首轮回答后生成）
      this.refreshTitle();
    }
    // 用户上滑阅读历史时不强拉回底部
    if (this.nearBottom) {
      this.scrollBottom();
    }
  }

  private startFlushTimer(assistant: ChatMessage): void {
    this.flushTimer = setInterval(() => {
      assistant.thinking = this.thinkingBuf;
      assistant.content = this.answerBuf;
      if (this.nearBottom) {
        this.scrollBottom();
      }
    }, 100);
  }

  private stopFlushTimer(assistant: ChatMessage): void {
    if (this.flushTimer >= 0) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
    assistant.thinking = this.thinkingBuf;
    assistant.content = this.answerBuf;
  }

  private stopStream(): void {
    if (this.stream !== null) {
      this.stream.abort();
    }
  }

  // ---------- 搜索结果与引用跳转 ----------

  /** 追加流式到达的搜索结果（按 url+citeIndex 去重，@Trace 整体替换触发刷新） */
  private appendSearchResults(assistant: ChatMessage, results: SearchResultInfo[]): void {
    if (results.length === 0) {
      return;
    }
    const merged: SearchResultInfo[] = assistant.searchResults.slice();
    for (const r of results) {
      let exists: boolean = false;
      for (const m of merged) {
        if (m.url === r.url && m.citeIndex === r.citeIndex) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        merged.push(r);
      }
    }
    if (merged.length !== assistant.searchResults.length) {
      assistant.searchResults = merged;
    }
  }

  /** 引用角标点击：确认后用默认浏览器打开 */
  private confirmOpenReference(url: string, title: string): void {
    const displayTitle: string = title.length > 0 ? title : '外部链接';
    this.getUIContext().showAlertDialog({
      title: '打开外部链接？',
      message: `${displayTitle}\n${url}`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: [
        {
          value: '取消',
          action: (): void => {
          }
        },
        {
          value: '打开',
          action: (): void => {
            this.openExternalUrl(url);
          }
        }
      ]
    });
  }

  private openExternalUrl(url: string): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.showToast('无法打开链接');
      return;
    }
    const abilityCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
    abilityCtx.openLink(url, { appLinkingOnly: false }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'ChatPage', 'openLink failed: %{public}s', err.message);
      this.showToast('无法打开链接');
    });
  }

  // ---------- 回底按钮 ----------

  /** 回底按钮显隐（带淡入淡出过渡；值未变化时不触发动画） */
  private setScrollBottomVisible(visible: boolean): void {
    if (this.showScrollBottom === visible) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.showScrollBottom = visible;
    });
  }

  /** 点击回底：弹簧动画滚回底部并恢复流式跟随 */
  private scrollToLatest(): void {
    this.nearBottom = true;
    this.distFromBottom = 0;
    this.setScrollBottomVisible(false);
    this.getUIContext().animateTo({ duration: 450, curve: curves.springMotion(0.34, 0.9) }, () => {
      this.scroller.scrollEdge(Edge.Bottom);
    });
  }

  // ---------- 问答导航条 ----------

  /** 重建用户消息索引集合（所有消息数组变更点调用） */
  private rebuildQaMarks(): void {
    const marks: number[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      if (this.messages[i].role === MessageRole.User) {
        marks.push(i);
      }
    }
    this.qaMarks = marks;
    this.activeQaIndex = Math.max(0, marks.length - 1);
  }

  /** 由首可见项推导当前激活问答 */
  private updateActiveQa(first: number): void {
    if (Date.now() < this.qaJumpGuardUntil) {
      return;
    }
    if (this.qaMarks.length === 0) {
      this.activeQaIndex = 0;
      return;
    }
    let active: number = 0;
    for (let k: number = 0; k < this.qaMarks.length; k++) {
      if (this.qaMarks[k] <= first) {
        active = k + 1;
      } else {
        break;
      }
    }
    const next: number = active > 0 ? active - 1 : 0;
    this.activeQaIndex = Math.min(next, this.qaMarks.length - 1);
  }

  /** 实测系统状态栏/导航区高度（vp）：全屏沉浸下首尾占位、标题渐变、dock 补偿按此适配 */
  private measureAvoidArea(win: window.Window): void {
    const sysTop: number = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
    const navBottom: number =
      win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
    const ui = this.getUIContext();
    if (sysTop > 0) {
      this.statusBarVp = ui.px2vp(sysTop);
    }
    if (navBottom > 0) {
      this.navBarVp = ui.px2vp(navBottom);
    }
  }

  /** 标题渐变内状态栏段占比：渐变从屏幕最顶端起渐隐，状态栏段保持较高白度保证图标可读 */
  private titleStatusStop(): number {
    const titleVp: number = 56;
    const total: number = this.statusBarVp + titleVp;
    if (total <= 0) {
      return 0.40;
    }
    return this.statusBarVp / total;
  }

  /** 计算标题栏平滑曲线渐变采样点比例（高位维持白度防混字，随后平滑曲线衰减） */
  private titleCurveStop(ratioInTitle: number): number {
    const s: number = this.titleStatusStop();
    return s + (1 - s) * ratioInTitle;
  }

  /** 导航条跳转：点按弹簧动画，拖动 scrub 即时定位 */
  private jumpToQa(markIndex: number, animated: boolean): void {
    if (markIndex < 0 || markIndex >= this.qaMarks.length) {
      return;
    }
    // 列表头部有 80vp 占位 ListItem：目标索引 +1，滚到 START 后再下移对齐消息；
    // 视口已全屏扩展（顶=屏幕顶），偏移需叠加状态栏高度保证落点仍在标题栏下方 96vp
    const target: number = this.qaMarks[markIndex] + 1;
    this.activeQaIndex = markIndex;
    // 跳转守卫：吞掉跳转自身触发的 onScrollIndex（约 100ms 后异步到达一次），
    // 否则落定后首可见项是上一条回答，updateActiveQa 会把 active 回退一格
    this.qaJumpGuardUntil = Date.now() + (animated ? 700 : 400);
    const jumpOffset: LengthMetrics = LengthMetrics.vp(-(96 + this.statusBarVp));
    if (animated) {
      this.getUIContext().animateTo({ duration: 450, curve: curves.springMotion(0.34, 0.9) }, () => {
        this.scroller.scrollToIndex(target, false, ScrollAlign.START, { extraOffset: jumpOffset });
      });
    } else {
      this.scroller.scrollToIndex(target, false, ScrollAlign.START, { extraOffset: jumpOffset });
    }
  }

  // ---------- 会话与抽屉 ----------

  /** 松手/按钮切换：弹簧动画驱动抽屉进度到位 */
  private settleDrawer(open: boolean): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.85) }, () => {
      this.drawerProgress = open ? 1 : 0;
    });
  }

  private toggleDrawer(open: boolean): void {
    if (open) {
      this.refreshSessions();
    }
    this.settleDrawer(open);
  }

  private async refreshSessions(): Promise<void> {
    const token: string = TokenStore.get();
    if (token.length === 0) {
      this.sessions = [];
      return;
    }
    try {
      this.sessions = await listSessions(token);
    } catch (e) {
      this.handleDsError(toDsError(e), '历史会话加载失败');
    }
  }

  private async selectSession(id: string): Promise<void> {
    if (this.isStreaming) {
      this.stopStream();
    }
    const token: string = TokenStore.get();
    if (token.length === 0) {
      this.requireLogin();
      return;
    }
    this.toggleDrawer(false);
    this.currentSessionId = id;
    this.currentTitle = '';
    this.attachments = [];
    this.lastRefFileIds = [];
    for (const s of this.sessions) {
      if (s.id === id) {
        this.currentTitle = s.title;
        break;
      }
    }
    this.messages = [];
    this.rebuildQaMarks();
    TtsService.getInstance().stop();
    DeepSeekTtsService.getInstance().stop();
    this.speakingMsgId = '';
    this.loadingHistory = true;
    try {
      this.messages = await loadMessages(token, id);
    } catch (e) {
      const err: DsApiError = toDsError(e);
      hilog.error(0x0000, 'ChatPage', 'loadMessages failed kind=%{public}d msg=%{public}s',
        err.kind, err.message);
      this.handleDsError(err, '消息加载失败');
    }
    this.rebuildQaMarks();
    this.loadingHistory = false;
    this.treeTipMsgId = 0;
    this.turnParentMsgId = 0;
    if (this.messages.length > 0) {
      this.treeTipMsgId = this.messages[this.messages.length - 1].serverMessageId;
    }
    // 切换会话：回到最新消息。新数据此刻尚未完成布局，同步
    // scrollEdge 会落在旧（空）布局上无效；单次延迟在长对话
    // （大量富文本块）首次布局超时时会失效，列表停在顶部，
    // 故以会话 id 守卫 + 多次退避重试直至确实滚到底（已到末
    // 尾时 scrollEdge 为幂等空操作；用户主动上翻后不再拉回）
    this.nearBottom = true;
    this.distFromBottom = 0;
    this.setScrollBottomVisible(false);
    const sid: string = id;
    const scrollToEnd = (): void => {
      if (this.currentSessionId === sid && this.messages.length > 0 && this.nearBottom) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    };
    setTimeout(scrollToEnd, 100);
    setTimeout(scrollToEnd, 400);
    setTimeout(scrollToEnd, 900);
    setTimeout(scrollToEnd, 1600);
  }

  private newChat(): void {
    if (this.isStreaming) {
      this.stopStream();
    }
    TtsService.getInstance().stop();
    DeepSeekTtsService.getInstance().stop();
    this.speakingMsgId = '';
    this.toggleDrawer(false);
    this.messages = [];
    this.rebuildQaMarks();
    this.attachments = [];
    this.currentSessionId = '';
    this.currentTitle = '';
    this.treeTipMsgId = 0;
    this.turnParentMsgId = 0;
    this.lastRefFileIds = [];
  }

  private openWebMode(): void {
    this.toggleDrawer(false);
    this.pathStack.pushPathByName('WebFallback', '');
  }

  private logout(): void {
    if (this.isStreaming) {
      this.stopStream();
    }
    TtsService.getInstance().stop();
    DeepSeekTtsService.getInstance().stop();
    this.speakingMsgId = '';
    TokenStore.remove();
    this.toggleDrawer(false);
    this.messages = [];
    this.rebuildQaMarks();
    this.attachments = [];
    this.sessions = [];
    this.currentSessionId = '';
    this.currentTitle = '';
    this.treeTipMsgId = 0;
    this.turnParentMsgId = 0;
    this.lastRefFileIds = [];
    this.requireLogin();
  }

  // ---------- 工具 ----------

  private requireLogin(): void {
    this.pathStack.pushPathByName('Login', '');
  }

  private handleDsError(err: DsApiError, fallbackMsg: string): void {
    if (err.kind === DsErrorKind.AuthExpired) {
      TokenStore.remove();
      this.requireLogin();
      return;
    }
    this.showToast(fallbackMsg);
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      // UI 上下文未就绪时忽略
    }
  }

  private scrollBottom(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  /**
   * 顶栏展示标题：优先服务端会话标题，其次首条用户消息摘要
   */
  private displayTitle(): string {
    if (this.currentTitle.length > 0) {
      return this.currentTitle;
    }
    for (const m of this.messages) {
      if (m.role === MessageRole.User) {
        const t: string = m.content.trim();
        if (t.length > 16) {
          return `${t.substring(0, 16)}…`;
        }
        return t;
      }
    }
    return 'DeepSeek';
  }

  private toggleAutoRead(): void {
    this.autoRead = !this.autoRead;
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      SettingsStore.putAutoRead(ctx, this.autoRead);
    }
    this.showToast(this.autoRead ? '已开启自动朗读回答' : '已关闭自动朗读回答');
  }

  private async refreshTitle(): Promise<void> {
    const token: string = TokenStore.get();
    if (token.length === 0 || this.currentSessionId.length === 0) {
      return;
    }
    try {
      const list: SessionSummary[] = await listSessions(token);
      this.sessions = list;
      for (const s of list) {
        if (s.id === this.currentSessionId) {
          this.currentTitle = s.title;
          break;
        }
      }
    } catch (e) {
      // 标题刷新失败不影响主流程
    }
  }

  private speakMessage(msg: ChatMessage): void {
    // 优先 DeepSeek 服务端 TTS（自然人声），仅在无服务端消息号/会话时走端侧合成
    if (msg.serverMessageId > 0 && this.currentSessionId.length > 0) {
      const token: string = TokenStore.get();
      if (token.length > 0) {
        DeepSeekTtsService.getInstance()
          .speak(msg.id, token, this.currentSessionId, msg.serverMessageId)
          .then((ok: boolean): void => {
            // 服务端 TTS 启动失败（票据/连接问题）且用户未切换到其他朗读时，回退端侧
            if (!ok && this.speakingMsgId.length === 0) {
              this.speakMessageLocal(msg);
            }
          });
        return;
      }
    }
    this.speakMessageLocal(msg);
  }

  private speakMessageLocal(msg: ChatMessage): void {
    TtsService.getInstance().speak(msg.id, msg.content).then((ok: boolean): void => {
      if (!ok) {
        if (this.speakingMsgId === msg.id) {
          this.speakingMsgId = '';
        }
        this.showToast('语音合成不可用或已中断');
      }
    });
  }

  private toggleSpeech(msg: ChatMessage): void {
    if (this.speakingMsgId === msg.id) {
      TtsService.getInstance().stop();
      DeepSeekTtsService.getInstance().stop();
      this.speakingMsgId = '';
    } else {
      TtsService.getInstance().stop();
      DeepSeekTtsService.getInstance().stop();
      this.speakMessage(msg);
    }
  }

  // ---------- 语音输入（按住说话、松开发送、上滑取消） ----------

  private async startVoiceInput(): Promise<void> {
    if (this.isStreaming || this.voiceRecording) {
      return;
    }
    if (TokenStore.get().length === 0) {
      this.requireLogin();
      return;
    }
    this.voiceRecording = true;
    this.voiceLiveText = '';
    this.voiceCancelled = false;
    this.voiceStarted = false;
    this.voiceStopRequested = false;
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.voiceRecording = false;
      return;
    }
    const granted: boolean = await AsrService.getInstance().requestMicrophonePermission(ctx);
    if (!granted) {
      this.voiceRecording = false;
      if (!this.voiceCancelled) {
        this.showToast('需要麦克风权限才能使用语音输入');
      }
      return;
    }
    if (this.voiceCancelled || !this.voiceRecording) {
      return;
    }
    const started: boolean = await AsrService.getInstance().start({
      onPartial: (text: string): void => {
        this.voiceLiveText = text;
      },
      onComplete: (fullText: string): void => {
        this.clearVoiceGuard();
        this.voiceRecording = false;
        if (!this.voiceCancelled && fullText.length > 0) {
          this.send(fullText);
        }
      },
      onError: (errorCode: number, errorMessage: string): void => {
        this.clearVoiceGuard();
        this.voiceRecording = false;
        if (!this.voiceCancelled) {
          if (errorCode === 1002200012) {
            this.showToast('需要麦克风权限才能使用语音输入');
          } else {
            this.showToast('语音识别失败，请重试');
          }
        }
      }
    });
    if (!started) {
      this.voiceRecording = false;
      this.showToast('语音识别不可用');
      return;
    }
    this.voiceStarted = true;
    if (this.voiceCancelled) {
      this.cancelVoiceInput();
      return;
    }
    if (this.voiceStopRequested) {
      setTimeout(() => {
        this.endVoiceInput();
      }, 300);
      return;
    }
    // 按住期间会话由 60s maxAudioDuration 封顶，守卫仅作引擎挂死的绝对兜底
    // （旧值 3000 会在用户仍按住时把会话掐断，是语音中断的根因之一）
    this.scheduleVoiceGuard(65000);
  }

  private endVoiceInput(): void {
    if (!this.voiceRecording) {
      return;
    }
    if (!this.voiceStarted) {
      this.voiceStopRequested = true;
      return;
    }
    AsrService.getInstance().finish();
    this.scheduleVoiceGuard(3000);
  }

  private cancelVoiceInput(): void {
    this.voiceCancelled = true;
    AsrService.getInstance().cancel();
    this.clearVoiceGuard();
    this.voiceRecording = false;
    this.voiceLiveText = '';
  }

  /**
   * 兜底守卫：finish 后引擎迟迟不回调时强制复位，避免录音面板卡死
   */
  private scheduleVoiceGuard(timeoutMs: number): void {
    this.clearVoiceGuard();
    this.voiceGuardTimer = setTimeout(() => {
      this.voiceGuardTimer = -1;
      if (this.voiceRecording) {
        AsrService.getInstance().cancel();
        this.voiceRecording = false;
        this.voiceLiveText = '';
      }
    }, timeoutMs);
  }

  private clearVoiceGuard(): void {
    if (this.voiceGuardTimer >= 0) {
      clearTimeout(this.voiceGuardTimer);
      this.voiceGuardTimer = -1;
    }
  }

  // ---------- 文件上传（取证自 Web bundle：/api/v0/file/upload_file + PoW + fetch_files 轮询） ----------

  private async handleAttachFile(): Promise<void> {
    const token: string = TokenStore.get();
    if (token.length === 0) {
      this.requireLogin();
      return;
    }
    const remain: number = MAX_ATTACHMENTS - this.attachments.length;
    if (remain <= 0) {
      this.showToast(`最多添加 ${MAX_ATTACHMENTS} 个文件`);
      return;
    }
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = remain;
    options.fileSuffixFilters = FILE_SUFFIX_FILTERS;
    let uris: string[] = [];
    try {
      uris = await docPicker.select(options);
    } catch (e) {
      // 用户取消选择或拉起失败，静默返回
      return;
    }
    for (const uri of uris) {
      await this.uploadUriFile(token, uri);
    }
  }

  private async uploadUriFile(token: string, uri: string): Promise<void> {
    const att: ChatAttachment =
      new ChatAttachment(`att_${Date.now()}_${this.attachments.length}`, this.fileNameFromUri(uri), 0);
    this.attachments.push(att);
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        throw new DsApiError(DsErrorKind.Server, '不能上传空文件');
      }
      if (size > MAX_UPLOAD_FILE_BYTES) {
        throw new DsApiError(DsErrorKind.Server, '单个文件不能超过 100MB');
      }
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      file = null;
      att.fileSize = size;
      const uploaded: DsUploadedFile = await uploadFile(token, att.fileName, this.mimeOf(att.fileName), buf,
        this.thinkingEnabled, (percent: number): void => {
          att.percent = percent;
        });
      att.fileId = uploaded.id;
      att.status = AttachmentStatus.Parsing;
      this.pollAttachment(token, att);
    } catch (e) {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (ignore) {
          // 关闭失败忽略
        }
      }
      const err: DsApiError = toDsError(e);
      att.status = AttachmentStatus.Failed;
      att.errorMsg = err.message.length > 0 ? err.message : '上传失败';
      hilog.error(0x0000, 'ChatPage', 'uploadFile failed kind=%{public}d msg=%{public}s', err.kind, err.message);
      if (err.kind === DsErrorKind.AuthExpired) {
        TokenStore.remove();
        this.requireLogin();
      }
    }
  }

  /** 轮询文件解析状态直至终态（SUCCESS → 就绪，其余终态 → 失败） */
  private async pollAttachment(token: string, att: ChatAttachment): Promise<void> {
    try {
      const ready: DsUploadedFile = await waitForFileReady(token, att.fileId, 180000);
      if (this.findAttachment(att.localId) === null) {
        return;
      }
      if (ready.status === DsFileStatus.SUCCESS) {
        att.status = AttachmentStatus.Ready;
      } else {
        att.status = AttachmentStatus.Failed;
        att.errorMsg = this.parseErrorText(ready.status);
      }
    } catch (e) {
      if (this.findAttachment(att.localId) === null) {
        return;
      }
      const err: DsApiError = toDsError(e);
      att.status = AttachmentStatus.Failed;
      att.errorMsg = err.message;
    }
  }

  private parseErrorText(status: string): string {
    if (status === DsFileStatus.CONTENT_EMPTY) {
      return '文件内容为空';
    }
    if (status === DsFileStatus.CONTENT_TOO_LONG) {
      return '文件内容过长';
    }
    if (status === DsFileStatus.CONTENT_FILTER) {
      return '文件内容不合规';
    }
    if (status === DsFileStatus.CANCELLED) {
      return '解析已取消';
    }
    return '文件解析失败';
  }

  private findAttachment(localId: string): ChatAttachment | null {
    for (const a of this.attachments) {
      if (a.localId === localId) {
        return a;
      }
    }
    return null;
  }

  private removeAttachment(localId: string): void {
    const next: ChatAttachment[] = [];
    for (const a of this.attachments) {
      if (a.localId !== localId) {
        next.push(a);
      }
    }
    this.attachments = next;
  }

  private fileNameFromUri(uri: string): string {
    let name: string = uri;
    try {
      const decoded: string = decodeURIComponent(uri);
      const idx: number = decoded.lastIndexOf('/');
      name = idx >= 0 ? decoded.substring(idx + 1) : decoded;
    } catch (e) {
      const idx: number = uri.lastIndexOf('/');
      name = idx >= 0 ? uri.substring(idx + 1) : uri;
    }
    return name.length > 0 ? name : '未命名文件';
  }

  private mimeOf(fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const ext: string = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    const mimeMap: Record<string, string> = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'csv': 'text/csv',
      'txt': 'text/plain',
      'md': 'text/markdown',
      'json': 'application/json',
      'xml': 'application/xml',
      'html': 'text/html',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'webp': 'image/webp',
      'gif': 'image/gif',
      'bmp': 'image/bmp'
    };
    const mime: string | undefined = mimeMap[ext];
    return mime !== undefined ? mime : 'application/octet-stream';
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      // 历史抽屉（push 模式：面板固定左侧，由聊天页整体右移露出；拖动/打开时挂载）
      if (this.drawerProgress > 0) {
        HistoryDrawer({
          sessions: this.sessions,
          activeSessionId: this.currentSessionId,
          userName: this.userName,
          avatarUrl: this.avatarUrl,
          progress: this.drawerProgress,
          statusBarVp: this.statusBarVp,
          navBarVp: this.navBarVp,
          onClose: (): void => {
            this.toggleDrawer(false);
          },
          onSelectSession: (id: string): void => {
            this.selectSession(id);
          },
          onOpenWebMode: (): void => {
            this.openWebMode();
          },
          onLogout: (): void => {
            this.logout();
          }
        })
      }

      // 聊天整页（push 位移 + 景深缩放/圆角/右缘投影随进度驱动）
      Column() {
        // 内容区（消息列表整屏滚动，上下由悬浮渐变层收边）
        Stack({ alignContent: Alignment.Bottom }) {
          Stack() {
            if (this.messages.length === 0) {
              Column({ space: 16 }) {
                Image($r('app.media.whale_logo'))
                  .width(68)
                  .height(58)
                  .objectFit(ImageFit.Contain)

                Text('今天有什么可以帮您？')
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .height('100%')
            } else {
              // 虚拟滚动长列表：仅渲染可视区附近的对话项，流式重排开销与历史长度解耦
              List({ scroller: this.scroller, space: 16 }) {
                // 头部占位：不可用 List 的 top padding——padding 会把子项渲染裁剪到内缩视口（实机像素级验证），
                // 改用占位项保持"滚到顶时首条消息停在标题栏下方"的停位（状态栏 + 80 + space 16）
                ListItem() {
                  Column()
                    .width('100%')
                    .height(80 + this.statusBarVp)
                }
                Repeat(this.messages)
                  .virtualScroll({ totalCount: this.messages.length })
                  .key((m: ChatMessage): string => m.id)
                  .each((ri: RepeatItem<ChatMessage>) => {
                    ListItem() {
                      MessageItem({
                        msg: ri.item,
                        isLast: ri.index === this.messages.length - 1,
                        isSpeaking: this.speakingMsgId === ri.item.id,
                        onOpenReference: (url: string, title: string): void => {
                          this.confirmOpenReference(url, title);
                        },
                        onRegenerate: (): void => {
                          this.regenerate();
                        },
                        onToggleSpeak: (): void => {
                          this.toggleSpeech(ri.item);
                        }
                      })
                    }
                  })
                // 尾部占位：滚到底时最后内容停在悬浮 dock 上方（导航区 + 160 + space 16）
                ListItem() {
                  Column()
                    .width('100%')
                    .height(160 + this.navBarVp)
                }
              }
              .width('100%')
              .height('100%')
              .padding({ left: 16, right: 16 })
              // 全屏沉浸：列表视口扩展进状态栏与导航区，消息文字贯穿整个屏幕（短信式）
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
              .scrollBar(BarState.Off)
              .cachedCount(3)
              .onDidScroll((scrollOffset: number, _scrollState: ScrollState) => {
                // 列表内容上移（向底部滚动）offset 为正；上翻离开底部累积距离
                this.distFromBottom -= scrollOffset;
                if (this.distFromBottom < 0) {
                  this.distFromBottom = 0;
                }
                const near: boolean = this.distFromBottom < NEAR_BOTTOM_THRESHOLD;
                if (near !== this.nearBottom) {
                  this.nearBottom = near;
                  this.setScrollBottomVisible(!near && this.messages.length > 0);
                }
              })
              .onScrollIndex((first: number, _last: number) => {
                this.updateActiveQa(Math.max(0, first - 1));
              })
              .onReachEnd(() => {
                this.distFromBottom = 0;
                if (!this.nearBottom) {
                  this.nearBottom = true;
                  this.setScrollBottomVisible(false);
                }
              })
            }

            // 右侧问答导航条（≥2 问显示）：圆点=问题，竖条=当前问答，点/拖快速跳转
            if (this.qaMarks.length >= 2) {
              QaNavRail({
                marks: this.qaMarks,
                activeIndex: this.activeQaIndex,
                onJump: (markIndex: number, animated: boolean): void => {
                  this.jumpToQa(markIndex, animated);
                }
              })
                .position({ x: '100%', y: '50%' })
                .markAnchor({ x: '100%', y: '50%' })
                .translate({ x: 10 })
            }

            if (this.loadingHistory) {
              LoadingProgress()
                .width(32)
                .height(32)
                .color($r('app.color.brand'))
            }
          }
          .width('100%')
          .height('100%')

          // 悬浮渐变标题栏：整栏单渐变（上端实白保证图标可读 → 下端渐透明），消息滚动穿过整栏时持续淡出
          // 注意：colors 数组不可混用 Resource 与 string（Resource 在首位时渐变失效，实机验证），两端均用字符串
          if (this.messages.length > 0) {
            Column() {
              Row() {
                SymbolGlyph($r('sys.symbol.list_bullet'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_primary')])
                  .padding(8)
                  .borderRadius(20)
                  .backgroundEffect({
                    radius: 18,
                    saturation: 1.5,
                    brightness: 1.15,
                    color: 'rgba(255, 255, 255, 0.55)',
                    adaptiveColor: AdaptiveColor.DEFAULT
                  })
                  .border({ width: 1, color: 'rgba(255, 255, 255, 0.9)' })
                  .shadow({
                    radius: 8,
                    color: 'rgba(38, 38, 38, 0.10)',
                    offsetX: 0,
                    offsetY: 2
                  })
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => {
                    this.toggleDrawer(true);
                  })
                Text(this.displayTitle())
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                // 白底液态玻璃 + 品牌蓝加号（新对话）
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(18)
                  .fontColor([$r('app.color.brand')])
                  .padding(10)
                  .borderRadius(19)
                  .backgroundEffect({
                    radius: 18,
                    saturation: 1.5,
                    brightness: 1.15,
                    color: 'rgba(255, 255, 255, 0.55)',
                    adaptiveColor: AdaptiveColor.DEFAULT
                  })
                  .border({ width: 1, color: 'rgba(255, 255, 255, 0.9)' })
                  .shadow({
                    radius: 8,
                    color: 'rgba(38, 38, 38, 0.10)',
                    offsetX: 0,
                    offsetY: 2
                  })
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => {
                    this.newChat();
                  })
                // 打开态：与加号按钮同款白底液态玻璃背景；关闭态：灰底图标
                if (this.autoRead) {
                  SymbolGlyph($r('sys.symbol.speaker_wave_2_fill'))
                    .fontSize(18)
                    .fontColor([$r('app.color.brand')])
                    .padding(10)
                    .borderRadius(19)
                    .backgroundEffect({
                      radius: 18,
                      saturation: 1.5,
                      brightness: 1.15,
                      color: 'rgba(255, 255, 255, 0.55)',
                      adaptiveColor: AdaptiveColor.DEFAULT
                    })
                    .border({ width: 1, color: 'rgba(255, 255, 255, 0.9)' })
                    .shadow({
                      radius: 8,
                      color: 'rgba(38, 38, 38, 0.10)',
                      offsetX: 0,
                      offsetY: 2
                    })
                    .margin({ left: 4 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.toggleAutoRead();
                    })
                } else {
                  SymbolGlyph($r('sys.symbol.speaker_slash'))
                    .fontSize(18)
                    .fontColor([$r('app.color.text_secondary')])
                    .padding(8)
                    .backgroundColor($r('app.color.input_bg'))
                    .borderRadius(16)
                    .margin({ left: 4 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.toggleAutoRead();
                    })
                }
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            }
            .width('100%')
            // 顶部曲线渐变：顶端 90% 渐隐，标题行高位维持 82%~88% 浓度防背景混字，底部平滑曲线淡出
            .padding({ top: this.statusBarVp, bottom: 10 })
            .linearGradient({
              angle: 180,
              colors: [
                ['rgba(255,255,255,0.90)', 0],
                ['rgba(255,255,255,0.88)', this.titleStatusStop()],
                ['rgba(255,255,255,0.82)', this.titleCurveStop(0.40)],
                ['rgba(255,255,255,0.58)', this.titleCurveStop(0.72)],
                ['rgba(255,255,255,0.22)', this.titleCurveStop(0.90)],
                ['rgba(255,255,255,0)', 1]
              ]
            })
            .position({ x: 0, y: 0 })
            .hitTestBehavior(HitTestMode.Transparent)
          }

          // 首页顶部：左上角呼出侧边栏按钮 + 右上角自动朗读开关（样式与聊天页标题栏保持一致）
          if (this.messages.length === 0) {
            Stack({ alignContent: Alignment.Top }) {
              Row() {
                SymbolGlyph($r('sys.symbol.list_bullet'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_primary')])
                  .padding(8)
                  .borderRadius(20)
                  .backgroundEffect({
                    radius: 18,
                    saturation: 1.5,
                    brightness: 1.15,
                    color: 'rgba(255, 255, 255, 0.55)',
                    adaptiveColor: AdaptiveColor.DEFAULT
                  })
                  .border({ width: 1, color: 'rgba(255, 255, 255, 0.9)' })
                  .shadow({
                    radius: 8,
                    color: 'rgba(38, 38, 38, 0.10)',
                    offsetX: 0,
                    offsetY: 2
                  })
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => {
                    this.toggleDrawer(true);
                  })
                Blank()
                // 打开态：与加号按钮同款白底液态玻璃背景；关闭态：灰底图标
                if (this.autoRead) {
                  SymbolGlyph($r('sys.symbol.speaker_wave_2_fill'))
                    .fontSize(18)
                    .fontColor([$r('app.color.brand')])
                    .padding(10)
                    .borderRadius(19)
                    .backgroundEffect({
                      radius: 18,
                      saturation: 1.5,
                      brightness: 1.15,
                      color: 'rgba(255, 255, 255, 0.55)',
                      adaptiveColor: AdaptiveColor.DEFAULT
                    })
                    .border({ width: 1, color: 'rgba(255, 255, 255, 0.9)' })
                    .shadow({
                      radius: 8,
                      color: 'rgba(38, 38, 38, 0.10)',
                      offsetX: 0,
                      offsetY: 2
                    })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.toggleAutoRead();
                    })
                } else {
                  SymbolGlyph($r('sys.symbol.speaker_slash'))
                    .fontSize(18)
                    .fontColor([$r('app.color.text_secondary')])
                    .padding(8)
                    .backgroundColor($r('app.color.input_bg'))
                    .borderRadius(16)
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.toggleAutoRead();
                    })
                }
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: this.statusBarVp + 6 })
            }
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
          }

          // 液态玻璃回底按钮：用户上翻离开底部时浮现（底部对齐 + 上移避开输入栏）
          if (this.showScrollBottom) {
            Row() {
              Blank()
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(20)
                .fontColor([$r('app.color.text_primary')])
                .padding(13)
                .borderRadius(23)
                .backgroundEffect({
                  radius: 24,
                  saturation: 1.5,
                  brightness: 1.15,
                  color: 'rgba(255, 255, 255, 0.55)',
                  adaptiveColor: AdaptiveColor.DEFAULT
                })
                .border({ width: 1, color: 'rgba(255, 255, 255, 0.9)' })
                .shadow({
                  radius: 8,
                  color: 'rgba(38, 38, 38, 0.10)',
                  offsetX: 0,
                  offsetY: 2
                })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  this.scrollToLatest();
                })
            }
            .width('100%')
            .padding({ right: 14 })
            .margin({ bottom: this.inputBarHeight + 38 + this.navBarVp })
            .hitTestBehavior(HitTestMode.Transparent)
            .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 })))
          }

          // 悬浮输入 dock：左右留边、圆角软阴影的悬浮卡片，消息全屏滚动从其后方穿过
          Column() {
            Column() {
              InputBar({
                isStreaming: this.isStreaming,
                thinkingEnabled: this.thinkingEnabled,
                searchEnabled: this.searchEnabled,
                voiceRecording: this.voiceRecording,
                voiceLiveText: this.voiceLiveText,
                attachments: this.attachments,
                onSend: (text: string): void => {
                  this.send(text);
                },
                onStop: (): void => {
                  this.stopStream();
                },
                onToggleThinking: (): void => {
                  this.thinkingEnabled = !this.thinkingEnabled;
                  const ctx = this.getUIContext().getHostContext();
                  if (ctx !== undefined) {
                    SettingsStore.putThinkingEnabled(ctx, this.thinkingEnabled);
                  }
                },
                onToggleSearch: (): void => {
                  this.searchEnabled = !this.searchEnabled;
                  const ctx = this.getUIContext().getHostContext();
                  if (ctx !== undefined) {
                    SettingsStore.putSearchEnabled(ctx, this.searchEnabled);
                  }
                },
                onAttachFile: (): void => {
                  this.handleAttachFile();
                },
                onRemoveAttachment: (localId: string): void => {
                  this.removeAttachment(localId);
                },
                onVoicePressStart: (): void => {
                  this.startVoiceInput();
                },
                onVoicePressEnd: (): void => {
                  this.endVoiceInput();
                },
                onVoicePressCancel: (): void => {
                  this.cancelVoiceInput();
                }
              })
            }
            .width('100%')
            .padding({ left: 10, right: 10, bottom: 6, top: 2 })
            .backgroundColor($r('app.color.chat_bg'))
            // 悬浮 dock 卡片：左右留边 + 大圆角 + 软阴影，内容量高不含 margin
            .borderRadius(26)
            .shadow({ radius: 20, color: 'rgba(38, 38, 38, 0.08)', offsetX: 0, offsetY: 4 })
            .margin({ left: 12, right: 12 })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              // 动态量取输入栏高度：回底按钮随输入栏（附件行/语音行）伸缩而正确上移
              const h: number = Number(newArea.height);
              if (Number.isFinite(h) && h > 0) {
                this.inputBarHeight = h;
              }
            })
            // 底部渐隐条：锚定屏幕最底端，向上渐变至输入栏下沿（最小 50%，底端最大 90%）
            Column()
              .width('100%')
              .height(this.navBarVp + 8)
              .linearGradient({
                angle: 180,
                colors: [['rgba(255,255,255,0.50)', 0], ['rgba(255,255,255,0.90)', 1]]
              })
              .hitTestBehavior(HitTestMode.Transparent)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      // push 景深：整页右移露出抽屉 + 轻微缩小成卡片 + 圆角与右缘投影
      .translate({ x: this.drawerProgress * DRAWER_WIDTH })
      .scale({
        x: 1 - this.drawerProgress * (1 - DRAWER_MAX_SCALE),
        y: 1 - this.drawerProgress * (1 - DRAWER_MAX_SCALE)
      })
      .borderRadius(this.drawerProgress * 24)
      .shadow({ radius: 20, color: 'rgba(38, 38, 38, 0.12)', offsetX: 6, offsetY: 0 })
      // 纯白底：自绘状态栏/小白条安全区，与页面无缝一体（抽屉打开时整页右移露出抽屉）
      .backgroundColor($r('app.color.chat_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 全屏横向拖动跟手驱动抽屉（挂根 Stack：聊天页与抽屉面板上均可拖动；列表垂直滚动按方向仲裁互不影响）
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: DRAWER_DRAG_DISTANCE })
        .onActionStart((e: GestureEvent): void => {
          this.drawerDragBase = this.drawerProgress;
          // 起手即挂载抽屉：progress≈0 时面板原位全覆盖，无闪烁
          if (this.drawerProgress <= 0) {
            this.drawerProgress = 0.001;
          }
        })
        .onActionUpdate((e: GestureEvent): void => {
          const p: number = this.drawerDragBase + e.offsetX / DRAWER_WIDTH;
          this.drawerProgress = Math.min(1, Math.max(0, p));
        })
        .onActionEnd((e: GestureEvent): void => {
          // 快速甩动按方向判定；慢速释放按拖动方向意图 + 宽松位置带（左拖 75% 内即关、右拖 25% 外即开）
          let open: boolean;
          if (e.velocityX > DRAWER_FLING_SPEED) {
            open = true;
          } else if (e.velocityX < -DRAWER_FLING_SPEED) {
            open = false;
          } else if (e.offsetX < 0) {
            open = this.drawerProgress >= 0.75;
          } else {
            open = this.drawerProgress > 0.25;
          }
          this.settleDrawer(open);
        })
    )
  }
}

