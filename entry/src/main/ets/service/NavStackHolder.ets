/**
 * 全局保存 Navigation 的路由栈，供 EntryAbility.onBackPress 处理系统返回键。
 * Navigation 的默认返回拦截在 hideNavBar 场景下不生效，需由 ability 统一兜底。
 */
let navStack: NavPathStack | null = null;

export function setNavStack(stack: NavPathStack): void {
  navStack = stack;
}

export function getNavStack(): NavPathStack | null {
  return navStack;
}
