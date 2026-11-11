/**
 * LaTeX 源码解析器：LatexNode 树 + 行内线性化（RD-02 三级策略的解析层）。
 * - 块级公式：parseLatex → LatexNode 树，供 LatexRenderer 原生布局
 * - 行内公式：linearizeLatexInline → LatexRun[]（普通/上标/下标），供 MdInlineBuilder 拼接
 * - 未识别命令/结构（矩阵、aligned、\\ 多行、& 对齐）→ 整体降级（degraded=true）
 * - 模块级 LRU 缓存（上限 64），流式重解析命中缓存
 */

export enum LatexNodeKind {
  Atom = 0,
  Group = 1,
  Sup = 2,
  Sub = 3,
  Frac = 4,
  Sqrt = 5,
  Limits = 6,
  Styled = 7,
  Degraded = 8
}

export class LatexNode {
  kind: LatexNodeKind;
  text: string = '';
  styleBold: boolean = false;
  styleItalic: boolean = false;
  upright: boolean = false;
  children: LatexNode[] = [];
  base: LatexNode | null = null;
  script: LatexNode | null = null;
  num: LatexNode | null = null;
  den: LatexNode | null = null;
  index: LatexNode | null = null;
  body: LatexNode | null = null;
  op: string = '';
  lower: LatexNode | null = null;
  upper: LatexNode | null = null;

  constructor(kind: LatexNodeKind) {
    this.kind = kind;
  }
}

export class LatexResult {
  root: LatexNode | null = null;
  degraded: boolean = false;
  degradedSource: string = '';
}

/** 行内线性化片段：0=普通 1=上标 2=下标。 */
export class LatexRun {
  text: string;
  kind: number;

  constructor(text: string, kind: number) {
    this.text = text;
    this.kind = kind;
  }
}

function buildSymbolMap(): Map<string, string> {
  const m: Map<string, string> = new Map();
  // 希腊字母小写
  m.set('alpha', 'α').set('beta', 'β').set('gamma', 'γ').set('delta', 'δ')
    .set('epsilon', 'ε').set('varepsilon', 'ε').set('zeta', 'ζ').set('eta', 'η')
    .set('theta', 'θ').set('vartheta', 'ϑ').set('iota', 'ι').set('kappa', 'κ')
    .set('lambda', 'λ').set('mu', 'μ').set('nu', 'ν').set('xi', 'ξ')
    .set('pi', 'π').set('varpi', 'ϖ').set('rho', 'ρ').set('varrho', 'ϱ')
    .set('sigma', 'σ').set('varsigma', 'ς').set('tau', 'τ').set('upsilon', 'υ')
    .set('phi', 'φ').set('varphi', 'φ').set('chi', 'χ').set('psi', 'ψ').set('omega', 'ω');
  // 希腊字母大写
  m.set('Gamma', 'Γ').set('Delta', 'Δ').set('Theta', 'Θ').set('Lambda', 'Λ')
    .set('Xi', 'Ξ').set('Pi', 'Π').set('Sigma', 'Σ').set('Upsilon', 'Υ')
    .set('Phi', 'Φ').set('Psi', 'Ψ').set('Omega', 'Ω');
  // 二元运算符
  m.set('pm', '±').set('mp', '∓').set('times', '×').set('div', '÷')
    .set('cdot', '·').set('ast', '∗').set('star', '⋆').set('circ', '∘')
    .set('bullet', '•').set('oplus', '⊕').set('ominus', '⊖').set('otimes', '⊗')
    .set('oslash', '⊘').set('odot', '⊙');
  // 关系运算符
  m.set('leq', '≤').set('le', '≤').set('geq', '≥').set('ge', '≥')
    .set('neq', '≠').set('ne', '≠').set('equiv', '≡').set('approx', '≈')
    .set('sim', '∼').set('simeq', '≃').set('cong', '≅').set('propto', '∝')
    .set('ll', '≪').set('gg', '≫').set('asymp', '≈');
  // 集合与逻辑
  m.set('subset', '⊂').set('supset', '⊃').set('subseteq', '⊆').set('supseteq', '⊇')
    .set('in', '∈').set('notin', '∉').set('ni', '∋').set('mid', '∣')
    .set('parallel', '∥').set('perp', '⊥').set('angle', '∠').set('wedge', '∧')
    .set('vee', '∨').set('neg', '¬').set('lnot', '¬').set('therefore', '∴')
    .set('because', '∵').set('forall', '∀').set('exists', '∃')
    .set('emptyset', '∅').set('varnothing', '∅').set('square', '□');
  // 常用符号
  m.set('infty', '∞').set('partial', '∂').set('nabla', '∇').set('hbar', 'ℏ')
    .set('ell', 'ℓ').set('aleph', 'ℵ').set('wp', '℘').set('Re', 'ℜ').set('Im', 'ℑ')
    .set('prime', '′').set('degree', '°').set('circ', '∘');
  // 大运算符（Limits 节点）
  m.set('sum', '∑').set('prod', '∏').set('coprod', '∐')
    .set('int', '∫').set('iint', '∬').set('iiint', '∭').set('oint', '∮')
    .set('lim', 'lim');
  // 箭头
  m.set('leftarrow', '←').set('rightarrow', '→').set('to', '→')
    .set('leftrightarrow', '↔').set('Leftarrow', '⇐').set('Rightarrow', '⇒')
    .set('Leftrightarrow', '⇔').set('mapsto', '↦')
    .set('uparrow', '↑').set('downarrow', '↓').set('updownarrow', '↕');
  // 省略号
  m.set('cdots', '⋯').set('ldots', '…').set('dots', '…')
    .set('vdots', '⋮').set('ddots', '⋱');
  return m;
}

