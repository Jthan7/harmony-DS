import { AttachmentStatus, ChatAttachment } from '../model/ChatModels';

@ComponentV2
export struct InputBar {
  @Param isStreaming: boolean = false;
  @Param thinkingEnabled: boolean = false;
  @Param searchEnabled: boolean = false;
  @Param voiceRecording: boolean = false;
  @Param voiceLiveText: string = '';
  @Param attachments: ChatAttachment[] = [];
  @Event onSend: (text: string) => void = (_text: string) => {
  };
  @Event onStop: () => void = () => {
  };
  @Event onToggleThinking: () => void = () => {
  };
  @Event onToggleSearch: () => void = () => {
  };
  @Event onAttachFile: () => void = () => {
  };
  @Event onRemoveAttachment: (localId: string) => void = (_localId: string) => {
  };
  @Event onVoicePressStart: () => void = () => {
  };
  @Event onVoicePressEnd: () => void = () => {
  };
  @Event onVoicePressCancel: () => void = () => {
  };
  @Local draft: string = '';
  @Local voiceMode: boolean = false;
  @Local voiceCancelReady: boolean = false;
  private voiceDownY: number = -1;

  private doSend(): void {
    const text: string = this.draft.trim();
    if (text.length === 0 || this.isStreaming) {
      return;
    }
    this.draft = '';
    this.onSend(text);
  }

  private attachmentStatusText(att: ChatAttachment): string {
    if (att.status === AttachmentStatus.Uploading) {
      return att.percent > 0 ? `上传中 ${att.percent}%` : '上传中…';
    }
    if (att.status === AttachmentStatus.Parsing) {
      return '解析中…';
    }
    if (att.status === AttachmentStatus.Failed) {
      return att.errorMsg.length > 0 ? att.errorMsg : '上传失败';
    }
    return '已就绪';
  }

