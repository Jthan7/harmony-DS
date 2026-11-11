import { parseMarkdown, parseInlineSpans, MdBlock, MdBlockKind, MdSpan } from './MarkdownParser';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StyledText } from './StyledText';
import { MdTextColorKind } from './MdInlineBuilder';
import { getNavStack } from '../service/NavStackHolder';
import { LatexRenderer } from './LatexRenderer';
import { highlight, HighlightToken, TokenKind } from './CodeHighlighter';
import { MermaidView } from './MermaidView';
import { SearchResultInfo } from '../model/ChatModels';

export function copyToClipboard(text: string): void {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setData(data).catch((e: BusinessError) => {
  });
}

const FONT_SIZE_BODY: number = 18;
const LINE_HEIGHT_BODY: number = 30;
const TAIL_WARN_BUDGET_MS: number = 16;
const DIVIDER_LINE_REG: RegExp = /^(-{3,}|\*{3,}|_{3,})$/;
const FOOTNOTE_DEF_REG: RegExp = /^\[\^(\d+)\]:\s*/;
const LIST_ITEM_HEAD_REG: RegExp = /^(\s*)([-*+]|\d+\.)\s+/;

function isHeadingLine(t: string): boolean {
  let level: number = 0;
  while (level < t.length && t.charAt(level) === '#') {
    level++;
  }
  return level >= 1 && level <= 6 && t.charAt(level) === ' ';
}

/** 单行即完成、完成后解析器状态完全复位的结构行（标题/分割线/脚注定义）。 */
function isResetLine(t: string): boolean {
  return isHeadingLine(t) || DIVIDER_LINE_REG.test(t) || FOOTNOTE_DEF_REG.test(t);
}

/**
 * 块内容签名：用于 ForEach key。
 * @Builder 为值传参，内容变化时若 key 不变则节点被复用、UI 不刷新，
 * 因此 key 必须包含内容指纹（含全部扩展字段），保证流式更新时块被重建、未变化块被复用。
 */
function hashTextInto(hash: number, text: string): number {
  let h: number = hash;
  for (let i: number = 0; i < text.length; i++) {
    h = (h * 31 + text.charCodeAt(i)) | 0;
  }
  return h;
}

function blockSignature(b: MdBlock): string {
  let hash: number = (b.kind * 131 + b.level * 17 + b.depth * 7) | 0;
  hash = (hash * 31 + (b.isOrdered ? 1 : 0) * 3 + b.ordinal) | 0;
  hash = (hash * 31 + b.taskState * 5 + b.quoteLevel * 11) | 0;
  hash = (hash * 31 + (b.codeClosed ? 1 : 0) * 13 + b.footnoteId) | 0;
  hash = hashTextInto(hash, b.codeLang);
  hash = hashTextInto(hash, b.codeText);
  hash = hashTextInto(hash, b.latexSource);
  hash = (hash * 31 + b.spans.length) | 0;
  for (const s of b.spans) {
    hash = hashTextInto(hash, s.text);
    hash = hashTextInto(hash, s.linkUrl);
    hash = hashTextInto(hash, s.imageUrl);
    hash = hashTextInto(hash, s.latexSource);
    hash = (hash * 31 + (s.bold ? 1 : 0) + (s.italic ? 2 : 0) + (s.code ? 4 : 0)
      + (s.strike ? 8 : 0) + s.footnoteRef * 3 + (s.refIndex + 1) * 3) | 0;
  }
  hash = (hash * 31 + b.tableRows.length) | 0;
  for (const row of b.tableRows) {
    hash = (hash * 31 + row.length) | 0;
    for (const cell of row) {
      hash = hashTextInto(hash, cell);
    }
  }
  return `${b.kind}_${hash}`;
}

@ComponentV2
export struct MarkdownRenderer {
  @Param rawText: string = '';
  /** 联网搜索结果：供 [reference:N]/[citation:N] 角标解析与点击 */
  @Param searchResults: SearchResultInfo[] = [];
  @Event onReferenceClick: (url: string, title: string) => void = (_url: string, _title: string): void => {
  };
  @Local blocks: MdBlock[] = [];

  // 硬边界增量缓存：cacheKey 为已确认稳定的文本前缀（截至最近硬边界），
  // cachedBlocks 为其解析结果（只增不改）；scan* 为边界扫描器的增量位置与结构状态。
  private cacheKey: string = '';
  private cachedBlocks: MdBlock[] = [];
  private scanPos: number = 0;
  private scanFence: boolean = false;
  private scanFormula: number = 0; // 0 无；1 $$ 公式；2 \[ 公式

  aboutToAppear(): void {
    this.rebuild(this.rawText);
  }