function buildAccentMap(): Map<string, string> {
  const m: Map<string, string> = new Map();
  m.set('hat', '\u0302').set('bar', '\u0304').set('vec', '\u20D7')
    .set('tilde', '\u0303').set('dot', '\u0307').set('ddot', '\u0308');
  return m;
}

const SYMBOL_MAP: Map<string, string> = buildSymbolMap();
const ACCENT_MAP: Map<string, string> = buildAccentMap();
const LIMITS_OPS: string[] = ['sum', 'prod', 'coprod', 'int', 'iint', 'iiint', 'oint', 'lim'];
const SKIP_COMMANDS: string[] = ['left', 'right', 'displaystyle', 'limits', 'nolimits',
  'big', 'Big', 'bigg', 'Bigg', 'bigl', 'bigr', 'Bigl', 'Bigr', 'bigm', 'Bigm'];
const TEXT_COMMANDS: string[] = ['text', 'textrm', 'mathrm', 'mathbf', 'textbf', 'mathit', 'mathcal', 'operatorname'];
const FUNCTION_NAMES: string[] = ['sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'arcsin', 'arccos', 'arctan',
  'sinh', 'cosh', 'tanh', 'log', 'ln', 'lg', 'exp', 'max', 'min', 'sup', 'inf', 'det', 'dim', 'arg', 'deg', 'gcd', 'lcm'];

class LatexParserImpl {
  private src: string = '';
  private pos: number = 0;
  private failed: boolean = false;

  constructor(src: string) {
    this.src = src;
  }

  parse(): LatexResult {
    const result: LatexResult = new LatexResult();
    if (this.src.trim().length === 0) {
      result.degraded = true;
      result.degradedSource = this.src;
      return result;
    }
    const root: LatexNode = new LatexNode(LatexNodeKind.Group);
    root.children = this.parseSequence(false);
    if (this.failed) {
      result.degraded = true;
      result.degradedSource = this.src;
      return result;
    }
    result.root = root;
    return result;
  }

  private fail(): void {
    this.failed = true;
  }

  private atom(text: string): LatexNode {
    const node: LatexNode = new LatexNode(LatexNodeKind.Atom);
    node.text = text;
    return node;
  }

