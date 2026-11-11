import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TokenStore } from '../service/TokenStore';
import { DeepSeekLoginClient, LoginApiError, LoginResult, SendSmsResult, ShumeiVerification } from '../service/DeepSeekLoginClient';
import { WebLoginFallback } from '../components/WebLoginFallback';
import { ShumeiCaptchaDialog } from '../components/ShumeiCaptchaDialog';

const TAG: string = 'DSLogin';
const PHONE_REGEX: RegExp = /^1\d{10}$/;

@Builder
export function LoginBuilder(): void {
  LoginPage()
}

/**
 * 登录页（login-glass）：全原生短信验证码登录 + 液态玻璃视觉 + 隐藏调试入口。
 * - 原生表单直连 DeepSeek SMS API（挑战→PoW→加密→token，RD-05）
 * - 任一环节失败 → 内联错误 + "使用网页登录"回退（WebLoginFallback，RD-08）
 * - 长按标题 ≥1s 唤出隐藏菜单（网页登录备用/嗅探模式/API 记录，RD-06）
 * - 液态玻璃视觉：光斑背景 + backgroundEffect 玻璃卡片 + 品牌蓝胶囊按钮（RD-07）
 * 契约不变：Login 路由名 / LoginBuilder 导出 / NavDestination 根节点 / onReady(pathStack)。
 */
@ComponentV2
export struct LoginPage {
  pathStack: NavPathStack = new NavPathStack();
  @Local phone: string = '';
  @Local smsCode: string = '';
  @Local countdown: number = 0;
  @Local sendingCode: boolean = false;
  @Local loggingIn: boolean = false;
  @Local statusText: string = '';
  @Local statusError: string = '';
  @Local showWebFallback: boolean = false;
  @Local fallbackSniffMode: boolean = false;
  @Local fallbackShowPanel: boolean = false;
  @Local showHiddenMenu: boolean = false;
  @Local showCaptcha: boolean = false;
  private client: DeepSeekLoginClient | null = null;
  private countdownTimer: number = -1;

  @Computed get sendButtonLabel(): string {
    if (this.sendingCode) {
      return '发送中…';
    }
    if (this.countdown > 0) {
      return `${this.countdown}s 后重发`;
    }
    return '获取验证码';
  }

