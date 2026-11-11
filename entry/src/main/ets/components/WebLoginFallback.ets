import { webview } from '@kit.ArkWeb';
import { TokenStore } from '../service/TokenStore';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOGIN_URL: string = 'https://chat.deepseek.com/sign_in';
const COOKIE_URL: string = 'https://chat.deepseek.com';
const SNIFF_PREFIX: string = '[SNIFF]';
const MAX_SNIFF_ENTRIES: number = 400;
// 移动 UA：页面按移动视口渲染（1 CSS px ≈ 1vp）。
// 桌面 UA 曾导致整页缩放、图标实际仅 ~7vp，触发 AGC 可访问性检测"图标宽高 < 8vp"。
const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

/**
 * 可访问性兜底（AGC 检测要求图标宽高 ≥ 8vp）：
 * 注入 CSS 强制 img/svg/canvas 最小 8px，防止第三方页面残留超小图片节点。
 */
const A11Y_CSS_JS: string = `(function(){
  function inject(){
    try {
      var s = document.createElement('style');
      s.textContent = 'img,svg,canvas{min-width:8px !important;min-height:8px !important;}';
      (document.head || document.documentElement).appendChild(s);
    } catch (e) {}
  }
  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', inject); }
  else { inject(); }
})();`;

/**
 * 注入到登录页的 API 嗅探脚本：
 * hook fetch / XMLHttpRequest，将所有 /api/ 请求（方法/URL/请求体/请求头/响应片段/失败原因）
 * 通过 console.log 以 [SNIFF] 前缀回传给应用侧，用于核实真实端点与请求头。
 */