  private parseSequence(stopAtBrace: boolean): LatexNode[] {
    const nodes: LatexNode[] = [];
    while (this.pos < this.src.length && !this.failed) {
      const ch: string = this.src.charAt(this.pos);
      if (ch === '}') {
        if (stopAtBrace) {
          this.pos++;
          break;
        }
        this.fail();
        break;
      }
      if (ch === '{') {
        this.pos++;
        const groupNode: LatexNode = new LatexNode(LatexNodeKind.Group);
        groupNode.children = this.parseSequence(true);
        nodes.push(groupNode);
        continue;
      }
      if (ch === '^' || ch === '_') {
        this.pos++;
        const script: LatexNode = this.parseToken();
        if (this.failed) {
          break;
        }
        const prev: LatexNode | undefined = nodes.pop();
        if (prev === undefined) {
          const bareNode: LatexNode = new LatexNode(ch === '^' ? LatexNodeKind.Sup : LatexNodeKind.Sub);
          bareNode.script = script;
          nodes.push(bareNode);
        } else if (prev.kind === LatexNodeKind.Limits) {
          if (ch === '_') {
            prev.lower = script;
          } else {
            prev.upper = script;
          }
          nodes.push(prev);
        } else {
          const scriptNode: LatexNode = new LatexNode(ch === '^' ? LatexNodeKind.Sup : LatexNodeKind.Sub);
          scriptNode.base = prev;
          scriptNode.script = script;
          nodes.push(scriptNode);
        }
        continue;
      }
      if (ch === '\\') {
        const cmdNode: LatexNode | null = this.parseCommand();
        if (this.failed) {
          break;
        }
        if (cmdNode !== null) {
          nodes.push(cmdNode);
        }
        continue;
      }
      if (ch === '&' || ch === '\n' || ch === '\r') {
        // 对齐/多行结构（矩阵、aligned）→ 整体降级
        this.fail();
        break;
      }
      if (ch === '~') {
        this.pos++;
        nodes.push(this.atom(' '));
        continue;
      }
      if (ch === "'") {
        this.pos++;
        nodes.push(this.atom('′'));
        continue;
      }
      // 连续普通字符合并为一个原子
      let runEnd: number = this.pos;
      while (runEnd < this.src.length) {
        const c: string = this.src.charAt(runEnd);
        if (c === '{' || c === '}' || c === '^' || c === '_' || c === '\\' || c === '&'
          || c === '~' || c === "'" || c === '\n' || c === '\r') {
          break;
        }
        runEnd++;
      }
      nodes.push(this.atom(this.src.substring(this.pos, runEnd)));
      this.pos = runEnd;
    }
    if (this.failed) {
      return [];
    }
    return nodes;
  }

  /** 解析 ^/_ 的单个参数：{组}、\命令 或 单字符。 */
  private parseToken(): LatexNode {
    if (this.pos >= this.src.length) {
      this.fail();
      return this.atom('');
    }
    const ch: string = this.src.charAt(this.pos);
    if (ch === '{') {
      this.pos++;
      const groupNode: LatexNode = new LatexNode(LatexNodeKind.Group);
      groupNode.children = this.parseSequence(true);
      return groupNode;
    }
    if (ch === '\\') {
      const cmd: LatexNode | null = this.parseCommand();
      return cmd !== null ? cmd : this.atom('');
    }
    this.pos++;
    return this.atom(ch);
  }

