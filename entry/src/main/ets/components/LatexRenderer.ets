import { LatexNode, LatexNodeKind, LatexResult, parseLatex } from './LatexParser';

const DEGRADED_BG: string = '#EDF1FF';

/**
 * 文本片段模型：拆分数学原子中的英文变量（斜体）与数字/符号（正体）。
 */
class MathTextRun {
  text: string;
  isVariable: boolean;

  constructor(text: string, isVariable: boolean) {
    this.text = text;
    this.isVariable = isVariable;
  }
}

function isAsciiLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

/**
 * 原生 LaTeX 块级公式渲染组件（RD-02 块级全布局）。
 * 支持：分数 Column 上下结构 / 根号 Stack 覆盖线 / 上下标 baselineOffset /
 *       Limits 求和积分上下限 / 未识别命令等宽浅蓝底降级。
 */
@ComponentV2
export struct LatexRenderer {
  @Param source: string = '';
  @Param degraded: boolean = false;
  @Param fontSize: number = 18;

  build() {
    if (this.shouldDegrade()) {
      Text(this.source)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .fontFamily('monospace')
        .backgroundColor(DEGRADED_BG)
        .borderRadius(8)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .width('100%')
    } else {
      Scroll() {
        Row() {
          this.renderSequence(this.parsedChildren(), this.fontSize)
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 4, bottom: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
    }
  }

  private shouldDegrade(): boolean {
    if (this.degraded) {
      return true;
    }
    const res: LatexResult = parseLatex(this.source);
    return res.degraded || res.root === null;
  }

  private parsedChildren(): LatexNode[] {
    const res: LatexResult = parseLatex(this.source);
    if (res.root === null) {
      return [];
    }
    return res.root.children;
  }

  /**
   * 将普通原子文本拆解为英文单字母变量（斜体）与符号/数字（正体）。
   */
  atomRuns(text: string, upright: boolean): MathTextRun[] {
    if (upright || text.length === 0) {
      return [new MathTextRun(text, false)];
    }
    const runs: MathTextRun[] = [];
    let i: number = 0;
    while (i < text.length) {
      const isLetter: boolean = isAsciiLetter(text.charAt(i));
      let j: number = i + 1;
      while (j < text.length && isAsciiLetter(text.charAt(j)) === isLetter) {
        j++;
      }
      runs.push(new MathTextRun(text.substring(i, j), isLetter));
      i = j;
    }
    return runs;
  }

  /** 将仅由 Atom/Styled/Group 组成的简单节点拍平成纯字符串（供上下标偏移单 Text 渲染）。 */
  flattenSimpleScript(node: LatexNode | null): string | null {
    if (node === null) {
      return '';
    }
    if (node.kind === LatexNodeKind.Atom || node.kind === LatexNodeKind.Styled) {
      return node.text;
    }
    if (node.kind === LatexNodeKind.Group) {
      let s: string = '';
      for (const c of node.children) {
        const flat: string | null = this.flattenSimpleScript(c);
        if (flat === null) {
          return null;
        }
        s += flat;
      }
      return s;
    }
    return null;
  }

  @Builder
  renderSequence(nodes: LatexNode[], currentSize: number) {
    ForEach(nodes, (child: LatexNode, idx: number) => {
      this.renderNode(child, currentSize)
    }, (child: LatexNode, idx: number): string => `${idx}_${child.kind}_${child.text}`)
  }

  @Builder
  renderNodeSafe(node: LatexNode | null, currentSize: number) {
    if (node !== null) {
      this.renderNode(node, currentSize)
    }
  }

  @Builder
  renderNode(node: LatexNode, currentSize: number) {
    if (node.kind === LatexNodeKind.Atom) {
      this.renderAtom(node, currentSize)
    } else if (node.kind === LatexNodeKind.Styled) {
      Text(node.text)
        .fontSize(currentSize)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(node.styleBold ? 700 : 400)
        .fontStyle(node.styleItalic ? FontStyle.Italic : FontStyle.Normal)
    } else if (node.kind === LatexNodeKind.Group) {
      Row() {
        this.renderSequence(node.children, currentSize)
      }
      .alignItems(VerticalAlign.Center)
    } else if (node.kind === LatexNodeKind.Sup) {
      this.renderSup(node, currentSize)
    } else if (node.kind === LatexNodeKind.Sub) {
      this.renderSub(node, currentSize)
    } else if (node.kind === LatexNodeKind.Frac) {
      this.renderFrac(node, currentSize)
    } else if (node.kind === LatexNodeKind.Sqrt) {
      this.renderSqrt(node, currentSize)
    } else if (node.kind === LatexNodeKind.Limits) {
      this.renderLimits(node, currentSize)
    } else {
      Text(node.text)
        .fontSize(currentSize)
        .fontColor($r('app.color.text_primary'))
    }
  }

  @Builder
  renderAtom(node: LatexNode, currentSize: number) {
    Row() {
      ForEach(this.atomRuns(node.text, node.upright), (run: MathTextRun, idx: number) => {
        Text(run.text)
          .fontSize(currentSize)
          .fontColor($r('app.color.text_primary'))
          .fontStyle(run.isVariable ? FontStyle.Italic : FontStyle.Normal)
      }, (run: MathTextRun, idx: number): string => `${idx}_${run.text}_${run.isVariable}`)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  renderSup(node: LatexNode, currentSize: number) {
    Row() {
      this.renderNodeSafe(node.base, currentSize)
      if (this.flattenSimpleScript(node.script) !== null) {
        Text(this.flattenSimpleScript(node.script) ?? '')
          .fontSize(Math.max(9, Math.round(currentSize * 0.65)))
          .fontColor($r('app.color.text_primary'))
          .baselineOffset(currentSize * 0.35)
      } else {
        Row() {
          this.renderNodeSafe(node.script, Math.max(9, Math.round(currentSize * 0.65)))
        }
        .alignItems(VerticalAlign.Top)
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  renderSub(node: LatexNode, currentSize: number) {
    Row() {
      this.renderNodeSafe(node.base, currentSize)
      if (this.flattenSimpleScript(node.script) !== null) {
        Text(this.flattenSimpleScript(node.script) ?? '')
          .fontSize(Math.max(9, Math.round(currentSize * 0.65)))
          .fontColor($r('app.color.text_primary'))
          .baselineOffset(-currentSize * 0.2)
      } else {
        Row() {
          this.renderNodeSafe(node.script, Math.max(9, Math.round(currentSize * 0.65)))
        }
        .alignItems(VerticalAlign.Bottom)
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 分数：Column 上下结构，中间横线，居中对齐。 */
  @Builder
  renderFrac(node: LatexNode, currentSize: number) {
    Column() {
      Row() {
        this.renderNodeSafe(node.num, Math.max(10, Math.round(currentSize * 0.85)))
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 3, right: 3, bottom: 2 })

      Divider()
        .color($r('app.color.text_primary'))
        .strokeWidth(1)
        .width('100%')

      Row() {
        this.renderNodeSafe(node.den, Math.max(10, Math.round(currentSize * 0.85)))
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 3, right: 3, top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .constraintSize({ minWidth: 24 })
    .padding({ left: 3, right: 3 })
  }

  /** 根号：Stack 覆盖顶线，可选根指数。 */
  @Builder
  renderSqrt(node: LatexNode, currentSize: number) {
    Row({ space: 0 }) {
      if (node.index !== null) {
        Text(this.flattenSimpleScript(node.index) ?? '')
          .fontSize(Math.max(8, Math.round(currentSize * 0.55)))
          .fontColor($r('app.color.text_primary'))
          .baselineOffset(currentSize * 0.3)
      }
      Text('√')
        .fontSize(currentSize * 1.1)
        .fontColor($r('app.color.text_primary'))
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.renderNodeSafe(node.body, currentSize)
        }
        .padding({ top: 3, left: 2, right: 3 })

        Row()
          .height(1)
          .width('100%')
          .backgroundColor($r('app.color.text_primary'))
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  /** Limits：求和/积分等大运算符，上下限上下堆叠居中。 */
  @Builder
  renderLimits(node: LatexNode, currentSize: number) {
    Column() {
      if (node.upper !== null) {
        Row() {
          this.renderNodeSafe(node.upper, Math.max(9, Math.round(currentSize * 0.6)))
        }
        .alignItems(VerticalAlign.Center)
      }
      Text(node.op)
        .fontSize(currentSize * 1.25)
        .fontColor($r('app.color.text_primary'))
      if (node.lower !== null) {
        Row() {
          this.renderNodeSafe(node.lower, Math.max(9, Math.round(currentSize * 0.6)))
        }
        .alignItems(VerticalAlign.Center)
      }
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 3, right: 3 })
  }
}
