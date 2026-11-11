/** 导航条窗口大小（奇数，激活项居中） */
const QA_RAIL_WINDOW: number = 7;
/** 拖动步进阈值：每累计 24vp 位移跳一问 */
const QA_RAIL_DRAG_STEP: number = 24;

/**
 * 右侧问答导航条：每个用户提问一个圆点，当前问答呈品牌色小竖条。
 * 窗口化显示（最多 7 个，激活项居中），长会话不溢出屏幕。
 * 点按圆点弹簧跳转（animated=true）；在条带上拖动按 24vp 步进即时 scrub（animated=false）。
 * 形态块（圆点↔竖条）通过 .animation 属性动画平滑变形。
 */
@ComponentV2
export struct QaNavRail {
  /** 用户消息在消息列表中的索引（升序） */
  @Param marks: number[] = [];
  /** 当前激活的 mark 下标 */
  @Param activeIndex: number = 0;
  /** 跳转请求：markIndex 目标 mark；animated 是否弹簧动画（拖动 scrub 传 false） */
  @Event onJump: (markIndex: number, animated: boolean) => void =
    (_markIndex: number, _animated: boolean): void => {
    };

  /** 拖动放大反馈态 */
  @Local dragging: boolean = false;

  /** 拖动 scrub 状态：窗口 y 坐标、累计位移、拖动期间权威下标、是否已超出点按容忍区 */
  private lastY: number = 0;
  private accDy: number = 0;
  private scrubIndex: number = -1;
  private moved: boolean = false;

  /** 可见窗口起始 mark 下标（激活项尽量居中） */
  private windowStart(): number {
    if (this.marks.length <= QA_RAIL_WINDOW) {
      return 0;
    }
    let start: number = this.activeIndex - Math.floor(QA_RAIL_WINDOW / 2);
    if (start < 0) {
      start = 0;
    }
    const maxStart: number = this.marks.length - QA_RAIL_WINDOW;
    if (start > maxStart) {
      start = maxStart;
    }
    return start;
  }

  /** 可见 mark 下标数组（元素即 mark 下标） */
  private visibleMarks(): number[] {
    const start: number = this.windowStart();
    const count: number = Math.min(QA_RAIL_WINDOW, this.marks.length);
    const out: number[] = [];
    for (let i: number = 0; i < count; i++) {
      out.push(start + i);
    }
    return out;
  }

  private clampIndex(idx: number): number {
    if (idx < 0) {
      return 0;
    }
    if (idx > this.marks.length - 1) {
      return this.marks.length - 1;
    }
    return idx;
  }

  /** 距离衰减：离激活竖条越远的圆点越小（7→6→5，4 封底） */
  private dotSizeFor(markIdx: number): number {
    const d: number = Math.abs(markIdx - this.activeIndex);
    const size: number = 7 - d;
    return size < 4 ? 4 : size;
  }

  /**
   * 拖动 scrub：累计 dy，每越 24vp 步进跳一问；显著位移后抑制点按（moved）。
   * 仅条带整体挂 onTouch，子项只扩大点击热区，避免重复计数。
   */
  private handleRailTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.lastY = event.touches[0].y;
      this.accDy = 0;
      this.moved = false;
      this.scrubIndex = this.activeIndex;
      this.dragging = true;
      return;
    }
    if (event.type === TouchType.Move) {
      const y: number = event.touches[0].y;
      this.accDy += y - this.lastY;
      this.lastY = y;
      while (this.accDy >= QA_RAIL_DRAG_STEP && this.scrubIndex < this.marks.length - 1) {
        this.accDy -= QA_RAIL_DRAG_STEP;
        this.moved = true;
        this.scrubIndex = this.clampIndex(this.scrubIndex + 1);
        this.onJump(this.scrubIndex, false);
      }
      while (this.accDy <= -QA_RAIL_DRAG_STEP && this.scrubIndex > 0) {
        this.accDy += QA_RAIL_DRAG_STEP;
        this.moved = true;
        this.scrubIndex = this.clampIndex(this.scrubIndex - 1);
        this.onJump(this.scrubIndex, false);
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.dragging = false;
      this.scrubIndex = -1;
    }
  }

  build() {
    Column() {
      ForEach(this.visibleMarks(), (markIdx: number) => {
        Column() {
          // 形态块：圆点 ↔ 品牌色竖条，同一节点属性动画平滑变形；圆点随离激活项距离衰减变小
          Column()
            .width(markIdx === this.activeIndex ? 4 : this.dotSizeFor(markIdx))
            .height(markIdx === this.activeIndex ? 20 : this.dotSizeFor(markIdx))
            .borderRadius(markIdx === this.activeIndex ? 2 : this.dotSizeFor(markIdx) / 2)
            .backgroundColor(markIdx === this.activeIndex ? $r('app.color.brand') : 'rgba(38, 38, 38, 0.25)')
            .animation({ duration: 200, curve: Curve.EaseOut })
        }
        .width(36)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          if (!this.moved) {
            this.onJump(markIdx, true);
          }
        })
      }, (markIdx: number): string => `qarail_${markIdx}`)
    }
    .alignItems(HorizontalAlign.Center)
    .scale(this.dragging ? { x: 1.15, y: 1.15 } : { x: 1, y: 1 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      this.handleRailTouch(event);
    })
  }
}