  private parseCommand(): LatexNode | null {
    this.pos++; // 跳过 '\'
    if (this.pos >= this.src.length) {
      this.fail();
      return null;
    }
    const ch: string = this.src.charAt(this.pos);
    const isLetter: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
    if (isLetter) {
      let end: number = this.pos;
      while (end < this.src.length) {
        const c: string = this.src.charAt(end);
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
          end++;
        } else {
          break;
        }
      }
      const name: string = this.src.substring(this.pos, end);
      this.pos = end;
      return this.dispatchNamedCommand(name);
    }
    // 非字母命令
    this.pos++;
    if (ch === '\\') {
      this.fail(); // \\ 换行 → 多行公式降级
      return null;
    }
    if (ch === '{') {
      return this.atom('{');
    }
    if (ch === '}') {
      return this.atom('}');
    }
    if (ch === '|') {
      return this.atom('‖');
    }
    if (ch === ',' || ch === ';' || ch === ' ') {
      return this.atom(' ');
    }
    if (ch === '!') {
      return null; // 负空格：跳过
    }
    this.fail();
    return null;
  }

  private dispatchNamedCommand(name: string): LatexNode | null {
    if (name === 'frac' || name === 'dfrac' || name === 'tfrac') {
      const numNode: LatexNode = this.parseToken();
      const denNode: LatexNode = this.parseToken();
      if (this.failed) {
        return null;
      }
      const fracNode: LatexNode = new LatexNode(LatexNodeKind.Frac);
      fracNode.num = numNode;
      fracNode.den = denNode;
      return fracNode;
    }
    if (name === 'sqrt') {
      let indexNode: LatexNode | null = null;
      if (this.pos < this.src.length && this.src.charAt(this.pos) === '[') {
        const closeIdx: number = this.src.indexOf(']', this.pos);
        if (closeIdx < 0) {
          this.fail();
          return null;
        }
        indexNode = this.atom(this.src.substring(this.pos + 1, closeIdx));
        this.pos = closeIdx + 1;
      }
      const bodyNode: LatexNode = this.parseToken();
      if (this.failed) {
        return null;
      }
      const sqrtNode: LatexNode = new LatexNode(LatexNodeKind.Sqrt);
      sqrtNode.index = indexNode;
      sqrtNode.body = bodyNode;
      return sqrtNode;
    }
    if (TEXT_COMMANDS.indexOf(name) >= 0) {
      const raw: string = this.readGroupRaw();
      if (this.failed) {
        return null;
      }
      const styledNode: LatexNode = new LatexNode(LatexNodeKind.Styled);
      styledNode.text = raw;
      styledNode.styleBold = name === 'mathbf' || name === 'textbf';
      styledNode.styleItalic = name === 'mathit' || name === 'mathcal';
      return styledNode;
    }
    if (LIMITS_OPS.indexOf(name) >= 0) {
      const limitsNode: LatexNode = new LatexNode(LatexNodeKind.Limits);
      const sym: string | undefined = SYMBOL_MAP.get(name);
      limitsNode.op = sym !== undefined ? sym : name;
      return limitsNode;
    }
    if (SKIP_COMMANDS.indexOf(name) >= 0) {
      return null;
    }
    if (name === 'begin' || name === 'end') {
      // 矩阵/aligned/cases 等环境 → 整体降级
      this.fail();
      return null;
    }
    if (name === 'quad' || name === 'qquad') {
      return this.atom(name === 'qquad' ? '  ' : ' ');
    }
    if (name === 'hat' || name === 'bar' || name === 'vec' || name === 'tilde' || name === 'dot' || name === 'ddot') {
      const accent: string | undefined = ACCENT_MAP.get(name);
      const baseNode: LatexNode = this.parseToken();
      if (this.failed) {
        return null;
      }
      return this.attachAccent(baseNode, accent !== undefined ? accent : '\u0302');
    }
    const symbol: string | undefined = SYMBOL_MAP.get(name);
    if (symbol !== undefined) {
      return this.atom(symbol);
    }
    if (FUNCTION_NAMES.indexOf(name) >= 0) {
      const fnNode: LatexNode = this.atom(name);
      fnNode.upright = true;
      return fnNode;
    }
    // 未识别命令（自定义宏等）→ 整体降级
    this.fail();
    return null;
  }

  /** 读取 \text{...} 组内容原文（允许嵌套花括号）。 */
  private readGroupRaw(): string {
    if (this.pos >= this.src.length || this.src.charAt(this.pos) !== '{') {
      if (this.pos < this.src.length) {
        const c: string = this.src.charAt(this.pos);
        this.pos++;
        return c;
      }
      this.fail();
      return '';
    }
    let depth: number = 0;
    let end: number = -1;
    for (let i: number = this.pos; i < this.src.length; i++) {
      const c: string = this.src.charAt(i);
      if (c === '{') {
        depth++;
      } else if (c === '}') {
        depth--;
        if (depth === 0) {
          end = i;
          break;
        }
      }
    }
    if (end < 0) {
      this.fail();
      return '';
    }
    const raw: string = this.src.substring(this.pos + 1, end);
    this.pos = end + 1;
    return raw;
  }

  /** 重音符号：合并到基字符文本（组合字符）。 */
  private attachAccent(base: LatexNode, accent: string): LatexNode {
    const flattened: string = this.flattenNodeText(base);
    if (flattened.length > 0 && flattened.length <= 4) {
      return this.atom(flattened + accent);
    }
    return base;
  }

  private flattenNodeText(node: LatexNode): string {
    if (node.kind === LatexNodeKind.Atom || node.kind === LatexNodeKind.Styled) {
      return node.text;
    }
    if (node.kind === LatexNodeKind.Group) {
      let s: string = '';
      for (const child of node.children) {
        s += this.flattenNodeText(child);
      }
      return s;
    }
    if (node.kind === LatexNodeKind.Sup || node.kind === LatexNodeKind.Sub) {
      let s: string = node.base !== null ? this.flattenNodeText(node.base) : '';
      s += node.script !== null ? this.flattenNodeText(node.script) : '';
      return s;
    }
    return '';
  }
}

