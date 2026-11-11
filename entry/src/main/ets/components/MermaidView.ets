import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const MERMAID_STATE_LOADING: number = 0;
export const MERMAID_STATE_CHART: number = 1;
export const MERMAID_STATE_FALLBACK: number = 2;

const MAX_CHART_HEIGHT: number = 640;
const MIN_CHART_HEIGHT: number = 120;
const INITIAL_CHART_HEIGHT: number = 260;

/**
 * 暴露给 Web 端 JS 的双向通信 Bridge 对象（按 ArkWeb javaScriptProxy 规范）。
 */
class MermaidBridge {
  codeText: string = '';
  renderedCallback: (heightPx: number) => void = (_h: number): void => {
  };
  errorCallback: (msg: string) => void = (_m: string): void => {
  };

  getCode(): string {
    return this.codeText;
  }

  onRendered(heightPx: number): void {
    this.renderedCallback(heightPx);
  }

  onError(msg: string): void {
    this.errorCallback(msg);
  }
}

function copyCodeToClipboard(text: string): void {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setData(data).catch((_e: BusinessError) => {
  });
}

/**
 * Mermaid 图表渲染组件：加载 rawfile/mermaid_view.html + 本地离线 mermaid.min.js。
 * 具备 Loading / Chart / Fallback 三态状态机；高度自适应+上限封顶；超宽图表支持 Web 内横向滚动。
 */
@ComponentV2
export struct MermaidView {
  @Param code: string = '';
  @Param closed: boolean = true;
  @Local renderState: number = MERMAID_STATE_LOADING;
  @Local chartHeight: number = INITIAL_CHART_HEIGHT;
  @Local pageLoaded: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: MermaidBridge = new MermaidBridge();

  aboutToAppear(): void {
    this.bridge.codeText = this.code;
    this.bridge.renderedCallback = (heightPx: number): void => {
      this.applyChartHeight(heightPx);
    };
    this.bridge.errorCallback = (_msg: string): void => {
      this.renderState = MERMAID_STATE_FALLBACK;
    };
  }

  aboutToDisappear(): void {
    // 解除回调引用，避免内存泄漏；Web 实例随组件节点销毁释放
    this.bridge.renderedCallback = (_h: number): void => {
    };
    this.bridge.errorCallback = (_m: string): void => {
    };
    this.bridge.codeText = '';
  }

  @Monitor('code')
  onCodeChange(): void {
    this.bridge.codeText = this.code;
    this.renderState = MERMAID_STATE_LOADING;
    if (this.pageLoaded) {
      this.rerenderChart();
    }
  }

  private applyChartHeight(heightPx: number): void {
    const clamped: number = Math.min(MAX_CHART_HEIGHT, Math.max(MIN_CHART_HEIGHT, heightPx + 16));
    this.chartHeight = clamped;
    this.renderState = MERMAID_STATE_CHART;
  }

  private rerenderChart(): void {
    try {
      this.controller.runJavaScript('window.renderMermaid && window.renderMermaid();')
        .catch((_err: BusinessError) => {
        });
    } catch (e) {
      // 页面未就绪时忽略，等待 onPageEnd 或 load 事件触发
    }
  }

  build() {
    if (this.renderState === MERMAID_STATE_FALLBACK || !this.closed) {
      this.buildFallbackBlock()
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Web({ src: $rawfile('mermaid_view.html'), controller: this.controller })
          .javaScriptProxy({
            object: this.bridge,
            name: 'mermaidBridge',
            methodList: ['getCode', 'onRendered', 'onError'],
            controller: this.controller
          })
          .domStorageAccess(true)
          .onPageEnd(() => {
            this.pageLoaded = true;
            this.rerenderChart();
          })
          .onErrorReceive(() => {
            this.renderState = MERMAID_STATE_FALLBACK;
          })
          .height(this.renderState === MERMAID_STATE_CHART ? this.chartHeight : INITIAL_CHART_HEIGHT)
          .width('100%')
          .borderRadius(8)

        if (this.renderState === MERMAID_STATE_LOADING) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color($r('app.color.text_secondary'))
            Text('正在渲染图表...')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(INITIAL_CHART_HEIGHT)
          .backgroundColor('#F9FAFB')
          .borderRadius(8)
        }
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
    }
  }

  /**
   * 语法错误或未闭合时的降级展示（带复制按钮）。
   */
  @Builder
  buildFallbackBlock() {
    Column() {
      Row() {
        Text('mermaid (图表)')
          .fontSize(14)
          .fontColor('#9DA5B4')
        Blank()
        Text('复制')
          .fontSize(14)
          .fontColor('#9DA5B4')
          .onClick(() => {
            copyCodeToClipboard(this.code);
            this.getUIContext().getPromptAction().showToast({ message: '已复制代码' });
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      Scroll() {
        Text(this.code)
          .fontSize(15)
          .lineHeight(24)
          .fontColor($r('app.color.code_text'))
          .fontFamily('monospace')
          .padding(12)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)
      .width('100%')
    }
    .backgroundColor($r('app.color.code_bg'))
    .borderRadius(10)
    .width('100%')
  }
}