  @Monitor('rawText')
  onRawTextChange(): void {
    this.rebuild(this.rawText);
  }

  /**
   * 硬边界增量解析：稳定前缀只解析一次并缓存，每次文本追加仅重解析
   * 最近边界之后的短尾段（未闭合代码块/公式/正在增长的段落），
   * 避免长回答流式期间全量重解析。
   */
  private rebuild(text: string): void {
    if (!text.startsWith(this.cacheKey)) {
      // 前缀失效（非追加式更新，如整体替换）：全量重置
      this.cacheKey = '';
      this.cachedBlocks = [];
      this.scanPos = 0;
      this.scanFence = false;
      this.scanFormula = 0;
    }
    this.advanceBoundary(text);
    const tail: string = text.substring(this.cacheKey.length);
    if (tail.length === 0) {
      if (this.blocks !== this.cachedBlocks) {
        this.blocks = this.cachedBlocks;
      }
      return;
    }
    const t0: number = Date.now();
    const tailBlocks: MdBlock[] = parseMarkdown(tail);
    const costMs: number = Date.now() - t0;
    if (costMs > TAIL_WARN_BUDGET_MS) {
      hilog.warn(0x0000, 'MdRender', 'tail parse exceeded budget: cost=%{public}dms, len=%{public}d',
        costMs, tail.length);
    }
    this.blocks = this.cachedBlocks.concat(tailBlocks);
  }

  /**
   * 增量推进硬边界，只扫描上次位置之后的增量行。边界规则镜像
   * MarkdownParser 的行级状态机：围栏/块级公式闭合行之后、标题/分割线/
   * 脚注定义行之后、空行之后（要求下一行已完整接收且不是列表项——
   * 松散列表跨空行续编号）。任何边界之前的文本独立解析结果与全文一致。
   */
  private advanceBoundary(text: string): void {
    let pos: number = this.scanPos;
    let fence: boolean = this.scanFence;
    let formula: number = this.scanFormula;
    let cut: number = this.cacheKey.length;
    while (pos < text.length) {
      const nl: number = text.indexOf('\n', pos);
      if (nl < 0) {
        break; // 末行未收完，等待下一次追加
      }
      const trimmed: string = text.substring(pos, nl).trim();
      if (fence) {
        if (trimmed.startsWith('```')) {
          fence = false;
          cut = nl + 1;
        }
      } else if (formula === 1) {
        if (trimmed === '$$' || trimmed.startsWith('$$')) {
          formula = 0;
          cut = nl + 1;
        }
      } else if (formula === 2) {
        if (trimmed === '\\]' || trimmed.endsWith('\\]')) {
          formula = 0;
          cut = nl + 1;
        }
      } else if (trimmed.length === 0) {
        // 空行切点：下一行必须完整收到，且不是列表项（保护松散列表跨空行续接）
        const nextStart: number = nl + 1;
        const nextNl: number = text.indexOf('\n', nextStart);
        if (nextNl < 0) {
          break;
        }
        if (!LIST_ITEM_HEAD_REG.test(text.substring(nextStart, nextNl))) {
          cut = nextStart;
        }
      } else if (trimmed.startsWith('```')) {
        fence = true;
      } else if (trimmed === '$$') {
        formula = 1;
      } else if (trimmed.startsWith('$$') && trimmed.endsWith('$$') && trimmed.length > 4) {
        cut = nl + 1; // 单行 $$...$$ 公式
      } else if (trimmed === '\\[') {
        formula = 2;
      } else if (isResetLine(trimmed)) {
        cut = nl + 1;
      }
      pos = nl + 1;
    }
    this.scanPos = pos;
    this.scanFence = fence;
    this.scanFormula = formula;
    if (cut > this.cacheKey.length) {
      const seg: string = text.substring(this.cacheKey.length, cut);
      this.cachedBlocks = this.cachedBlocks.concat(parseMarkdown(seg));
      this.cacheKey = text.substring(0, cut);
    }
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks, (b: MdBlock, idx: number) => {
        this.buildBlock(b)
      }, (b: MdBlock, idx: number): string => `${idx}_${blockSignature(b)}`)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 链接点击：携带 url 参数跳转应用内 WebFallbackPage 预览。 */
  openLink(url: string): void {
    const stack: NavPathStack | null = getNavStack();
    if (stack !== null) {
      stack.pushPathByName('WebFallback', url);
    }
  }

  headingSize(level: number): number {
    if (level <= 1) {
      return 26;
    }
    if (level === 2) {
      return 23;
    }
    if (level === 3) {
      return 21;
    }
    if (level === 4) {
      return 19;
    }
    return 18;
  }