const SNIFFER_JS: string = `(function(){
  if (window.__dsSniffInstalled) { return; }
  window.__dsSniffInstalled = true;
  try {
    Object.defineProperty(navigator, 'onLine', { get: function() { return true; }, configurable: true });
  } catch (e) {}
  function emit(kind, obj) {
    try { console.log('[SNIFF]' + JSON.stringify({ k: kind, d: obj })); } catch (e) {}
  }
  window.addEventListener('error', function(ev) {
    emit('jsError', { m: String(ev.message || ''), s: String((ev.filename || '') + ':' + (ev.lineno || 0)) });
  });
  window.addEventListener('unhandledrejection', function(ev) {
    emit('jsRejection', { r: String(ev.reason || '') });
  });
  var of = window.fetch;
  if (of) {
    window.fetch = function(input, init) {
      var url = (typeof input === 'string') ? input : ((input && input.url) ? input.url : '');
      var method = (init && init.method) || 'GET';
      var headers = {};
      try { if (init && init.headers) { headers = init.headers; } } catch (e) {}
      var body = '';
      try { if (init && init.body) { body = String(init.body).slice(0, 600); } } catch (e) {}
      var auth = '';
      try {
        if (init && init.headers) {
          var hd = init.headers;
          if (typeof hd.get === 'function') { auth = hd.get('authorization') || ''; }
          else { var ks = Object.keys(hd); for (var ki = 0; ki < ks.length; ki++) { if (ks[ki].toLowerCase() === 'authorization') { auth = hd[ks[ki]]; } } }
        }
      } catch (e) {}
      if (auth) { emit('auth', { a: String(auth).slice(0, 300) }); }
      var pr = of.apply(this, arguments);
      if (url.indexOf('/api/') >= 0) {
        emit('req', { m: method, u: url });
        pr.then(function(resp) {
          resp.clone().text().then(function(txt) {
            emit('fetch', { m: method, u: url, b: body, h: JSON.stringify(headers).slice(0, 600), s: resp.status, r: txt.slice(0, 800) });
          }).catch(function(e) {});
        }).catch(function(e) {
          emit('fetchFail', { m: method, u: url, e: String(e && e.message ? e.message : e) });
        });
      }
      return pr;
    };
  }
  var oo = XMLHttpRequest.prototype.open;
  var os = XMLHttpRequest.prototype.send;
  var osh = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function(m, u) { this.__dsM = m; this.__dsU = u; this.__dsH = {}; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function(k, v) { if (this.__dsH) { this.__dsH[k] = v; } return osh.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(b) {
    var self = this;
    if (this.__dsU && this.__dsU.indexOf('/api/') >= 0) {
      emit('req', { m: self.__dsM, u: self.__dsU });
      if (self.__dsH) {
        var hk = Object.keys(self.__dsH);
        for (var hi = 0; hi < hk.length; hi++) {
          if (hk[hi].toLowerCase() === 'authorization') { emit('auth', { a: String(self.__dsH[hk[hi]]).slice(0, 300) }); }
        }
      }
      this.addEventListener('load', function() {
        emit('xhr', { m: self.__dsM, u: self.__dsU, b: b ? String(b).slice(0, 600) : '', h: JSON.stringify(self.__dsH || {}).slice(0, 600), s: self.status, r: (self.responseText || '').slice(0, 800) });
      });
      this.addEventListener('error', function() { emit('xhrFail', { m: self.__dsM, u: self.__dsU, e: 'network error' }); });
      this.addEventListener('abort', function() { emit('xhrFail', { m: self.__dsM, u: self.__dsU, e: 'aborted' }); });
      this.addEventListener('timeout', function() { emit('xhrFail', { m: self.__dsM, u: self.__dsU, e: 'timeout' }); });
    }
    return os.apply(this, arguments);
  };
  function probe() {
    if (location.origin.indexOf('deepseek') < 0) { return; }
    emit('env', { origin: location.origin, online: navigator.onLine, ua: navigator.userAgent.slice(0, 80) });
    if (navigator.serviceWorker) {
      navigator.serviceWorker.getRegistrations().then(function(rs) {
        var scopes = [];
        for (var i = 0; i < rs.length; i++) { scopes.push(rs[i].scope); }
        emit('sw', { count: rs.length, scopes: scopes.join('|') });
      }).catch(function(e) { emit('swErr', { e: String(e) }); });
    } else {
      emit('sw', { unsupported: true });
    }
    fetch(location.origin + '/api/v0/chat/list', { method: 'GET' })
      .then(function(r) { emit('probeGetApi', { s: r.status }); })
      .catch(function(e) { emit('probeGetApiFail', { e: String(e) }); });
    fetch(location.origin + '/', { method: 'GET' })
      .then(function(r) { emit('probeGetRoot', { s: r.status }); })
      .catch(function(e) { emit('probeGetRootFail', { e: String(e) }); });
    fetch('https://www.huawei.com/favicon.ico', { mode: 'no-cors' })
      .then(function() { emit('probeCross', { ok: 1 }); })
      .catch(function(e) { emit('probeCrossFail', { e: String(e) }); });
    var x = new XMLHttpRequest();
    x.open('POST', location.origin + '/api/v0/telemetry');
    x.onload = function() { emit('probeXhrPost', { s: x.status }); };
    x.onerror = function() { emit('probeXhrPostFail', { e: 'onerror' }); };
    try { x.send('{}'); } catch (e) { emit('probeXhrPostFail', { e: 'throw ' + String(e) }); }
  }
  setTimeout(probe, 3000);
})();`;

function extractUserToken(cookies: string): string {
  const parts: string[] = cookies.split(';');
  for (const p of parts) {
    const t: string = p.trim();
    if (t.startsWith('userToken=')) {
      return t.substring('userToken='.length);
    }
  }
  return '';
}

/**
 * WebView 登录回退组件（RD-06/RD-08，FR-003）：
 * 从旧 LoginPage 迁移的完整 WebView 登录 + 嗅探工具链——
 * 加载官方 sign_in 页（移动 UA，保证图标 ≥8vp 过 AGC 可访问性检测）、Cookie 轮询捕获 userToken、SNIFFER_JS 注入、
 * [SNIFF] 日志捕获、嗅探模式开关与 API 记录面板，全部内聚在组件内。
 * 由 LoginPage 以全屏弹层打开（原生登录失败引导 / 隐藏调试入口），登录永不中断的兜底路径。
 */