  @Computed get loginButtonLabel(): string {
    return this.loggingIn ? '安全校验中' : '登录';
  }

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      this.client = new DeepSeekLoginClient(ctx);
    } else {
      hilog.error(0x0000, TAG, 'host context unavailable, native login disabled');
    }
  }

  aboutToDisappear(): void {
    this.stopCountdown();
  }

  private stopCountdown(): void {
    if (this.countdownTimer >= 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
  }

  private startCountdown(secs: number): void {
    this.stopCountdown();
    this.countdown = secs > 0 ? secs : 60;
    this.countdownTimer = setInterval(() => {
      this.countdown = this.countdown - 1;
      if (this.countdown <= 0) {
        this.countdown = 0;
        this.stopCountdown();
      }
    }, 1000);
  }

  private isValidPhone(): boolean {
    return PHONE_REGEX.test(this.phone);
  }

  private async doSendCode(): Promise<void> {
    if (this.sendingCode || this.countdown > 0) {
      return;
    }
    if (!this.isValidPhone()) {
      this.statusText = '';
      this.statusError = '请输入正确的 11 位手机号';
      return;
    }
    if (this.client === null) {
      this.statusError = '初始化未完成，请稍后重试';
      return;
    }
    // 大陆用户发码前先完成数美人机验证（对齐 Web 2.7.1 主动验证码流程）：
    // 验证通过后由 sendCodeWithCaptcha 组装 shumei_verification = {rid, region} 随加密体上送
    this.statusText = '';
    this.statusError = '';
    this.showCaptcha = true;
  }

  /** 数美验证通过后发码：凭证 {rid, region:"CN"} 放入 body.shumei_verification */
  private async sendCodeWithCaptcha(rid: string): Promise<void> {
    this.showCaptcha = false;
    if (this.sendingCode || this.countdown > 0) {
      return;
    }
    if (this.client === null) {
      this.statusError = '初始化未完成，请稍后重试';
      return;
    }
    this.sendingCode = true;
    this.statusText = '';
    this.statusError = '';
    try {
      const verification: ShumeiVerification = new ShumeiVerification(rid, 'CN');
      const result: SendSmsResult = await this.client.sendSmsCode(this.phone, verification);
      this.startCountdown(result.sendWindowSecs);
      this.statusText = '验证码已发送，请查收短信';
    } catch (e) {
      const err: LoginApiError = e as LoginApiError;
      this.statusError = err.message.length > 0 ? err.message : '验证码发送失败，请稍后重试';
    }
    this.sendingCode = false;
  }

  private async doLogin(): Promise<void> {
    if (this.loggingIn) {
      return;
    }
    if (!this.isValidPhone()) {
      this.statusText = '';
      this.statusError = '请输入正确的 11 位手机号';
      return;
    }
    if (this.smsCode.length < 4) {
      this.statusText = '';
      this.statusError = '请输入收到的短信验证码';
      return;
    }
    if (this.client === null) {
      this.statusError = '初始化未完成，请稍后重试';
      return;
    }
    this.loggingIn = true;
    this.statusText = '安全校验中';
    this.statusError = '';
    try {
      const result: LoginResult = await this.client.loginBySms(this.phone, this.smsCode);
      TokenStore.set(result.token);
      // 设备登记尽力而为（Bearer 新 token），不阻塞返回聊天
      this.client.checkDevice(result.token).catch((): void => {
      });
      this.finishLogin();
    } catch (e) {
      const err: LoginApiError = e as LoginApiError;
      this.statusError = err.message.length > 0 ? err.message : '登录失败，请稍后重试';
    }
    this.statusText = '';
    this.loggingIn = false;
  }

  /** 登录收尾：原生与 WebView 回退共用路径（凭证已写 TokenStore → 返回上一页） */
  private finishLogin(): void {
    this.stopCountdown();
    this.showWebFallback = false;
    this.pathStack.pop();
  }

  private openWebFallback(sniffMode: boolean, showPanel: boolean): void {
    this.fallbackSniffMode = sniffMode;
    this.fallbackShowPanel = showPanel;
    this.showWebFallback = true;
  }

  private closeHiddenMenu(): void {
    this.showHiddenMenu = false;
  }

  build() {
    NavDestination() {
      Stack() {
        // 底色 + 左上/右下品牌蓝径向渐变氛围光斑（RD-07）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.chat_bg'))
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({
            center: ['15%', '10%'],
            radius: '55%',
            colors: [[$r('app.color.glass_spot'), 0.0], [Color.Transparent, 1.0]]
          })
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({
            center: ['88%', '85%'],
            radius: '60%',
            colors: [[$r('app.color.glass_spot'), 0.0], [Color.Transparent, 1.0]]
          })

        // 表单区：Scroll 包裹，键盘 RESIZE 避让时内容完整可见、可滚动
        Scroll() {
          Column() {
            // 液态玻璃卡片（RD-07：backgroundEffect 折射 + 高光描边 + 柔和投影）
            Column({ space: 18 }) {
              // 标题/Logo 区（长按 ≥1s 唤出隐藏调试菜单，RD-06）
              Column({ space: 6 }) {
                Text('DeepSeek')
                  .fontSize(28)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text('短信验证码登录')
                  .fontSize(14)
                  .fontColor($r('app.color.glass_text_aux'))
              }
              .gesture(
                LongPressGesture({ repeat: false, duration: 1000 })
                  .onAction(() => {
                    this.showHiddenMenu = true;
                  })
              )

              // 手机号输入（+86 前缀、11 位校验）
              Row({ space: 10 }) {
                Text('+86')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .textAlign(TextAlign.Center)
                  .height(48)
                  .padding({ left: 14, right: 14 })
                  .borderRadius(12)
                  .backgroundColor($r('app.color.input_bg'))
                TextInput({ placeholder: '请输入手机号', text: this.phone })
                  .type(InputType.PhoneNumber)
                  .maxLength(11)
                  .height(48)
                  .layoutWeight(1)
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.input_bg'))
                  .borderRadius(12)
                  .padding({ left: 14, right: 14 })
                  .onChange((value: string) => {
                    this.phone = value;
                  })
              }
              .width('100%')

              // 验证码输入 + 发送验证码（玻璃次级按钮，倒计时禁用态）
              Row({ space: 10 }) {
                TextInput({ placeholder: '请输入验证码', text: this.smsCode })
                  .type(InputType.Number)
                  .maxLength(6)
                  .height(48)
                  .layoutWeight(1)
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.input_bg'))
                  .borderRadius(12)
                  .padding({ left: 14, right: 14 })
                  .onChange((value: string) => {
                    this.smsCode = value;
                  })
                Text(this.sendButtonLabel)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.countdown > 0 || this.sendingCode ?
                  $r('app.color.text_secondary') : $r('app.color.brand'))
                  .textAlign(TextAlign.Center)
                  .height(40)
                  .padding({ left: 12, right: 12 })
                  .constraintSize({ minWidth: 96 })
                  .borderRadius(20)
                  .backgroundColor($r('app.color.glass_card'))
                  .border({ width: 1, color: $r('app.color.glass_stroke') })
                  .onClick(() => {
                    this.doSendCode();
                  })
              }
              .width('100%')

              // 登录按钮：品牌蓝胶囊大按钮，加载态内嵌小型 Loading + "安全校验中"
              Button({ type: ButtonType.Capsule }) {
                Row({ space: 8 }) {
                  if (this.loggingIn) {
                    LoadingProgress()
                      .width(20)
                      .height(20)
                      .color(Color.White)
                  }
                  Text(this.loginButtonLabel)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                }
              }
              .width('100%')
              .height(48)
              .backgroundColor($r('app.color.brand'))
              .enabled(!this.loggingIn)
              .onClick(() => {
                this.doLogin();
              })

              // 内联状态/错误提示（错误用 danger 色）+ 网页登录回退引导（RD-08）
              if (this.statusError.length > 0) {
                Text(this.statusError)
                  .fontSize(13)
                  .fontColor($r('app.color.danger'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                Text('遇到问题？使用网页登录')
                  .fontSize(13)
                  .fontColor($r('app.color.brand'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.openWebFallback(false, false);
                  })
              } else if (this.statusText.length > 0) {
                Text(this.statusText)
                  .fontSize(13)
                  .fontColor($r('app.color.glass_text_aux'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
              }
            }
            .width('88%')
            .padding(24)
            .constraintSize({ minWidth: 280 })
            .backgroundEffect({
              radius: 30,
              saturation: 1.5,
              brightness: 1.15,
              color: $r('app.color.glass_card'),
              adaptiveColor: AdaptiveColor.DEFAULT
            })
            .borderRadius(24)
            .border({ width: 1, color: $r('app.color.glass_stroke') })
            .shadow({ radius: 28, color: $r('app.color.glass_shadow'), offsetY: 4 })
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Center)
          .padding({ top: 24, bottom: 24 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)

        // WebView 登录回退全屏弹层（登录失败引导 / 隐藏入口唤出）
        if (this.showWebFallback) {
          Column() {
            WebLoginFallback({
              onLoginSuccess: (): void => {
                this.finishLogin();
              },
              onClose: (): void => {
                this.showWebFallback = false;
              },
              initialSniffMode: this.fallbackSniffMode,
              initialShowSniffPanel: this.fallbackShowPanel
            })
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.chat_bg'))
        }

        // 数美验证码弹层（发码前主动人机验证，原生 UI + 内嵌 WebView 控件）
        if (this.showCaptcha) {
          ShumeiCaptchaDialog({
            mode: 'spatial_select',
            onPass: (rid: string): void => {
              this.sendCodeWithCaptcha(rid);
            },
            onClose: (): void => {
              this.showCaptcha = false;
            }
          })
        }

        // 隐藏调试菜单（默认界面零调试痕迹）
        if (this.showHiddenMenu) {
          Column() {
            Column() {
              Text('使用网页登录（备用）')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .height(48)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.closeHiddenMenu();
                  this.openWebFallback(false, false);
                })
              Divider()
                .color($r('app.color.divider_color'))
              Text('嗅探模式')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .height(48)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.closeHiddenMenu();
                  this.openWebFallback(true, false);
                })
              Divider()
                .color($r('app.color.divider_color'))
              Text('API 记录')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .height(48)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.closeHiddenMenu();
                  this.openWebFallback(true, true);
                })
              Divider()
                .color($r('app.color.divider_color'))
              Text('取消')
                .fontSize(15)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .height(48)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.closeHiddenMenu();
                })
            }
            .width('78%')
            .borderRadius(16)
            .backgroundColor($r('app.color.panel_bg'))
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.mask'))
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.closeHiddenMenu();
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      if (this.showWebFallback) {
        this.showWebFallback = false;
        return true;
      }
      if (this.showCaptcha) {
        this.showCaptcha = false;
        return true;
      }
      if (this.showHiddenMenu) {
        this.showHiddenMenu = false;
        return true;
      }
      this.pathStack.pop();
      return true;
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}
