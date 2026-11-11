import { ChatMessage, MessageRole, MessageStatus } from '../model/ChatModels';
import { MarkdownRenderer, copyToClipboard } from './MarkdownRenderer';
import { ThinkingBlock } from './ThinkingBlock';

@ComponentV2
export struct MessageItem {
  @Param msg: ChatMessage = new ChatMessage('', MessageRole.User, '');
  @Param isLast: boolean = false;
  @Param isSpeaking: boolean = false;
  @Event onRegenerate: () => void = () => {
  };
  @Event onToggleSpeak: () => void = () => {
  };
  @Event onOpenReference: (url: string, title: string) => void = (_url: string, _title: string): void => {
  };

  build() {
    if (this.msg.role === MessageRole.User) {
      Row() {
        Blank()
        Column({ space: 6 }) {
          // 附件文件名列表（随消息上传的文件）
          ForEach(this.msg.attachmentNames, (name: string) => {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.doc_text'))
                .fontSize(14)
                .fontColor([$r('app.color.brand')])
              Text(name)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 180 })
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor('rgba(77, 107, 254, 0.08)')
          }, (name: string, index: number) => `${index}_${name}`)

          if (this.msg.content.length > 0) {
            Text(this.msg.content)
              .fontSize(18)
              .lineHeight(30)
              .fontColor($r('app.color.text_primary'))
              // 长按选择文字并复制（系统选择菜单）
              .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
              .copyOption(CopyOptions.LocalDevice)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .constraintSize({ maxWidth: '82%' })
        .borderRadius(20)
        // 白卡片悬浮气泡：不透明白底 + 白描边 + 投影（纯白页面上靠投影分离，悬浮感清晰）
        .backgroundColor(Color.White)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.8)' })
        .shadow({
          radius: 12,
          color: 'rgba(38, 38, 38, 0.10)',
          offsetX: 0,
          offsetY: 3
        })
      }
      .width('100%')
    } else {
      Column({ space: 10 }) {
        // 联网搜索过程状态：进行中显示转圈提示，结束后显示结果数小结
        if (this.msg.searching) {
          Row({ space: 6 }) {
            LoadingProgress()
              .width(15)
              .height(15)
              .color($r('app.color.text_secondary'))
            Text(this.msg.searchHint.length > 0 ? `正在联网搜索：${this.msg.searchHint}` : '正在联网搜索…')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .transition(
            TransitionEffect.OPACITY
              .animation({ duration: 200, curve: Curve.EaseOut })
          )
        } else if (this.msg.searchResults.length > 0) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(14)
              .fontColor([$r('app.color.text_secondary')])
            Text(`已搜索 ${this.msg.searchResults.length} 条结果`)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .transition(
            TransitionEffect.OPACITY
              .animation({ duration: 200, curve: Curve.EaseOut })
          )
        }
        if (this.msg.thinking.length > 0) {
          ThinkingBlock({
            thinkingText: this.msg.thinking,
            isThinking: this.msg.status === MessageStatus.Streaming && this.msg.content.length === 0,
            elapsedMs: this.msg.thinkingElapsedMs
          })
        } else if (this.msg.status === MessageStatus.Streaming && this.msg.content.length === 0) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color($r('app.color.text_secondary'))
        }

        if (this.msg.content.length > 0) {
          MarkdownRenderer({
            rawText: this.msg.content,
            searchResults: this.msg.searchResults,
            onReferenceClick: (url: string, title: string): void => {
              this.onOpenReference(url, title);
            }
          })
        }

        if (this.msg.status === MessageStatus.Error) {
          Text(this.msg.errorMsg)
            .fontSize(16)
            .fontColor($r('app.color.danger'))
            .width('100%')
          if (this.isLast) {
            Text('重试')
              .fontSize(16)
              .fontColor($r('app.color.brand'))
              .padding({ top: 2, bottom: 2 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
              .onClick(() => {
                this.onRegenerate();
              })
          }
        }

        // 官方风格消息底栏操作区（复制、朗读/停止、重新生成）
        if (this.msg.status === MessageStatus.Done && this.msg.content.length > 0) {
          Row({ space: 16 }) {
            // 复制回答
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.doc_text_on_doc_text'))
                .fontSize(16)
                .fontColor([$r('app.color.text_secondary')])
              Text('复制')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding({ top: 4, bottom: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              copyToClipboard(this.msg.content);
              this.getUIContext().getPromptAction().showToast({ message: '已复制回答' });
            })

            // 朗读语音 / 停止朗读
            Row({ space: 5 }) {
              SymbolGlyph(this.isSpeaking ? $r('sys.symbol.speaker_wave_3_fill') : $r('sys.symbol.speaker_wave_2'))
                .fontSize(16)
                .fontColor(this.isSpeaking ? [$r('app.color.brand')] : [$r('app.color.text_secondary')])
              Text(this.isSpeaking ? '停止朗读' : '朗读')
                .fontSize(14)
                .fontColor(this.isSpeaking ? $r('app.color.brand') : $r('app.color.text_secondary'))
            }
            .padding({ top: 4, bottom: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.onToggleSpeak();
            })

            // 重新生成（仅针对最新一条助手回答）
            if (this.isLast) {
              Row({ space: 5 }) {
                SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                  .fontSize(16)
                  .fontColor([$r('app.color.text_secondary')])
                Text('重新生成')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
              }
              .padding({ top: 4, bottom: 4 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
              .onClick(() => {
                this.onRegenerate();
              })
            }
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 4, bottom: 8 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }
}