@ComponentV2
export struct WebLoginFallback {
  /** 登录成功（凭证已写入 TokenStore）回调，走与原生一致的 finishLogin 路径 */
  @Event onLoginSuccess: () => void = (): void => {
  };
  /** 关闭回退弹层（未登录）回调 */
  @Event onClose: () => void = (): void => {
  };
  /** 初始嗅探模式（取证：捕获 API 请求记录） */
  @Param initialSniffMode: boolean = false;
  /** 初始展开 API 记录面板 */
  @Param initialShowSniffPanel: boolean = false;
  @Local sniffMode: boolean = false;
  @Local showSniffPanel: boolean = false;
  @Local tokenCaptured: boolean = false;
  @Local sniffEntries: string[] = [];
  private controller: webview.WebviewController = new webview.WebviewController();
  private cookieTimer: number = -1;
  private capturedToken: string = '';
  private lastCookieDiag: string = '';

  aboutToAppear(): void {
    this.sniffMode = this.initialSniffMode;
    this.showSniffPanel = this.initialShowSniffPanel;
    this.startCookiePolling();
  }

  aboutToDisappear(): void {
    this.stopCookiePolling();
  }

  private startCookiePolling(): void {
    if (this.cookieTimer >= 0) {
      return;
    }
    this.cookieTimer = setInterval(() => {
      this.checkCookie();
    }, 1200);
  }

  private stopCookiePolling(): void {
    if (this.cookieTimer >= 0) {
      clearInterval(this.cookieTimer);
      this.cookieTimer = -1;
    }
  }

  private checkCookie(): void {
    try {
      const cookies: string = webview.WebCookieManager.fetchCookieSync(COOKIE_URL);
      const token: string = extractUserToken(cookies);
      if (token.length > 0) {
        this.captureToken(token);
        if (!this.sniffMode) {
          this.onLoginSuccess();
        }
        return;
      }
      if (cookies !== this.lastCookieDiag) {
        this.lastCookieDiag = cookies;
        hilog.info(0x0000, 'DSLogin', 'cookieMiss docCookie=%{public}s', cookies.slice(0, 400));
      }
      this.probeWebCookies();
    } catch (e) {
      // Web 未就绪时忽略
    }
  }

  private probeWebCookies(): void {
    try {
      this.controller.runJavaScript('document.cookie')
        .then((result: string) => {
          const token: string = extractUserToken(result);
          if (token.length > 0) {
            this.captureToken(token);
            if (!this.sniffMode) {
              this.onLoginSuccess();
            }
          }
        })
        .catch((e: BusinessError) => {
        });
    } catch (e) {
      // controller 未挂载时忽略
    }
  }

  private handleSniffMessage(raw: string): void {
    const marker: string = '"a":"';
    const idx: number = raw.indexOf(marker);
    if (idx < 0 || raw.indexOf('"k":"auth"') < 0) {
      return;
    }
    const rest: string = raw.substring(idx + marker.length);
    const endIdx: number = rest.indexOf('"');
    if (endIdx <= 0) {
      return;
    }
    const authValue: string = rest.substring(0, endIdx);
    const token: string = authValue.startsWith('Bearer ') ? authValue.substring('Bearer '.length) : '';
    if (token.length > 0) {
      this.captureToken(token);
    }
  }

  private captureToken(token: string): void {
    if (token !== this.capturedToken) {
      this.capturedToken = token;
      TokenStore.set(token);
    }
    this.tokenCaptured = true;
  }

  private enterChat(): void {
    if (TokenStore.get().length > 0) {
      this.onLoginSuccess();
    } else {
      this.safeShowToast('未检测到登录凭证，请先在下方完成登录');
    }
  }

