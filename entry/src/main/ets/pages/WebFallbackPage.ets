import { webview } from '@kit.ArkWeb';

/**
 * 网页模式兜底：原生通道失效时，直接用 Web 组件加载官方网页版。
 * 登录态由 Web Cookie 沙箱保持，功能 100% 跟随官方。
 */
@Builder
export function WebFallbackBuilder(): void {
  WebFallbackPage()
}

@ComponentV2
export struct WebFallbackPage {
  pathStack: NavPathStack = new NavPathStack();
  private controller: webview.WebviewController = new webview.WebviewController();
  @Local targetUrl: string = 'https://chat.deepseek.com';

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Web({ src: this.targetUrl, controller: this.controller })
          .domStorageAccess(true)
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([Color.White])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('#66000000')
        .margin({ left: 12, top: 8 })
        .onClick(() => {
          this.pathStack.pop();
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.pathStack.pop();
      return true;
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
      // Markdown 链接点击携带 url 参数进入预览；无参数时保持官方网页版兜底
      const urlParam: string = ctx.pathInfo.param as string;
      if (typeof urlParam === 'string' && urlParam.length > 0) {
        this.targetUrl = urlParam;
      }
    })
  }
}