const PARSE_CACHE_LIMIT: number = 64;
const parseCache: Map<string, LatexResult> = new Map();

/** LaTeX 解析入口（LRU 缓存上限 64）。 */
export function parseLatex(src: string): LatexResult {
  const cached: LatexResult | undefined = parseCache.get(src);
  if (cached !== undefined) {
    parseCache.delete(src);
    parseCache.set(src, cached);
    return cached;
  }
  const impl: LatexParserImpl = new LatexParserImpl(src);
  const result: LatexResult = impl.parse();
  if (parseCache.size >= PARSE_CACHE_LIMIT) {
    let oldestKey: string = '';
    parseCache.forEach((_v: LatexResult, k: string) => {
      if (oldestKey.length === 0) {
        oldestKey = k;
      }
    });
    if (oldestKey.length > 0) {
      parseCache.delete(oldestKey);
    }
  }
  parseCache.set(src, result);
  return result;
}

/**
 * 行内公式线性化：LatexNode 树 → LatexRun[]。
 * 分数降为 a⁄b 线性形式，上下标以 kind 标记，符号已映射 Unicode。
 * 降级时返回空数组，由调用方按等宽原文渲染。
 */
export function linearizeLatexInline(src: string): LatexRun[] {
  const result: LatexResult = parseLatex(src);
  if (result.degraded || result.root === null) {
    return [];
  }
  const runs: LatexRun[] = [];
  linearizeNode(result.root, 0, runs);
  return runs;
}

function pushRun(runs: LatexRun[], text: string, kind: number): void {
  if (text.length === 0) {
    return;
  }
  if (runs.length > 0) {
    const last: LatexRun = runs[runs.length - 1];
    if (last.kind === kind) {
      last.text += text;
      return;
    }
  }
  runs.push(new LatexRun(text, kind));
}

function linearizeNode(node: LatexNode | null, kind: number, runs: LatexRun[]): void {
  if (node === null) {
    return;
  }
  if (node.kind === LatexNodeKind.Atom) {
    pushRun(runs, node.text, kind);
    return;
  }
  if (node.kind === LatexNodeKind.Group) {
    for (const child of node.children) {
      linearizeNode(child, kind, runs);
    }
    return;
  }
  if (node.kind === LatexNodeKind.Sup) {
    linearizeNode(node.base, kind, runs);
    linearizeNode(node.script, 1, runs);
    return;
  }
  if (node.kind === LatexNodeKind.Sub) {
    linearizeNode(node.base, kind, runs);
    linearizeNode(node.script, 2, runs);
    return;
  }
  if (node.kind === LatexNodeKind.Frac) {
    // 分数线性化：a⁄b（U+2044 分数斜线）
    linearizeNode(node.num, kind, runs);
    pushRun(runs, '⁄', kind);
    linearizeNode(node.den, kind, runs);
    return;
  }
  if (node.kind === LatexNodeKind.Sqrt) {
    pushRun(runs, '√(', kind);
    linearizeNode(node.body, kind, runs);
    pushRun(runs, ')', kind);
    return;
  }
  if (node.kind === LatexNodeKind.Limits) {
    pushRun(runs, node.op, kind);
    linearizeNode(node.lower, 2, runs);
    linearizeNode(node.upper, 1, runs);
    return;
  }
  if (node.kind === LatexNodeKind.Styled) {
    pushRun(runs, node.text, kind);
    return;
  }
  if (node.kind === LatexNodeKind.Degraded) {
    pushRun(runs, node.text, kind);
    return;
  }
}
