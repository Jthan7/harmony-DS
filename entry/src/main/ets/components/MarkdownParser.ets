/**
 * 轻量 Markdown 解析器（零依赖，纯 ArkTS）。
 * 支持：标题 / 段落 / 加粗 / 斜体 / 删除线 / 行内代码 / 链接 / 行内图片 / 脚注 /
 *       代码块 / 嵌套无序与有序列表 / 任务列表 / 引用（合并+嵌套）/ 分割线 / 表格 /
 *       块级与行内 LaTeX 公式识别（货币防误判）/ 转义字符 / 软换行保留。
 * 输出块数组，供 MarkdownRenderer 用原生组件渲染。
 */

export enum MdBlockKind {
  Paragraph = 0,
  Heading = 1,
  Code = 2,
  ListItem = 3,
  Quote = 4,
  Divider = 5,
  Table = 6,
  BlockFormula = 7,
  FootnoteDef = 8
}

export class MdSpan {
  text: string;
  bold: boolean = false;
  italic: boolean = false;
  code: boolean = false;
  linkUrl: string = '';
  strike: boolean = false;
  imageUrl: string = '';
  footnoteRef: number = 0;
  latexSource: string = '';
  /** [reference:N]/[citation:N] 的原始 N（-1 表示非引用角标），text 为显示编号 N+1 */
  refIndex: number = -1;

  constructor(text: string) {
    this.text = text;
  }
}

export class MdBlock {
  kind: MdBlockKind;
  spans: MdSpan[] = [];
  level: number = 0;
  codeLang: string = '';
  codeText: string = '';
  isOrdered: boolean = false;
  ordinal: number = 0;
  tableRows: string[][] = [];
  depth: number = 0;
  taskState: number = 0;
  codeClosed: boolean = true;
  quoteLevel: number = 0;
  latexSource: string = '';
  footnoteId: number = 0;

  constructor(kind: MdBlockKind) {
    this.kind = kind;
  }
}

/** 行内公式识别的 LaTeX 特征字符。 */
const LATEX_FEATURE_REG: RegExp = /[\^_\\{}]/;
/** ≤20 字符的纯数学串（数字/字母/基础运算符），用于货币 $ 防误判的接受分支。 */
const SHORT_MATH_REG: RegExp = /^[0-9a-zA-Z.+\-*/=<>() ]{1,20}$/;
/** 行内转义字符集合：\x 一律按字面渲染。 */
const ESCAPABLE_CHARS: string = '\\*~$[](){}#>!`_+-.';
const MAX_INLINE_FORMULA_LEN: number = 300;

class MdParser {
  private blocks: MdBlock[] = [];
  private paraBuffer: string[] = [];
  private listIndentStack: number[] = [];
  private orderedCounters: number[] = [];
  private lastListDepth: number = -1;