  build() {
    Column() {
      // 待发送附件 chips（横向滚动）
      if (this.attachments.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.attachments, (att: ChatAttachment) => {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.doc_text'))
                  .fontSize(16)
                  .fontColor([att.status === AttachmentStatus.Failed
                    ? $r('app.color.danger') : $r('app.color.brand')])
                Column({ space: 2 }) {
                  Text(att.fileName)
                    .fontSize(13)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 130 })
                  Text(this.attachmentStatusText(att))
                    .fontSize(11)
                    .fontColor(att.status === AttachmentStatus.Failed
                      ? $r('app.color.danger') : $r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(12)
                  .fontColor([$r('app.color.text_secondary')])
                  .padding(5)
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => {
                    this.onRemoveAttachment(att.localId);
                  })
              }
              .padding({ left: 10, right: 5, top: 8, bottom: 8 })
              .borderRadius(12)
              .backgroundColor($r('app.color.input_bg'))
              .border({
                width: 1,
                color: att.status === AttachmentStatus.Ready
                  ? $r('app.color.brand') : $r('app.color.divider_color')
              })
            }, (att: ChatAttachment) => att.localId)
          }
          .padding({ left: 12, right: 12, top: 10 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }

      // 输入区域：语音模式 / 文本模式
      if (this.voiceMode) {
        // 语音输入区（节点常驻、仅切换属性，确保按住期间触摸流不中断）
        Column() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.mic'))
              .fontSize(18)
              .fontColor([$r('app.color.text_secondary')])
              .visibility(this.voiceRecording ? Visibility.None : Visibility.Visible)
            Text(this.voiceRecording ? (this.voiceLiveText.length > 0 ? this.voiceLiveText : '正在聆听…') : '按住 说话')
              .fontSize(17)
              .fontWeight(this.voiceRecording ? FontWeight.Normal : FontWeight.Medium)
              .fontColor(this.voiceRecording
                ? (this.voiceLiveText.length > 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                : $r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          Text(this.voiceCancelReady ? '松开手指，取消发送' : '松开发送，上滑取消')
            .fontSize(12)
            .fontColor(this.voiceCancelReady ? $r('app.color.danger') : $r('app.color.text_secondary'))
            .margin({ top: 6 })
            .visibility(this.voiceRecording ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .constraintSize({ minHeight: 52 })
        .justifyContent(FlexAlign.Center)
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .margin({ left: 4, right: 4, top: 4 })
        .borderRadius(26)
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            const downPoint: TouchObject = event.touches[0];
            this.voiceDownY = downPoint.y;
            this.voiceCancelReady = false;
            this.onVoicePressStart();
          } else if (event.type === TouchType.Move) {
            const movePoint: TouchObject = event.touches[0];
            if (this.voiceDownY - movePoint.y > 100) {
              this.voiceCancelReady = true;
            } else if (this.voiceCancelReady) {
              this.voiceCancelReady = false;
            }
          } else if (event.type === TouchType.Up) {
            if (this.voiceCancelReady) {
              this.onVoicePressCancel();
            } else {
              this.onVoicePressEnd();
            }
            this.voiceCancelReady = false;
            this.voiceDownY = -1;
          } else if (event.type === TouchType.Cancel) {
            // 触摸流被打断时保留已识别内容（finish 正常发送），而非整段丢弃；
            // 显式上滑取消仍走 Up + voiceCancelReady 分支
            this.onVoicePressEnd();
            this.voiceCancelReady = false;
            this.voiceDownY = -1;
          }
        })
        // 子级手势抢占：按住说话期间手指横移时由本节点 pan 胜出，
        // 阻止父级全屏抽屉 PanGesture 跨组件抢占触摸流（否则 onTouch 收到 Cancel 中断识别）；
        // 注意触摸/手势坐标均为 vp（100vp ≈ 屏高 1/10+），pan 路径与 onTouch 路径阈值保持一致
        .priorityGesture(
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
            .onActionUpdate((event: GestureEvent): void => {
              this.voiceCancelReady = event.offsetY < -100;
            })
        )
      } else {
        TextArea({ text: this.draft, placeholder: '给 DeepSeek 发送消息' })
          .placeholderColor($r('app.color.text_secondary'))
          .fontSize(17)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .caretColor($r('app.color.brand'))
          .constraintSize({ minHeight: 46, maxHeight: 120 })
          .maxLines(5)
          .padding({ left: 16, right: 16, top: 12, bottom: 6 })
          .width('100%')
          .onChange((value: string) => {
            this.draft = value;
          })
      }

      // 底部工具行（深度思考、联网搜索、附件、语音、发送）
      Row() {
        // 左侧：模式开关药丸
        Row({ space: 8 }) {
          // 深度思考 (R1)
          Row({ space: 5 }) {
            if (this.thinkingEnabled) {
              Column()
                .width(6)
                .height(6)
                .borderRadius(3)
                .backgroundColor($r('app.color.brand'))
            }
            Text('深度思考')
              .fontSize(13)
              .fontWeight(this.thinkingEnabled ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.thinkingEnabled ? $r('app.color.brand') : $r('app.color.text_secondary'))
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor(this.thinkingEnabled ? $r('app.color.user_bubble') : Color.Transparent)
          .border({
            width: 1,
            color: this.thinkingEnabled ? $r('app.color.brand') : $r('app.color.divider_color')
          })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.onToggleThinking();
          })

          // 联网搜索
          Row({ space: 5 }) {
            if (this.searchEnabled) {
              Column()
                .width(6)
                .height(6)
                .borderRadius(3)
                .backgroundColor($r('app.color.brand'))
            }
            Text('联网搜索')
              .fontSize(13)
              .fontWeight(this.searchEnabled ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.searchEnabled ? $r('app.color.brand') : $r('app.color.text_secondary'))
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor(this.searchEnabled ? $r('app.color.user_bubble') : Color.Transparent)
          .border({
            width: 1,
            color: this.searchEnabled ? $r('app.color.brand') : $r('app.color.divider_color')
          })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.onToggleSearch();
          })
        }

        Blank()

        // 右侧操作按钮组
        Row({ space: 6 }) {
          // 附件
          SymbolGlyph($r('sys.symbol.paperclip'))
            .fontSize(20)
            .fontColor([$r('app.color.text_secondary')])
            .padding(8)
            .borderRadius(18)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.onAttachFile();
            })

          // 语音输入模式切换（语音 ↔ 键盘）
          SymbolGlyph(this.voiceMode ? $r('sys.symbol.keyboard') : $r('sys.symbol.mic'))
            .fontSize(20)
            .fontColor([this.voiceMode ? $r('app.color.brand') : $r('app.color.text_secondary')])
            .padding(8)
            .borderRadius(18)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              if (!this.voiceRecording) {
                this.voiceMode = !this.voiceMode;
              }
            })

          // 发送 / 停止
          if (this.isStreaming) {
            Button() {
              Column()
                .width(14)
                .height(14)
                .borderRadius(2)
                .backgroundColor(Color.White)
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('app.color.brand'))
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => {
              this.onStop();
            })
          } else {
            Button() {
              Text('↑')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor(this.draft.trim().length > 0 ? $r('app.color.brand') : $r('app.color.divider_color'))
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => {
              this.doSend();
            })
          }
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 10, top: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }
}