  isSingleImage(b: MdBlock): boolean {
    return b.spans.length === 1 && b.spans[0].imageUrl.length > 0;
  }

  isMermaidChart(b: MdBlock): boolean {
    return b.codeClosed && b.codeLang.trim().toLowerCase() === 'mermaid';
  }

  codeTokens(b: MdBlock): HighlightToken[] {
    return highlight(b.codeText, b.codeLang);
  }

  tokenColor(kind: TokenKind): string {
    if (kind === TokenKind.Keyword) {
      return '#C678DD'; // One Dark 紫色
    }
    if (kind === TokenKind.String) {
      return '#98C379'; // One Dark 绿色
    }
    if (kind === TokenKind.Comment) {
      return '#5C6370'; // One Dark 灰色
    }
    if (kind === TokenKind.Number) {
      return '#D19A66'; // One Dark 橙色
    }
    return '#ABB2BF';   // One Dark 浅灰字
  }

  @Builder
  buildBlock(b: MdBlock) {
    if (b.kind === MdBlockKind.Paragraph) {
      this.buildParagraph(b)
    } else if (b.kind === MdBlockKind.Heading) {
      this.buildHeading(b)
    } else if (b.kind === MdBlockKind.Code) {
      this.buildCodeEntry(b)
    } else if (b.kind === MdBlockKind.ListItem) {
      this.buildListItem(b)
    } else if (b.kind === MdBlockKind.Quote) {
      this.buildQuote(b)
    } else if (b.kind === MdBlockKind.Divider) {
      Divider()
        .color($r('app.color.divider_color'))
        .width('100%')
    } else if (b.kind === MdBlockKind.Table) {
      this.buildTable(b)
    } else if (b.kind === MdBlockKind.BlockFormula) {
      this.buildBlockFormula(b)
    } else {
      this.buildFootnoteDef(b)
    }
  }

  @Builder
  buildParagraph(b: MdBlock) {
    if (this.isSingleImage(b)) {
      this.buildImageBlock(b)
    } else {
      StyledText({
        spans: b.spans,
        fontSize: FONT_SIZE_BODY,
        lineHeight: LINE_HEIGHT_BODY,
        colorKind: MdTextColorKind.Primary,
        searchResults: this.searchResults,
        onLinkClick: (url: string) => {
          this.openLink(url);
        },
        onReferenceClick: (url: string, title: string): void => {
          this.onReferenceClick(url, title);
        }
      })
    }
  }

  /** 独立成行的图片：Image 组件渲染，失败时 alt 文本占位。 */
  @Builder
  buildImageBlock(b: MdBlock) {
    Image(b.spans[0].imageUrl)
      .alt(b.spans[0].text)
      .objectFit(ImageFit.Contain)
      .width('100%')
      .constraintSize({ maxHeight: 280 })
      .borderRadius(8)
  }

  @Builder
  buildHeading(b: MdBlock) {
    StyledText({
      spans: b.spans,
      fontSize: this.headingSize(b.level),
      lineHeight: this.headingSize(b.level) * 1.4,
      colorKind: MdTextColorKind.Primary,
      boldWeight: 700,
      searchResults: this.searchResults,
      onLinkClick: (url: string) => {
        this.openLink(url);
      },
      onReferenceClick: (url: string, title: string): void => {
        this.onReferenceClick(url, title);
      }
    })
  }