  parse(src: string): MdBlock[] {
    this.blocks = [];
    this.paraBuffer = [];
    this.listIndentStack = [];
    this.orderedCounters = [];
    this.lastListDepth = -1;
    const lines: string[] = src.split('\n');
    let i: number = 0;
    while (i < lines.length) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        this.flushParagraph();
        i++;
        continue;
      }
      if (trimmed.startsWith('```')) {
        this.flushParagraph();
        this.resetListState();
        i = this.consumeCodeBlock(lines, i);
        continue;
      }
      const blockFormulaStart: boolean = trimmed === '$$' ||
        (trimmed.startsWith('$$') && trimmed.endsWith('$$') && trimmed.length > 4);
      if (blockFormulaStart) {
        this.flushParagraph();
        this.resetListState();
        i = this.consumeBlockFormula(lines, i);
        continue;
      }
      if (trimmed === '\\[') {
        this.flushParagraph();
        this.resetListState();
        i = this.consumeBracketFormula(lines, i);
        continue;
      }
      const headingMatch: string[] = this.matchHeading(trimmed);
      if (headingMatch.length > 0) {
        this.flushParagraph();
        this.resetListState();
        const block: MdBlock = new MdBlock(MdBlockKind.Heading);
        block.level = Number(headingMatch[0]) || 1;
        block.spans = this.parseInline(headingMatch[1]);
        this.blocks.push(block);
        i++;
        continue;
      }
      if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
        this.flushParagraph();
        this.resetListState();
        this.blocks.push(new MdBlock(MdBlockKind.Divider));
        i++;
        continue;
      }
      const footnoteId: number = this.matchFootnoteDef(trimmed);
      if (footnoteId > 0) {
        this.flushParagraph();
        this.resetListState();
        const block: MdBlock = new MdBlock(MdBlockKind.FootnoteDef);
        block.footnoteId = footnoteId;
        const rest: string = trimmed.replace(/^\[\^\d+\]:\s*/, '');
        block.spans = this.parseInline(rest);
        this.blocks.push(block);
        i++;
        continue;
      }
      if (trimmed.startsWith('>')) {
        this.flushParagraph();
        this.resetListState();
        i = this.consumeQuote(lines, i);
        continue;
      }
      if (trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.length > 2) {
        this.flushParagraph();
        this.resetListState();
        i = this.consumeTable(lines, i);
        continue;
      }
      const listMatch: ListItemMatch | null = this.matchListItem(line);
      if (listMatch !== null) {
        this.flushParagraph();
        this.pushListItem(listMatch);
        i++;
        continue;
      }
      this.resetListState();
      this.orderedCounters = [];
      this.paraBuffer.push(trimmed);
      i++;
    }
    this.flushParagraph();
    return this.blocks;
  }

  private resetListState(): void {
    this.listIndentStack = [];
    this.lastListDepth = -1;
  }

  /** 返回 [级别字符串, 内容]；非标题返回空数组。 */
  private matchHeading(line: string): string[] {
    let level: number = 0;
    while (level < line.length && line.charAt(level) === '#') {
      level++;
    }
    if (level >= 1 && level <= 6 && line.charAt(level) === ' ') {
      return [`${level}`, line.substring(level + 1).trim()];
    }
    return [];
  }

  /** 脚注定义行 `[^n]: text`：返回编号；非定义行返回 0。 */
  private matchFootnoteDef(line: string): number {
    const reg: RegExp = /^\[\^(\d+)\]:\s*/;
    const m: RegExpMatchArray | null = line.match(reg);
    if (m !== null && m.length >= 2) {
      return Number(m[1]) || 0;
    }
    return 0;
  }

  /** 计算行首缩进宽度：空格计 1，Tab 按 4 列对齐（Tab=4 空格）。 */
  private indentWidth(line: string): number {
    let w: number = 0;
    for (let i: number = 0; i < line.length; i++) {
      const ch: string = line.charAt(i);
      if (ch === ' ') {
        w++;
      } else if (ch === '\t') {
        w += 4 - (w % 4);
      } else {
        break;
      }
    }
    return w;
  }

  /** 列表项匹配结果（显式模型，避免 any）。 */
  private matchListItem(line: string): ListItemMatch | null {
    const reg: RegExp = /^(\s*)([-*+]|\d+\.)\s+/;
    const m: RegExpMatchArray | null = line.match(reg);
    if (m === null || m.length < 3) {
      return null;
    }
    const marker: string = m[2];
    let content: string = line.substring(m[0].length).trim();
    const isOrdered: boolean = marker !== '-' && marker !== '*' && marker !== '+';
    let taskState: number = 0;
    if (!isOrdered) {
      if (content.startsWith('[ ] ') || content === '[ ]') {
        taskState = 1;
        content = content.substring(3).trim();
      } else if (content.toLowerCase().startsWith('[x] ')) {
        taskState = 2;
        content = content.substring(3).trim();
      } else if (content.toLowerCase() === '[x]') {
        taskState = 2;
        content = '';
      }
    }
    const result: ListItemMatch = new ListItemMatch();
    result.indent = this.indentWidth(line);
    result.isOrdered = isOrdered;
    result.taskState = taskState;
    result.content = content;
    return result;
  }

  /** 列表层级计算：与已开层级栈比较缩进，2/4 空格与 Tab 混合均可正确分级。 */
  private pushListItem(item: ListItemMatch): void {
    const stack: number[] = this.listIndentStack;
    while (stack.length > 0 && item.indent <= stack[stack.length - 1]) {
      stack.pop();
    }
    const depth: number = stack.length;
    stack.push(item.indent);
    const block: MdBlock = new MdBlock(MdBlockKind.ListItem);
    block.depth = depth;
    block.isOrdered = item.isOrdered;
    block.taskState = item.taskState;
    if (item.isOrdered) {
      const continuation: boolean = this.lastListDepth === depth;
      const prev: number = this.orderedCounters.length > depth ? this.orderedCounters[depth] : 0;
      block.ordinal = continuation ? prev + 1 : 1;
      while (this.orderedCounters.length <= depth) {
        this.orderedCounters.push(0);
      }
      this.orderedCounters[depth] = block.ordinal;
    }
    this.lastListDepth = depth;
    block.spans = this.parseInline(item.content);
    this.blocks.push(block);
  }

  /** 代码块消费：支持流式未闭合（codeClosed=false）。 */
  private consumeCodeBlock(lines: string[], startIdx: number): number {
    const block: MdBlock = new MdBlock(MdBlockKind.Code);
    const fence: string = lines[startIdx].trim();
    block.codeLang = fence.substring(3).trim();
    block.codeClosed = false;
    let i: number = startIdx + 1;
    const codeLines: string[] = [];
    while (i < lines.length) {
      const line: string = lines[i];
      if (line.trim().startsWith('```')) {
        block.codeClosed = true;
        i++;
        break;
      }
      codeLines.push(line);
      i++;
    }
    block.codeText = codeLines.join('\n');
    this.blocks.push(block);
    return i;
  }

  /** 块级公式 `$$...$$`：单行或跨行；流式未闭合按原文输出（codeClosed=false）。 */
  private consumeBlockFormula(lines: string[], startIdx: number): number {
    const block: MdBlock = new MdBlock(MdBlockKind.BlockFormula);
    const first: string = lines[startIdx].trim();
    if (first.length > 4 && first.endsWith('$$')) {
      // 单行 $$...$$
      block.latexSource = first.substring(2, first.length - 2).trim();
      block.codeClosed = true;
      this.blocks.push(block);
      return startIdx + 1;
    }
    block.codeClosed = false;
    const bodyLines: string[] = [];
    let i: number = startIdx + 1;
    while (i < lines.length) {
      const t: string = lines[i].trim();
      if (t === '$$' || t.startsWith('$$')) {
        block.codeClosed = true;
        const inlineRest: string = t === '$$' ? '' : t.substring(2).trim();
        if (inlineRest.length > 0) {
          bodyLines.push(inlineRest);
        }
        i++;
        break;
      }
      bodyLines.push(lines[i]);
      i++;
    }
    block.latexSource = bodyLines.join('\n').trim();
    this.blocks.push(block);
    return i;
  }

  /** 块级公式 `\[...\]` 定界符形式。 */
  private consumeBracketFormula(lines: string[], startIdx: number): number {
    const block: MdBlock = new MdBlock(MdBlockKind.BlockFormula);
    block.codeClosed = false;
    const bodyLines: string[] = [];
    let i: number = startIdx + 1;
    while (i < lines.length) {
      const t: string = lines[i].trim();
      if (t === '\\]' || t.endsWith('\\]')) {
        block.codeClosed = true;
        const inlineRest: string = t === '\\]' ? '' : t.substring(0, t.length - 2).trim();
        if (inlineRest.length > 0) {
          bodyLines.push(inlineRest);
        }
        i++;
        break;
      }
      bodyLines.push(lines[i]);
      i++;
    }
    block.latexSource = bodyLines.join('\n').trim();
    this.blocks.push(block);
    return i;
  }

  /** 引用消费：相邻行若层级相同则合并，若层级变化则按各自 quoteLevel 产出独立引用块。 */
  private consumeQuote(lines: string[], startIdx: number): number {
    let i: number = startIdx;
    while (i < lines.length) {
      const trimmed: string = lines[i].trim();
      if (!trimmed.startsWith('>')) {
        break;
      }
      let level: number = 0;
      while (level < trimmed.length && trimmed.charAt(level) === '>') {
        level++;
      }
      const segLines: string[] = [];
      while (i < lines.length) {
        const curTrim: string = lines[i].trim();
        if (!curTrim.startsWith('>')) {
          break;
        }
        let curLevel: number = 0;
        while (curLevel < curTrim.length && curTrim.charAt(curLevel) === '>') {
          curLevel++;
        }
        if (curLevel !== level) {
          // 层级发生变化，切断当前段
          break;
        }
        let stripped: string = curTrim.substring(level).trim();
        segLines.push(stripped);
        i++;
      }
      const block: MdBlock = new MdBlock(MdBlockKind.Quote);
      block.quoteLevel = Math.max(1, level);
      block.spans = this.parseInline(segLines.join('\n'));
      this.blocks.push(block);
    }
    return i;
  }

  private consumeTable(lines: string[], startIdx: number): number {
    const block: MdBlock = new MdBlock(MdBlockKind.Table);
    let i: number = startIdx;
    while (i < lines.length) {
      const trimmed: string = lines[i].trim();
      if (!(trimmed.startsWith('|') && trimmed.endsWith('|'))) {
        break;
      }
      const cellsRaw: string[] = trimmed.substring(1, trimmed.length - 1).split('|');
      const isSeparator: boolean = this.isTableSeparatorRow(cellsRaw);
      if (!isSeparator) {
        block.tableRows.push(cellsRaw);
      }
      i++;
    }
    if (block.tableRows.length === 0) {
      // 全是分隔行，丢弃
      return i;
    }
    this.blocks.push(block);
    return i;
  }

  /** 表格分隔行变体：---、:---、---:、:---:、:-: 等全部识别。 */
  private isTableSeparatorRow(cells: string[]): boolean {
    if (cells.length === 0) {
      return true;
    }
    for (const c of cells) {
      const t: string = c.trim();
      if (!(t === '' || /^:?-+:?$/.test(t) || /^:+$/.test(t))) {
        return false;
      }
    }
    return true;
  }

  private flushParagraph(): void {
    if (this.paraBuffer.length === 0) {
      return;
    }
    const block: MdBlock = new MdBlock(MdBlockKind.Paragraph);
    // 软换行保留：段内单换行不合并为空格
    block.spans = this.parseInline(this.paraBuffer.join('\n'));
    this.blocks.push(block);
    this.paraBuffer = [];
  }

  parseInline(text: string): MdSpan[] {
    const spans: MdSpan[] = [];
    let plain: string = '';
    let i: number = 0;
    const flushPlain = (): void => {
      if (plain.length > 0) {
        spans.push(new MdSpan(plain));
        plain = '';
      }
    };
    while (i < text.length) {
      const ch: string = text.charAt(i);
      // 转义字符：\* \~ \$ 等一律字面显示，不触发格式
      if (ch === '\\') {
        const next: string = i + 1 < text.length ? text.charAt(i + 1) : '';
        if (next.length > 0 && ESCAPABLE_CHARS.indexOf(next) >= 0) {
          // \(...\) 或 \[...\] 可能是行内公式定界符：需找到对应闭合且内容含 LaTeX 特征才按公式处理
          if (next === '(' || next === '[') {
            const closeMarker: string = next === '(' ? '\\)' : '\\]';
            const closeIdx: number = text.indexOf(closeMarker, i + 2);
            if (closeIdx > i + 2) {
              const inner: string = text.substring(i + 2, closeIdx);
              if (inner.length <= MAX_INLINE_FORMULA_LEN && LATEX_FEATURE_REG.test(inner)) {
                flushPlain();
                const latexSpan: MdSpan = new MdSpan(inner);
                latexSpan.latexSource = inner;
                spans.push(latexSpan);
                i = closeIdx + 2;
                continue;
              }
            }
          }
          plain += next;
          i += 2;
          continue;
        }
        plain += ch;
        i++;
        continue;
      }
      // 行内公式 $...$（货币防误判：开 $ 后紧邻非空白、闭 $ 前紧邻非空白、
      // 内容含 LaTeX 特征字符或为 ≤20 字符纯数学串）
      if (ch === '$') {
        const openOk: boolean = i + 1 < text.length && text.charAt(i + 1) !== ' ';
        if (openOk) {
          const closeIdx: number = text.indexOf('$', i + 2);
          if (closeIdx > i + 1) {
            const inner: string = text.substring(i + 1, closeIdx);
            const closeOk: boolean = text.charAt(closeIdx - 1) !== ' ';
            const noNewline: boolean = inner.indexOf('\n') < 0;
            const noDollar: boolean = inner.indexOf('$') < 0;
            const bounded: boolean = inner.length <= MAX_INLINE_FORMULA_LEN;
            const featured: boolean = LATEX_FEATURE_REG.test(inner) || SHORT_MATH_REG.test(inner);
            if (closeOk && noNewline && noDollar && bounded && featured && inner.length > 0) {
              flushPlain();
              const latexSpan: MdSpan = new MdSpan(inner);
              latexSpan.latexSource = inner;
              spans.push(latexSpan);
              i = closeIdx + 1;
              continue;
            }
          }
        }
        // 未配对/不满足公式条件：按普通文本（如货币 $100）
        plain += ch;
        i++;
        continue;
      }
      if (ch === '*' && text.charAt(i + 1) === '*') {
        const close: number = text.indexOf('**', i + 2);
        if (close > i + 1) {
          flushPlain();
          const boldSpan: MdSpan = new MdSpan(text.substring(i + 2, close));
          boldSpan.bold = true;
          spans.push(boldSpan);
          i = close + 2;
          continue;
        }
      }
      if (ch === '~' && text.charAt(i + 1) === '~') {
        const close: number = text.indexOf('~~', i + 2);
        if (close > i + 1) {
          flushPlain();
          const strikeSpan: MdSpan = new MdSpan(text.substring(i + 2, close));
          strikeSpan.strike = true;
          spans.push(strikeSpan);
          i = close + 2;
          continue;
        }
      }
      if (ch === '`') {
        const close: number = text.indexOf('`', i + 1);
        if (close > i) {
          flushPlain();
          const codeSpan: MdSpan = new MdSpan(text.substring(i + 1, close));
          codeSpan.code = true;
          spans.push(codeSpan);
          i = close + 1;
          continue;
        }
      }
      // 行内图片 ![alt](url)
      if (ch === '!' && text.charAt(i + 1) === '[') {
        const closeBracket: number = text.indexOf('](', i + 1);
        if (closeBracket > i + 1) {
          const closeParen: number = text.indexOf(')', closeBracket);
          if (closeParen > closeBracket) {
            flushPlain();
            const imgSpan: MdSpan = new MdSpan(text.substring(i + 2, closeBracket));
            imgSpan.imageUrl = text.substring(closeBracket + 2, closeParen);
            spans.push(imgSpan);
            i = closeParen + 1;
            continue;
          }
        }
      }
      if (ch === '[') {
        // 引用角标 [reference:N] / [citation:N]（联网搜索引用，显示 N+1）
        const refMatch: RegExpMatchArray | null = text.substring(i).match(/^\[(?:reference|citation):(\d+)\]/i);
        if (refMatch !== null && refMatch.length >= 2) {
          flushPlain();
          const rawN: number = Number(refMatch[1]) || 0;
          const refSpan: MdSpan = new MdSpan(String(rawN + 1));
          refSpan.refIndex = rawN;
          spans.push(refSpan);
          i += refMatch[0].length;
          continue;
        }
        // 脚注引用 [^n]
        const footnoteMatch: RegExpMatchArray | null = text.substring(i).match(/^\[\^(\d+)\]/);
        if (footnoteMatch !== null && footnoteMatch.length >= 2) {
          flushPlain();
          const refId: number = Number(footnoteMatch[1]) || 0;
          const fnSpan: MdSpan = new MdSpan(footnoteMatch[1]);
          fnSpan.footnoteRef = refId;
          spans.push(fnSpan);
          i += footnoteMatch[0].length;
          continue;
        }
        // 链接 [text](url)
        const closeBracket: number = text.indexOf('](', i);
        if (closeBracket > i) {
          const closeParen: number = text.indexOf(')', closeBracket);
          if (closeParen > closeBracket) {
            flushPlain();
            const linkSpan: MdSpan = new MdSpan(text.substring(i + 1, closeBracket));
            linkSpan.linkUrl = text.substring(closeBracket + 2, closeParen);
            spans.push(linkSpan);
            i = closeParen + 1;
            continue;
          }
        }
      }
      if (ch === '*' && text.charAt(i + 1) !== '*') {
        const close: number = text.indexOf('*', i + 1);
        if (close > i) {
          flushPlain();
          const italicSpan: MdSpan = new MdSpan(text.substring(i + 1, close));
          italicSpan.italic = true;
          spans.push(italicSpan);
          i = close + 1;
          continue;
        }
      }
      plain += ch;
      i++;
    }
    flushPlain();
    return spans;
  }
}

/** 列表项匹配中间模型。 */
class ListItemMatch {
  indent: number = 0;
  isOrdered: boolean = false;
  taskState: number = 0;
  content: string = '';
}

export function parseMarkdown(src: string): MdBlock[] {
  const parser: MdParser = new MdParser();
  return parser.parse(src);
}

/** 行内解析独立入口：供表格单元格等场景将纯文本转为 MdSpan[]。 */
export function parseInlineSpans(text: string): MdSpan[] {
  const parser: MdParser = new MdParser();
  return parser.parseInline(text);
}
