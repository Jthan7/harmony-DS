import { ChatPage } from './ChatPage';
import { TokenStore } from '../service/TokenStore';
import { setNavStack, getNavStack } from '../service/NavStackHolder';

@Entry
@ComponentV2
struct Index {
  pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    setNavStack(this.pathStack);
    const token: string = TokenStore.get();
    if (token.length === 0) {
      setTimeout(() => {
        this.pathStack.pushPathByName('Login', '');
      }, 120);
    }
  }

  /**
   * 系统返回键：存在目标页时先关闭目标页并保持在应用前台，否则交回默认行为。
   */
  onBackPress(): boolean {
    const stack: NavPathStack | null = getNavStack();
    if (stack !== null && stack.size() > 0) {
      stack.pop();
      return true;
    }
    return false;
  }

  build() {
    Stack() {
      // 首页：铺满整个窗口（不经过 Navigation 的 NavBar，避免底部安全区被裁剪）
      ChatPage({ pathStack: this.pathStack })
        .width('100%')
        .height('100%')

      // 路由层：仅承载 Login / WebFallback 等目标页
      // hitTestBehavior(Transparent)：无目标页时触摸穿透到下方聊天页，
      // 目标页为全屏组件，仍会优先命中
      Navigation(this.pathStack) {
        // 空首页（首页由上方 ChatPage 承载）
      }
      .mode(NavigationMode.Stack)
      .hideNavBar(true)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }
}