  @Builder
  buildListItem(b: MdBlock) {
    Row({ space: 6 }) {
      if (b.taskState > 0) {
        // 任务列表复选框两态：已勾选/未勾选
        SymbolGlyph(b.taskState === 2 ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
          .fontSize(21)
          .fontColor(b.taskState === 2 ? [$r('app.color.brand')] : [$r('app.color.text_secondary')])
          .margin({ top: 3 })
      } else {
        Text(b.isOrdered ? `${b.ordinal}.` : '•')
          .fontSize(FONT_SIZE_BODY)
          .lineHeight(LINE_HEIGHT_BODY)
          .fontColor($r('app.color.text_secondary'))
      }
      StyledText({
        spans: b.spans,
        fontSize: FONT_SIZE_BODY,
        lineHeight: LINE_HEIGHT_BODY,
        colorKind: MdTextColorKind.Primary,
        searchResults: this.searchResults,
        onLinkClick: (url: string) => {
          this.openLink(url);
        },
        onReferenceClick: (url: string, title: string): void => {
          this.onReferenceClick(url, title);
        }
      })
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding({ left: b.depth * 18 })
  }

  @Builder
  buildQuote(b: MdBlock) {
    Row({ space: 10 }) {
      Column()
        .width(b.quoteLevel > 1 ? 4 : 3)
        .height('100%')
        .backgroundColor(b.quoteLevel > 1 ? $r('app.color.brand') : $r('app.color.divider_color'))
      StyledText({
        spans: b.spans,
        fontSize: 17,
        lineHeight: 28,
        colorKind: MdTextColorKind.Secondary,
        searchResults: this.searchResults,
        onLinkClick: (url: string) => {
          this.openLink(url);
        },
        onReferenceClick: (url: string, title: string): void => {
          this.onReferenceClick(url, title);
        }
      })
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding({ left: (b.quoteLevel - 1) * 14 })
  }

  /** 脚注定义：文末 [n] 编号 + 说明文本。 */
  @Builder
  buildFootnoteDef(b: MdBlock) {
    Row({ space: 4 }) {
      Text(`[${b.footnoteId}]`)
        .fontSize(13)
        .fontColor($r('app.color.brand'))
        .margin({ top: 2 })
      StyledText({
        spans: b.spans,
        fontSize: 14,
        lineHeight: 22,
        colorKind: MdTextColorKind.Secondary,
        searchResults: this.searchResults,
        onLinkClick: (url: string) => {
          this.openLink(url);
        },
        onReferenceClick: (url: string, title: string): void => {
          this.onReferenceClick(url, title);
        }
      })
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
  }

  @Builder
  buildCodeEntry(b: MdBlock) {
    if (this.isMermaidChart(b)) {
      MermaidView({ code: b.codeText, closed: b.codeClosed })
    } else {
      this.buildCodeBlock(b)
    }
  }

  @Builder
  buildCodeBlock(b: MdBlock) {
    Column() {
      Row() {
        Text(b.codeLang.length > 0 ? b.codeLang : '代码')
          .fontSize(14)
          .fontColor('#9DA5B4')
        Blank()
        Text('复制')
          .fontSize(14)
          .fontColor('#9DA5B4')
          .onClick(() => {
            copyToClipboard(b.codeText);
            this.getUIContext().getPromptAction().showToast({ message: '已复制代码' });
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      Scroll() {
        Text() {
          if (this.codeTokens(b).length === 0) {
            Span(b.codeText)
              .fontSize(15)
              .fontColor($r('app.color.code_text'))
              .fontFamily('monospace')
          } else {
            ForEach(this.codeTokens(b), (t: HighlightToken) => {
              Span(t.text)
                .fontSize(15)
                .fontColor(this.tokenColor(t.kind))
                .fontFamily('monospace')
            }, (t: HighlightToken, idx: number): string => `${idx}_${t.kind}_${t.text.length}`)
          }
        }
        .fontSize(15)
        .lineHeight(24)
        .padding(12)
        // 长按选择代码文字并复制（系统选择菜单；横向滚动与长按由手势消歧）
        .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        .copyOption(CopyOptions.LocalDevice)
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

  @Builder
  buildTable(b: MdBlock) {
    Scroll() {
      Column() {
        ForEach(b.tableRows, (row: string[], rIdx: number) => {
          Row() {
            ForEach(row, (cell: string, cIdx: number) => {
              // 表格单元格支持行内格式（粗体/链接/行内代码等）
              StyledText({
                spans: parseInlineSpans(cell.trim()),
                fontSize: 15,
                lineHeight: 22,
                colorKind: rIdx === 0 ? MdTextColorKind.Primary : MdTextColorKind.Secondary,
                boldWeight: rIdx === 0 ? 700 : 400,
                searchResults: this.searchResults,
                onLinkClick: (url: string) => {
                  this.openLink(url);
                },
                onReferenceClick: (url: string, title: string): void => {
                  this.onReferenceClick(url, title);
                }
              })
                .padding(8)
                .constraintSize({ minWidth: 80 })
                .border({ width: 0.5, color: $r('app.color.divider_color') })
            }, (cell: string, cIdx: number): string => `${rIdx}_${cIdx}_${cell.length}`)
          }
        }, (row: string[], rIdx: number): string => `${rIdx}_${row.length}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .width('100%')
  }

  /** 块级公式：已闭合走 LatexRenderer 原生布局/降级，流式未闭合保持原文。 */
  @Builder
  buildBlockFormula(b: MdBlock) {
    if (!b.codeClosed) {
      Text(b.latexSource.length > 0 ? b.latexSource : '$$')
        .fontSize(16)
        .lineHeight(26)
        .fontColor($r('app.color.text_primary'))
        .fontFamily('monospace')
        .width('100%')
    } else {
      LatexRenderer({ source: b.latexSource, fontSize: 18 })
    }
  }
}
