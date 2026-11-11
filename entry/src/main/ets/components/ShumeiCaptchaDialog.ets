import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ShumeiCaptcha';

export const CAPTCHA_STATE_LOADING: number = 0;
export const CAPTCHA_STATE_READY: number = 1;
export const CAPTCHA_STATE_ERROR: number = 2;

const CARD_WIDTH: number = 332;
const WEB_WIDTH: number = 300;
const WEB_HEIGHT: number = 250;

/**
 * 暴露给 Web 端 JS 的双向通信 Bridge 对象（按 ArkWeb javaScriptProxy 规范）。
 * 契约取证自 Web bundle main.9120333998.js（2.7.1）：shumei_captcha.html 通过
 * captchaBridge.getMode() 同步取模式、onReady/onResult/onError 回调原生侧。
 */
class ShumeiBridge {
  mode: string = 'spatial_select';
  readyCallback: () => void = (): void => {
  };
  resultCallback: (resultJson: string) => void = (_resultJson: string): void => {
  };
  errorCallback: () => void = (): void => {
  };

  getMode(): string {
    return this.mode;
  }

  onReady(): void {
    this.readyCallback();
  }

  onResult(resultJson: string): void {
    this.resultCallback(resultJson);
  }

  onError(): void {
    this.errorCallback();
  }
}

/** 数美 onSuccess 原始结构（JSON.parse 后一次性映射） */
interface ShumeiResultRaw {
  pass?: boolean;
  rid?: string;
}

/**
 * 数美验证码弹窗：内嵌 WebView 加载 rawfile/shumei_captcha.html，
 * 渲染 Web 端同款数美滑块/点选控件（SDK castatic.fengkongcloud.cn，org P9usCUBauxft8eAmUXaZ）。
 * 通过 onPass(rid) 返回验证凭证，由调用方组装 shumei_verification = {rid, region: "CN"}。
 * 三态：loading（骨架屏）/ ready（控件交互）/ error（加载失败 + 重试）。
 */
@ComponentV2
export struct ShumeiCaptchaDialog {
  /** 数美模式：slide | select | icon_select | seq_select | spatial_select */
  @Param mode: string = 'spatial_select';
  /** 验证通过：rid 非空（对齐 Web instance.onSuccess({pass, rid})） */
  @Event onPass: (rid: string) => void = (_rid: string): void => {
  };
  /** 用户关闭 / 点击遮罩取消 */
  @Event onClose: () => void = (): void => {
  };
  @Local state: number = CAPTCHA_STATE_LOADING;
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: ShumeiBridge = new ShumeiBridge();

  aboutToAppear(): void {
    this.bridge.mode = this.mode;
    this.bridge.readyCallback = (): void => {
      this.state = CAPTCHA_STATE_READY;
    };
    this.bridge.resultCallback = (resultJson: string): void => {
      this.handleResult(resultJson);
    };
    this.bridge.errorCallback = (): void => {
      // 仅加载阶段置错误态；ready 后的偶发 onError 忽略（控件自愈/重试由刷新承担）
      if (this.state === CAPTCHA_STATE_LOADING) {
        this.state = CAPTCHA_STATE_ERROR;
      }
    };
  }

  aboutToDisappear(): void {
    // 解除回调引用，避免内存泄漏；Web 实例随组件节点销毁释放
    this.bridge.readyCallback = (): void => {
    };
    this.bridge.resultCallback = (_resultJson: string): void => {
    };
    this.bridge.errorCallback = (): void => {
    };
    this.bridge.mode = '';
  }

  private handleResult(resultJson: string): void {
    let raw: ShumeiResultRaw;
    try {
      raw = JSON.parse(resultJson) as ShumeiResultRaw;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'parse captcha result failed');
      return;
    }
    const pass: boolean = raw.pass === true;
    const rid: string = raw.rid !== undefined ? raw.rid : '';
    if (pass && rid.length > 0) {
      hilog.info(0x0000, TAG, 'captcha passed, rid len=%{public}d', rid.length);
      this.onPass(rid);
    } else {
      // pass=false：数美控件自动进入下一轮挑战，弹窗保持
      hilog.info(0x0000, TAG, 'captcha not passed, keep dialog');
    }
  }

  private retryLoad(): void {
    this.state = CAPTCHA_STATE_LOADING;
    try {
      this.controller.refresh();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0x0000, TAG, 'refresh web failed: %{public}s', err.message);
    }
  }

  build() {
    Stack() {
      // 遮罩：点击取消
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.mask'))
        .onClick(() => {
          this.onClose();
        })

      // 验证码卡片
      Column({ space: 12 }) {
        Row() {
          Text('安全验证')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('刷新')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.retryLoad();
            })
          Text('✕')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')

        Stack() {
          Web({ src: $rawfile('shumei_captcha.html'), controller: this.controller })
            .javaScriptProxy({
              object: this.bridge,
              name: 'captchaBridge',
              methodList: ['getMode', 'onReady', 'onResult', 'onError'],
              controller: this.controller
            })
            .domStorageAccess(true)
            .width(WEB_WIDTH)
            .height(WEB_HEIGHT)

          if (this.state === CAPTCHA_STATE_ERROR) {
            Column({ space: 12 }) {
              Text('验证码加载失败')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text('重试')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.brand'))
                .padding({ left: 20, right: 20, top: 8, bottom: 8 })
                .borderRadius(18)
                .backgroundColor($r('app.color.input_bg'))
                .onClick(() => {
                  this.retryLoad();
                })
            }
            .width(WEB_WIDTH)
            .height(WEB_HEIGHT)
            .backgroundColor(Color.White)
            .borderRadius(12)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width(WEB_WIDTH)
        .height(WEB_HEIGHT)
      }
      .width(CARD_WIDTH)
      .padding(16)
      .backgroundColor($r('app.color.panel_bg'))
      .borderRadius(20)
      .border({ width: 1, color: $r('app.color.glass_stroke') })
      .shadow({ radius: 28, color: $r('app.color.glass_shadow'), offsetY: 4 })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