  private safeShowToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // UI 上下文未就绪时忽略
    }
  }

  private addDiag(entry: string): void {
    if (this.sniffEntries.length >= MAX_SNIFF_ENTRIES) {
      this.sniffEntries.splice(0, 100);
    }
    this.sniffEntries.push(entry);
    hilog.info(0x0000, 'DSLogin', '%{public}s', entry);
  }

  private copySniffLog(): void {
    const text: string = this.sniffEntries.join('\n');
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).catch((e: BusinessError) => {
      this.safeShowToast('复制失败，请重试');
    });
    this.safeShowToast('已复制嗅探日志');
  }

  build() {
    Column() {
      Row() {
        Text('网页登录')
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Row({ space: 6 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.sniffMode })
            .onChange((isOn: boolean) => {
              this.sniffMode = isOn;
            })
          Text('嗅探模式')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        Text('API记录')
          .fontSize(14)
          .fontColor($r('app.color.brand'))
          .padding({ left: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.showSniffPanel = true;
          })
        Text('关闭')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Row({ space: 12 }) {
        Text(this.tokenCaptured ? '已捕获登录凭证' : '请在下方完成登录，成功后自动进入聊天')
          .fontSize(14)
          .fontColor(this.tokenCaptured ? $r('app.color.brand') : $r('app.color.text_secondary'))
          .layoutWeight(1)
        if (this.tokenCaptured) {
          Text('进入聊天')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(16)
            .backgroundColor($r('app.color.input_bg'))
            .onClick(() => {
              this.enterChat();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Stack() {
        Web({ src: LOGIN_URL, controller: this.controller })
          .domStorageAccess(true)
          .onControllerAttached(() => {
            // 控制器挂载即设置移动 UA（早于首个页面加载，等价原 .userAgent 属性且非废弃）
            try {
              this.controller.setCustomUserAgent(MOBILE_UA);
            } catch (e) {
              hilog.warn(0x0000, 'DSLogin', 'setCustomUserAgent failed');
            }
          })
          .javaScriptOnDocumentStart([{ script: SNIFFER_JS, scriptRules: ['*'] }, { script: A11Y_CSS_JS, scriptRules: ['*'] }])
          .onConsole((event) => {
            const message: string = event.message.getMessage();
            if (message.startsWith(SNIFF_PREFIX)) {
              const payload: string = message.substring(SNIFF_PREFIX.length);
              this.handleSniffMessage(payload);
              this.addDiag(payload);
            } else {
              hilog.info(0x0000, 'DSLogin', 'console: %{public}s', message.slice(0, 400));
            }
            return false;
          })
          .onErrorReceive((event) => {
            this.addDiag(`{"k":"netErr","d":{"u":"${event.request.getRequestUrl()}","c":${event.error.getErrorCode()},"i":"${event.error.getErrorInfo()}","main":${event.request.isMainFrame()}}}`);
          })
          .onHttpErrorReceive((event) => {
            this.addDiag(`{"k":"httpErr","d":{"u":"${event.request.getRequestUrl()}","s":${event.response.getResponseCode()}}}`);
          })
          .onPageEnd(() => {
            this.checkCookie();
          })

        if (this.showSniffPanel) {
          Column() {
            Row({ space: 12 }) {
              Text('API 嗅探记录')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text('复制全部')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .onClick(() => {
                  this.copySniffLog();
                })
              Text('关闭')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .onClick(() => {
                  this.showSniffPanel = false;
                })
            }
            .width('100%')
            .padding(12)

            Scroll() {
              Column() {
                ForEach(this.sniffEntries, (e: string, idx: number) => {
                  Text(e)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .padding(6)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }, (e: string, idx: number): string => `${idx}`)
              }
              .width('100%')
            }
            .layoutWeight(1)
            .width('100%')
            .align(Alignment.TopStart)
            .scrollBar(BarState.Auto)
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.panel_bg'))
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.chat_bg'))
  }
}
