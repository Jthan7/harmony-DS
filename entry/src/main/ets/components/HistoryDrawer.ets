import { SessionSummary } from '../model/ChatModels';

interface SessionGroup {
  label: string;
  items: SessionSummary[];
}

const DAY_MS: number = 24 * 60 * 60 * 1000;

// 按官方 Web 端规则分组：置顶 / 今天 / 昨天 / 7 天内 / 30 天内 / 按月（YYYY年M月）
function buildSessionGroups(sessions: SessionSummary[], keyword: string): SessionGroup[] {
  const result: SessionGroup[] = [];
  const kw: string = keyword.trim().toLowerCase();
  let pool: SessionSummary[] = sessions;
  if (kw.length > 0) {
    pool = sessions.filter((s: SessionSummary): boolean => s.title.toLowerCase().includes(kw));
  }
  const sorted: SessionSummary[] =
    pool.slice().sort((a: SessionSummary, b: SessionSummary): number => b.updatedAtMs - a.updatedAtMs);

  const now: Date = new Date();
  const startToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const startYesterday: number = startToday - DAY_MS;
  const start7: number = startToday - 6 * DAY_MS;
  const start30: number = startToday - 29 * DAY_MS;

  const pinnedItems: SessionSummary[] = [];
  const todayItems: SessionSummary[] = [];
  const yesterdayItems: SessionSummary[] = [];
  const weekItems: SessionSummary[] = [];
  const month30Items: SessionSummary[] = [];
  const olderItems: SessionSummary[] = [];
  for (const s of sorted) {
    if (s.pinned) {
      pinnedItems.push(s);
      continue;
    }
    if (s.updatedAtMs >= startToday) {
      todayItems.push(s);
    } else if (s.updatedAtMs >= startYesterday) {
      yesterdayItems.push(s);
    } else if (s.updatedAtMs >= start7) {
      weekItems.push(s);
    } else if (s.updatedAtMs >= start30) {
      month30Items.push(s);
    } else {
      olderItems.push(s);
    }
  }

  if (pinnedItems.length > 0) {
    result.push({ label: '置顶', items: pinnedItems });
  }
  if (todayItems.length > 0) {
    result.push({ label: '今天', items: todayItems });
  }
  if (yesterdayItems.length > 0) {
    result.push({ label: '昨天', items: yesterdayItems });
  }
  if (weekItems.length > 0) {
    result.push({ label: '7 天内', items: weekItems });
  }
  if (month30Items.length > 0) {
    result.push({ label: '30 天内', items: month30Items });
  }

  // 更早的会话按月分组（sorted 倒序，月份自然由新到旧）
  let lastLabel: string = '';
  let lastItems: SessionSummary[] = [];
  for (const s of olderItems) {
    const d: Date = new Date(s.updatedAtMs);
    const label: string = `${d.getFullYear()}年${d.getMonth() + 1}月`;
    if (label !== lastLabel) {
      if (lastItems.length > 0) {
        result.push({ label: lastLabel, items: lastItems });
      }
      lastLabel = label;
      lastItems = [];
    }
    lastItems.push(s);
  }
  if (lastItems.length > 0) {
    result.push({ label: lastLabel, items: lastItems });
  }
  return result;
}

@ComponentV2
export struct HistoryDrawer {
  @Param sessions: SessionSummary[] = [];
  @Param activeSessionId: string = '';
  @Param userName: string = '';
  @Param avatarUrl: string = '';
  /** 抽屉打开进度 0~1：内容轻微视差跟随 */
  @Param progress: number = 0;
  /** 系统状态栏高度（vp）：全屏沉浸窗口下抽屉顶部内容避开状态栏 */
  @Param statusBarVp: number = 0;
  /** 导航区高度（vp）：全屏沉浸窗口下抽屉底部内容避开小白条 */
  @Param navBarVp: number = 0;
  @Event onClose: () => void = () => {
  };
  @Event onSelectSession: (id: string) => void = (_id: string) => {
  };
  @Event onOpenWebMode: () => void = () => {
  };
  @Event onLogout: () => void = () => {
  };
  @Local searchKeyword: string = '';
  @Local avatarLoadFailed: boolean = false;

  @Computed
  get groups(): SessionGroup[] {
    return buildSessionGroups(this.sessions, this.searchKeyword);
  }

  get initialLetter(): string {
    if (this.userName.length > 0) {
      return this.userName.substring(0, 1).toUpperCase();
    }
    return 'D';
  }

  get showAvatarImage(): boolean {
    return this.avatarUrl.length > 0 && !this.avatarLoadFailed;
  }

  @Builder
  userMenuBuilder() {
    Menu() {
      MenuItem({ content: '网页模式' })
        .onClick(() => {
          this.onOpenWebMode();
        })
      MenuItem({ content: '退出登录' })
        .onClick(() => {
          this.onLogout();
        })
    }
  }

  build() {
    // push 模式裸面板：固定在左侧由聊天页右移露出，无遮罩无进入动画（位移/透明度由 progress 驱动）
    Column() {
      // 顶部搜索框
      Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
          TextInput({ text: this.searchKeyword, placeholder: '搜索对话内容...' })
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .placeholderFont({ size: 14 })
            .backgroundColor(Color.Transparent)
            .padding(0)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.searchKeyword = value;
            })
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor($r('app.color.search_bg'))
        .borderRadius(20)
        .margin({ left: 16, right: 16, top: this.statusBarVp + 16 })
        .alignItems(VerticalAlign.Center)

        // 分组会话列表
        List() {
          ForEach(this.groups, (g: SessionGroup, gIdx: number) => {
            ListItem() {
              Text(g.label)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 6 })
            }
            ForEach(g.items, (s: SessionSummary) => {
              ListItem() {
                Text(s.title)
                  .fontSize(15)
                  .fontColor(s.id === this.activeSessionId ? $r('app.color.brand') : $r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .height(44)
                  .padding({ left: 16, right: 12 })
                  .borderRadius(10)
                  .backgroundColor(s.id === this.activeSessionId ? $r('app.color.input_bg') : Color.Transparent)
                  .width('100%')
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
                  .onClick(() => {
                    this.onSelectSession(s.id);
                  })
              }
            }, (s: SessionSummary): string => s.id)
          }, (g: SessionGroup, gIdx: number): string => `${g.label}_${gIdx}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // 底部：分割线 + 用户信息行
        Divider()
          .color($r('app.color.divider_color'))

        Row({ space: 10 }) {
          if (this.showAvatarImage) {
            Image(this.avatarUrl)
              .width(32)
              .height(32)
              .borderRadius(16)
              .alt($r('app.media.whale_logo'))
              .onError(() => {
                this.avatarLoadFailed = true;
              })
          } else {
            Text(this.initialLetter)
              .fontSize(16)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor($r('app.color.brand'))
              .borderRadius(16)
          }
          Text(this.userName.length > 0 ? this.userName : 'DeepSeek 用户')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
            .padding(8)
            .bindMenu(this.userMenuBuilder)
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 12, bottom: this.navBarVp + 16 })
        .alignItems(VerticalAlign.Center)
    }
    .width(288)
    .height('100%')
    .backgroundColor($r('app.color.drawer_bg'))
    // 灰底自绘状态栏/小白条安全区，消除抽屉上下边缘与窗口底色的割裂
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 内容视差：轻微左移 + 渐显跟随打开进度
    .translate({ x: (1 - this.progress) * -36 })
    .opacity(0.3 + this.progress * 0.7)
    // 点面板空白处关闭（onClick 不冒泡，会话项/菜单项自带点击不受影响）
    .onClick(() => {
      this.onClose();
    })
  }
}
