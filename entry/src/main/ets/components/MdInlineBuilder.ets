import { MdSpan } from './MarkdownParser';
import { LengthMetrics } from '@kit.ArkUI';
import { linearizeLatexInline, LatexRun } from './LatexParser';
import { SearchResultInfo } from '../model/ChatModels';

/**
 * 文本颜色类别：供 buildInlineStyled 决定基础前景色。
 */
export enum MdTextColorKind {
  Primary = 0,
  Secondary = 1
}

const FOOTNOTE_SCALE: number = 0.65;
const IMAGE_INLINE_WIDTH: number = 140;
const IMAGE_INLINE_HEIGHT: number = 90;
/** 引用角标缩放（略小于脚注，呈上标徽标形态） */
const REF_SCALE: number = 0.6;
/** 品牌色 #4D6BFE 的 10% 透明浅底 */
const REF_BADGE_BG: string = 'rgba(77, 107, 254, 0.10)';

function baseColor(kind: number): Resource {
  if (kind === MdTextColorKind.Secondary) {
    return $r('app.color.text_secondary');
  }
  return $r('app.color.text_primary');
}

/**
 * MdSpan[] → MutableStyledString 构建器。
 * 样式全部通过 StyledString 体系承载：
 * - TextStyle：颜色/字号/粗斜体/等宽字体
 * - DecorationStyle：删除线/下划线
 * - BaselineOffsetStyle：脚注角标上下偏移
 * - GestureStyle：链接点击（回调对象随 MutableStyledString 成员存活，见 faqs-arkui-901）
 * - ImageAttachment：行内图片（网络 URL，失败时该占位为空白）
 * 行内公式（latexSource）由 US2 阶段接入 linearizeLatexInline 线性化。
 */
export function buildInlineStyled(spans: MdSpan[], fontSize: number, colorKind: number,
  onLink: (url: string) => void, searchResults: SearchResultInfo[],
  onRef: (url: string, title: string) => void): MutableStyledString {
  const result: MutableStyledString = new MutableStyledString('');
  for (const s of spans) {
    appendSpan(result, s, fontSize, colorKind, onLink, searchResults, onRef);
  }
  return result;
}

/**
 * 引用角标解析：[reference:N]/[citation:N] 的 raw N → 搜索结果条目。
 * 三层兜底：citeIndex 精确匹配 → 数组下标 N → 数组下标 N-1（cite_index 0/1-based 兼容）。
 */
function resolveReference(refIndex: number, searchResults: SearchResultInfo[]): SearchResultInfo | null {
  if (searchResults.length === 0) {
    return null;
  }
  for (const r of searchResults) {
    if (r.citeIndex === refIndex) {
      return r;
    }
  }
  if (refIndex >= 0 && refIndex < searchResults.length) {
    return searchResults[refIndex];
  }
  if (refIndex > 0 && refIndex - 1 < searchResults.length) {
    return searchResults[refIndex - 1];
  }
  return null;
}

function isAsciiLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

/**
 * 行内公式处理：linearizeLatexInline 线性化为 StyledString 片段。
 * 上下标通过 BaselineOffsetStyle 抬高/降低并缩小字号，英文变量设斜体。
 * 降级时整段按等宽浅色背景原文渲染。
 */
function appendLatexSpan(target: MutableStyledString, s: MdSpan, fontSize: number): void {
  const runs: LatexRun[] = linearizeLatexInline(s.latexSource);
  if (runs.length === 0) {
    // 降级：等宽浅色背景原文
    const rawText: string = s.latexSource.length > 0 ? s.latexSource : ' ';
    const seg: MutableStyledString = new MutableStyledString(rawText);
    seg.setStyle({
      start: 0, length: rawText.length,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({ fontColor: $r('app.color.text_primary'), fontFamily: 'monospace' })
    });
    seg.setStyle({
      start: 0, length: rawText.length,
      styledKey: StyledStringKey.BACKGROUND_COLOR,
      styledValue: new BackgroundColorStyle({ color: $r('app.color.input_bg'), radius: 4 })
    });
    target.appendStyledString(seg);
    return;
  }
  for (const run of runs) {
    appendLatexRun(target, run, fontSize);
  }
}

function appendLatexRun(target: MutableStyledString, run: LatexRun, fontSize: number): void {
  if (run.text.length === 0) {
    return;
  }
  const scale: number = run.kind === 0 ? 0.95 : 0.7;
  const runSize: number = Math.max(9, Math.round(fontSize * scale));
  const seg: MutableStyledString = new MutableStyledString(run.text);
  const textLen: number = run.text.length;
  const baseColor: Resource = $r('app.color.text_primary');

  // 变量字母斜体，符号/数字正体
  let i: number = 0;
  while (i < textLen) {
    const isLetter: boolean = isAsciiLetter(run.text.charAt(i));
    let j: number = i + 1;
    while (j < textLen && isAsciiLetter(run.text.charAt(j)) === isLetter) {
      j++;
    }
    seg.setStyle({
      start: i,
      length: j - i,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({
        fontColor: baseColor,
        fontSize: LengthMetrics.fp(runSize),
        fontStyle: isLetter ? FontStyle.Italic : FontStyle.Normal
      })
    });
    i = j;
  }

  // 上标抬高 / 下标降低
  if (run.kind === 1) {
    seg.setStyle({
      start: 0,
      length: textLen,
      styledKey: StyledStringKey.BASELINE_OFFSET,
      styledValue: new BaselineOffsetStyle(LengthMetrics.vp(fontSize * 0.32))
    });
  } else if (run.kind === 2) {
    seg.setStyle({
      start: 0,
      length: textLen,
      styledKey: StyledStringKey.BASELINE_OFFSET,
      styledValue: new BaselineOffsetStyle(LengthMetrics.vp(-fontSize * 0.16))
    });
  }
  target.appendStyledString(seg);
}

