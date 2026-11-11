@ComponentV2
export struct ThinkingBlock {
  @Param thinkingText: string = '';
  @Param isThinking: boolean = false;
  @Param elapsedMs: number = 0;
  @Local expanded: boolean = false;

  private toggleExpanded(): void {
    // 展开态切换置于 animateTo 作用域：箭头旋转与正文过渡动画才会播放
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.expanded = !this.expanded;
    });
  }

  build() {
    Column({ space: 8 }) {
      if (this.isThinking) {
        // 流式思考中：默认展开实时滚动显示思考文本，回答开始自动折叠
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.text_secondary'))
          Text('正在深度思考…')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .transition(
          TransitionEffect.OPACITY
            .animation({ duration: 200, curve: Curve.EaseOut })
        )
        if (this.thinkingText.length > 0) {
          Text(this.thinkingText)
            .fontSize(16)
            .lineHeight(26)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            // 长按选择文字并复制（系统选择菜单）
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
            .copyOption(CopyOptions.LocalDevice)
            .transition(
              TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: -4 }))
                .animation({ duration: 200, curve: Curve.EaseOut })
            )
        }
      } else {
        Row({ space: 4 }) {
          Text(this.elapsedMs > 0 ? `已深度思考（用时 ${(this.elapsedMs / 1000).toFixed(0)} 秒）` : '已深度思考')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
            .rotate({ angle: this.expanded ? 180 : 0 })
        }
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .onClick(() => {
          this.toggleExpanded();
        })
        .width('100%')
        .transition(
          TransitionEffect.OPACITY
            .animation({ duration: 200, curve: Curve.EaseOut })
        )
        if (this.expanded && this.thinkingText.length > 0) {
          Text(this.thinkingText)
            .fontSize(16)
            .lineHeight(26)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            // 长按选择文字并复制（系统选择菜单）
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
            .copyOption(CopyOptions.LocalDevice)
            .transition(
              TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: -4 }))
                .animation({ duration: 200, curve: Curve.EaseOut })
            )
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