function appendSpan(target: MutableStyledString, s: MdSpan, fontSize: number,
  colorKind: number, onLink: (url: string) => void, searchResults: SearchResultInfo[],
  onRef: (url: string, title: string) => void): void {
  // 行内公式：由 linearizeLatexInline 线性化并设置 BaselineOffsetStyle
  if (s.latexSource.length > 0) {
    appendLatexSpan(target, s, fontSize);
    return;
  }
  // 行内图片：ImageAttachment 占 1 字符
  if (s.imageUrl.length > 0) {
    const imgOptions: ResourceImageAttachmentOptions = {
      resourceValue: s.imageUrl,
      size: { width: IMAGE_INLINE_WIDTH, height: IMAGE_INLINE_HEIGHT },
      verticalAlign: ImageSpanAlignment.BOTTOM,
      objectFit: ImageFit.Contain
    };
    const attachment: ImageAttachment = new ImageAttachment(imgOptions);
    const imgSeg: MutableStyledString = new MutableStyledString(attachment);
    target.appendStyledString(imgSeg);
    return;
  }
  const segText: string = s.text.length > 0 ? s.text : ' ';
  const seg: MutableStyledString = new MutableStyledString(segText);
  const segLen: number = segText.length;
  const color: Resource = baseColor(colorKind);

  // 字体样式
  if (s.refIndex >= 0) {
    // 引用角标：上标小徽标（品牌色 + 浅底），未解析到来源时灰色不可点
    const hit: SearchResultInfo | null = resolveReference(s.refIndex, searchResults);
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({
        fontColor: hit !== null ? $r('app.color.brand') : $r('app.color.text_secondary'),
        fontSize: LengthMetrics.fp(Math.max(10, Math.round(fontSize * REF_SCALE)))
      })
    });
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.BASELINE_OFFSET,
      styledValue: new BaselineOffsetStyle(LengthMetrics.vp(fontSize * 0.3))
    });
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.BACKGROUND_COLOR,
      styledValue: new BackgroundColorStyle({ color: REF_BADGE_BG, radius: 3 })
    });
    if (hit !== null) {
      // GestureStyle 回调对象提升引用：随 MutableStyledString 存活（faqs-arkui-901）
      const refGesture: GestureStyle = new GestureStyle({
        onClick: (event: ClickEvent) => {
          onRef(hit.url, hit.title);
        }
      });
      seg.setStyle({
        start: 0, length: segLen,
        styledKey: StyledStringKey.GESTURE,
        styledValue: refGesture
      });
    }
  } else if (s.footnoteRef > 0) {
    // 脚注角标：缩小字号 + 品牌色
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({
        fontColor: $r('app.color.brand'),
        fontSize: LengthMetrics.fp(Math.max(10, Math.round(fontSize * FOOTNOTE_SCALE)))
      })
    });
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.BASELINE_OFFSET,
      styledValue: new BaselineOffsetStyle(LengthMetrics.vp(fontSize * 0.3))
    });
  } else if (s.code) {
    // 行内代码：等宽 + 品牌色
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({ fontColor: $r('app.color.brand'), fontFamily: 'monospace' })
    });
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.BACKGROUND_COLOR,
      styledValue: new BackgroundColorStyle({ color: $r('app.color.input_bg'), radius: 4 })
    });
  } else if (s.linkUrl.length > 0) {
    // 链接：品牌色 + 下划线 + 点击手势
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({ fontColor: $r('app.color.brand') })
    });
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.DECORATION,
      styledValue: new DecorationStyle({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
    });
    // GestureStyle 回调对象提升引用：随 MutableStyledString 存活（faqs-arkui-901）
    const gesture: GestureStyle = new GestureStyle({
      onClick: (event: ClickEvent) => {
        onLink(s.linkUrl);
      }
    });
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.GESTURE,
      styledValue: gesture
    });
  } else {
    const styleOpts: TextStyleInterface = { fontColor: color };
    if (s.bold) {
      styleOpts.fontWeight = FontWeight.Bold;
    }
    if (s.italic) {
      styleOpts.fontStyle = FontStyle.Italic;
    }
    if (s.strike) {
      // 删除线：基础色 + LineThrough
      styleOpts.fontColor = color;
    }
    seg.setStyle({
      start: 0, length: segLen,
      styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle(styleOpts)
    });
    if (s.strike) {
      seg.setStyle({
        start: 0, length: segLen,
        styledKey: StyledStringKey.DECORATION,
        styledValue: new DecorationStyle({ type: TextDecorationType.LineThrough, color: color })
      });
    }
  }
  target.appendStyledString(seg);
}
