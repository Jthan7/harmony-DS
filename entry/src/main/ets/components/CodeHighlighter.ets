/**
 * 自研轻量代码高亮 Tokenizer（规则表驱动，单遍扫描无回溯，零第三方依赖）。
 * 支持 10 种主流语言：js, ts, python, java, c, cpp, json, bash, sql, html, css。
 * 遵循 One Dark 配色风格（深底浅字）。
 * 模块级 LRU 缓存（上限 64），保障流式重解析 <10ms。
 */

export enum TokenKind {
  Keyword = 0,
  String = 1,
  Comment = 2,
  Number = 3,
  Plain = 4
}

export class HighlightToken {
  kind: TokenKind;
  text: string;

  constructor(kind: TokenKind, text: string) {
    this.kind = kind;
    this.text = text;
  }
}

class LangRule {
  keywords: Set<string> = new Set<string>();
  lineComments: string[] = [];
  blockCommentStart: string = '';
  blockCommentEnd: string = '';
  stringDelims: string[] = [];
  caseInsensitiveKeywords: boolean = false;
  htmlMode: boolean = false;
  cssMode: boolean = false;
  pythonStrings: boolean = false;
  bashVars: boolean = false;
}

function setOf(words: string[]): Set<string> {
  const s: Set<string> = new Set<string>();
  for (const w of words) {
    s.add(w);
  }
  return s;
}

const JS_TS_KEYWORDS: string[] = [
  'abstract', 'any', 'as', 'async', 'await', 'boolean', 'break', 'case', 'catch', 'class',
  'const', 'constructor', 'continue', 'debugger', 'declare', 'default', 'delete', 'do',
  'else', 'enum', 'export', 'extends', 'false', 'finally', 'for', 'from', 'function',
  'get', 'if', 'implements', 'import', 'in', 'instanceof', 'interface', 'is', 'keyof',
  'let', 'module', 'namespace', 'never', 'new', 'null', 'number', 'of', 'package',
  'private', 'protected', 'public', 'readonly', 'require', 'return', 'set', 'static',
  'string', 'super', 'switch', 'symbol', 'this', 'throw', 'true', 'try', 'type',
  'typeof', 'undefined', 'unique', 'unknown', 'var', 'void', 'while', 'with', 'yield'
];

const JAVA_KEYWORDS: string[] = [
  'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char', 'class',
  'const', 'continue', 'default', 'do', 'double', 'else', 'enum', 'extends', 'final',
  'finally', 'float', 'for', 'goto', 'if', 'implements', 'import', 'instanceof', 'int',
  'interface', 'long', 'native', 'new', 'null', 'package', 'private', 'protected', 'public',
  'record', 'return', 'short', 'static', 'strictfp', 'super', 'switch', 'synchronized',
  'this', 'throw', 'throws', 'transient', 'true', 'false', 'try', 'var', 'void', 'volatile', 'while'
];

const C_KEYWORDS: string[] = [
  'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do', 'double',
  'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline', 'int', 'long',
  'register', 'restrict', 'return', 'short', 'signed', 'sizeof', 'static', 'struct',
  'switch', 'typedef', 'union', 'unsigned', 'void', 'volatile', 'while', '_Bool',
  '_Complex', '_Imaginary'
];

const CPP_EXTRA: string[] = [
  'alignas', 'alignof', 'and', 'and_eq', 'asm', 'atomic_cancel', 'atomic_commit',
  'atomic_noexcept', 'bitand', 'bitor', 'bool', 'catch', 'char16_t', 'char32_t',
  'char8_t', 'class', 'co_await', 'co_return', 'co_yield', 'compl', 'concept',
  'consteval', 'constexpr', 'constinit', 'const_cast', 'decltype', 'delete', 'dynamic_cast',
  'explicit', 'export', 'false', 'friend', 'mutable', 'namespace', 'new', 'noexcept',
  'not', 'not_eq', 'nullptr', 'operator', 'or', 'or_eq', 'override', 'private',
  'protected', 'public', 'reflexpr', 'reinterpret_cast', 'requires', 'static_assert',
  'static_cast', 'template', 'this', 'thread_local', 'throw', 'true', 'try', 'typeid',
  'typename', 'using', 'virtual', 'wchar_t', 'xor', 'xor_eq'
];

const PYTHON_KEYWORDS: string[] = [
  'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', 'del',
  'elif', 'else', 'except', 'False', 'finally', 'for', 'from', 'global', 'if', 'import',
  'in', 'is', 'lambda', 'None', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return',
  'True', 'try', 'while', 'with', 'yield',
  // 高频内置名
  'self', 'print', 'len', 'range', 'int', 'str', 'float', 'bool', 'list', 'dict', 'set',
  'tuple', 'type', 'isinstance', 'enumerate', 'zip', 'map', 'filter', 'sorted', 'sum'
];

const BASH_KEYWORDS: string[] = [
  'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'while', 'until', 'do',
  'done', 'in', 'function', 'select', 'time', 'return', 'exit', 'export', 'local',
  'readonly', 'declare', 'set', 'unset', 'shift', 'source', 'alias', 'echo', 'cd',
  'pwd', 'ls', 'mkdir', 'rm', 'cp', 'mv', 'cat', 'grep', 'sed', 'awk'
];

const SQL_KEYWORDS: string[] = [
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET', 'DELETE',
  'CREATE', 'TABLE', 'DROP', 'ALTER', 'ADD', 'COLUMN', 'JOIN', 'INNER', 'LEFT', 'RIGHT',
  'FULL', 'OUTER', 'CROSS', 'ON', 'GROUP', 'BY', 'ORDER', 'HAVING', 'LIMIT', 'OFFSET',
  'AS', 'AND', 'OR', 'NOT', 'NULL', 'IS', 'IN', 'BETWEEN', 'LIKE', 'EXISTS', 'DISTINCT',
  'COUNT', 'SUM', 'AVG', 'MIN', 'MAX', 'UNION', 'ALL', 'PRIMARY', 'KEY', 'FOREIGN',
  'REFERENCES', 'DEFAULT', 'CHECK', 'INDEX', 'VIEW', 'DESC', 'ASC', 'CASE', 'WHEN',
  'THEN', 'ELSE', 'END', 'CAST', 'COALESCE'
];

const JSON_KEYWORDS: string[] = ['true', 'false', 'null'];

function buildRules(): Map<string, LangRule> {
  const m: Map<string, LangRule> = new Map<string, LangRule>();

  // JavaScript / TypeScript
  const jsRule: LangRule = new LangRule();
  jsRule.keywords = setOf(JS_TS_KEYWORDS);
  jsRule.lineComments = ['//'];
  jsRule.blockCommentStart = '/*';
  jsRule.blockCommentEnd = '*/';
  jsRule.stringDelims = ['"', "'", '`'];
  m.set('js', jsRule);
  m.set('javascript', jsRule);
  m.set('ts', jsRule);
  m.set('typescript', jsRule);
  m.set('jsx', jsRule);
  m.set('tsx', jsRule);

  // Java
  const javaRule: LangRule = new LangRule();
  javaRule.keywords = setOf(JAVA_KEYWORDS);
  javaRule.lineComments = ['//'];
  javaRule.blockCommentStart = '/*';
  javaRule.blockCommentEnd = '*/';
  javaRule.stringDelims = ['"', "'"];
  m.set('java', javaRule);

  // C
  const cRule: LangRule = new LangRule();
  cRule.keywords = setOf(C_KEYWORDS);
  cRule.lineComments = ['//'];
  cRule.blockCommentStart = '/*';
  cRule.blockCommentEnd = '*/';
  cRule.stringDelims = ['"', "'"];
  m.set('c', cRule);

  // C++
  const cppRule: LangRule = new LangRule();
  const cppWords: string[] = C_KEYWORDS.concat(CPP_EXTRA);
  cppRule.keywords = setOf(cppWords);
  cppRule.lineComments = ['//'];
  cppRule.blockCommentStart = '/*';
  cppRule.blockCommentEnd = '*/';
  cppRule.stringDelims = ['"', "'"];
  m.set('cpp', cppRule);
  m.set('c++', cppRule);
  m.set('cxx', cppRule);

  // Python
  const pyRule: LangRule = new LangRule();
  pyRule.keywords = setOf(PYTHON_KEYWORDS);
  pyRule.lineComments = ['#'];
  pyRule.stringDelims = ['"', "'"];
  pyRule.pythonStrings = true;
  m.set('py', pyRule);
  m.set('python', pyRule);
  m.set('python3', pyRule);

  // Bash / Shell
  const bashRule: LangRule = new LangRule();
  bashRule.keywords = setOf(BASH_KEYWORDS);
  bashRule.lineComments = ['#'];
  bashRule.stringDelims = ['"', "'"];
  bashRule.bashVars = true;
  m.set('bash', bashRule);
  m.set('sh', bashRule);
  m.set('shell', bashRule);
  m.set('zsh', bashRule);

  // SQL
  const sqlRule: LangRule = new LangRule();
  sqlRule.keywords = setOf(SQL_KEYWORDS);
  sqlRule.lineComments = ['--'];
  sqlRule.blockCommentStart = '/*';
  sqlRule.blockCommentEnd = '*/';
  sqlRule.stringDelims = ["'", '"'];
  sqlRule.caseInsensitiveKeywords = true;
  m.set('sql', sqlRule);

  // JSON
  const jsonRule: LangRule = new LangRule();
  jsonRule.keywords = setOf(JSON_KEYWORDS);
  jsonRule.stringDelims = ['"'];
  m.set('json', jsonRule);

  // HTML
  const htmlRule: LangRule = new LangRule();
  htmlRule.stringDelims = ['"', "'"];
  htmlRule.htmlMode = true;
  m.set('html', htmlRule);
  m.set('htm', htmlRule);
  m.set('xml', htmlRule);

  // CSS
  const cssRule: LangRule = new LangRule();
  cssRule.blockCommentStart = '/*';
  cssRule.blockCommentEnd = '*/';
  cssRule.stringDelims = ['"', "'"];
  cssRule.cssMode = true;
  m.set('css', cssRule);
  m.set('scss', cssRule);
  m.set('less', cssRule);

  return m;
}

const RULES: Map<string, LangRule> = buildRules();

function isIdentStart(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch === '_' || ch === '$';
}

function isIdentChar(ch: string): boolean {
  return isIdentStart(ch) || (ch >= '0' && ch <= '9');
}

function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

class Tokenizer {
  private src: string;
  private rule: LangRule;
  private pos: number = 0;
  private plainStart: number = -1;
  private out: HighlightToken[] = [];
  private lastSigChar: string = '';

  constructor(src: string, rule: LangRule) {
    this.src = src;
    this.rule = rule;
  }

  run(): HighlightToken[] {
    const len: number = this.src.length;
    while (this.pos < len) {
      if (this.tryHtmlComment()) {
        continue;
      }
      if (this.tryBlockComment()) {
        continue;
      }
      if (this.tryLineComment()) {
        continue;
      }
      if (this.tryString()) {
        continue;
      }
      if (this.tryBashVar()) {
        continue;
      }
      if (this.tryNumber()) {
        continue;
      }
      if (this.tryIdentifier()) {
        continue;
      }

      // 普通字符：记录进 Plain 缓存
      const ch: string = this.src.charAt(this.pos);
      if (this.plainStart < 0) {
        this.plainStart = this.pos;
      }
      if (ch !== ' ' && ch !== '\t' && ch !== '\n' && ch !== '\r') {
        this.lastSigChar = ch;
      }
      this.pos++;
    }
    this.flushPlain(len);
    return this.mergeAdjacent(this.out);
  }

  private flushPlain(upTo: number): void {
    if (this.plainStart >= 0 && upTo > this.plainStart) {
      this.out.push(new HighlightToken(TokenKind.Plain, this.src.substring(this.plainStart, upTo)));
      this.plainStart = -1;
    }
  }

  private emit(kind: TokenKind, start: number, end: number): void {
    this.flushPlain(start);
    this.out.push(new HighlightToken(kind, this.src.substring(start, end)));
    this.pos = end;
    // 更新最后可见符号（非空白）
    for (let k: number = end - 1; k >= start; k--) {
      const c: string = this.src.charAt(k);
      if (c !== ' ' && c !== '\t' && c !== '\n' && c !== '\r') {
        this.lastSigChar = c;
        break;
      }
    }
  }

  private tryHtmlComment(): boolean {
    if (!this.rule.htmlMode) {
      return false;
    }
    if (this.src.startsWith('<!--', this.pos)) {
      const start: number = this.pos;
      const endIdx: number = this.src.indexOf('-->', this.pos + 4);
      const end: number = endIdx >= 0 ? endIdx + 3 : this.src.length;
      this.emit(TokenKind.Comment, start, end);
      return true;
    }
    return false;
  }

  private tryBlockComment(): boolean {
    const startMarker: string = this.rule.blockCommentStart;
    if (startMarker.length === 0) {
      return false;
    }
    if (this.src.startsWith(startMarker, this.pos)) {
      const start: number = this.pos;
      const endMarker: string = this.rule.blockCommentEnd;
      const endIdx: number = this.src.indexOf(endMarker, this.pos + startMarker.length);
      const end: number = endIdx >= 0 ? endIdx + endMarker.length : this.src.length;
      this.emit(TokenKind.Comment, start, end);
      return true;
    }
    return false;
  }

  private tryLineComment(): boolean {
    for (const marker of this.rule.lineComments) {
      if (this.src.startsWith(marker, this.pos)) {
        const start: number = this.pos;
        let end: number = this.src.indexOf('\n', this.pos + marker.length);
        if (end < 0) {
          end = this.src.length;
        }
        this.emit(TokenKind.Comment, start, end);
        return true;
      }
    }
    return false;
  }

  private tryString(): boolean {
    // Python 三引号处理
    if (this.rule.pythonStrings) {
      if (this.src.startsWith('"""', this.pos) || this.src.startsWith("'''", this.pos)) {
        const delim3: string = this.src.substring(this.pos, this.pos + 3);
        const start: number = this.pos;
        const endIdx: number = this.src.indexOf(delim3, this.pos + 3);
        const end: number = endIdx >= 0 ? endIdx + 3 : this.src.length;
        this.emit(TokenKind.String, start, end);
        return true;
      }
    }

    const ch: string = this.src.charAt(this.pos);
    for (const delim of this.rule.stringDelims) {
      if (ch === delim) {
        const start: number = this.pos;
        let p: number = this.pos + 1;
        while (p < this.src.length) {
          const c: string = this.src.charAt(p);
          if (c === '\\') {
            p += 2; // 跳过转义字符
            continue;
          }
          if (c === delim) {
            p++;
            break;
          }
          if (c === '\n' && delim !== '`') {
            // 普通字符串不支持跨行，断开
            break;
          }
          p++;
        }
        this.emit(TokenKind.String, start, p);
        return true;
      }
    }
    return false;
  }

  private tryBashVar(): boolean {
    if (!this.rule.bashVars) {
      return false;
    }
    if (this.src.charAt(this.pos) === '$') {
      const next: string = this.pos + 1 < this.src.length ? this.src.charAt(this.pos + 1) : '';
      if (next === '{') {
        const closeIdx: number = this.src.indexOf('}', this.pos + 2);
        const end: number = closeIdx >= 0 ? closeIdx + 1 : this.src.length;
        this.emit(TokenKind.Keyword, this.pos, end);
        return true;
      }
      if (isIdentStart(next) || next === '?' || next === '#' || next === '!' || isDigit(next)) {
        let p: number = this.pos + 2;
        while (p < this.src.length && isIdentChar(this.src.charAt(p))) {
          p++;
        }
        this.emit(TokenKind.Keyword, this.pos, p);
        return true;
      }
    }
    return false;
  }

  private tryNumber(): boolean {
    const ch: string = this.src.charAt(this.pos);
    const next: string = this.pos + 1 < this.src.length ? this.src.charAt(this.pos + 1) : '';
    const isNumStart: boolean = isDigit(ch) || (ch === '.' && isDigit(next));
    if (!isNumStart) {
      return false;
    }
    // 前驱字符不能是标识符（例如 foo.12 不作为数字起始）
    if (this.pos > 0 && isIdentChar(this.src.charAt(this.pos - 1))) {
      return false;
    }
    const start: number = this.pos;
    let p: number = this.pos + 1;
    // 消费 16 进制 0x/0b/0o 前缀
    if (ch === '0' && (next === 'x' || next === 'X' || next === 'b' || next === 'B' || next === 'o' || next === 'O')) {
      p = this.pos + 2;
      while (p < this.src.length && /[0-9a-fA-F_]/.test(this.src.charAt(p))) {
        p++;
      }
      this.emit(TokenKind.Number, start, p);
      return true;
    }
    while (p < this.src.length) {
      const c: string = this.src.charAt(p);
      if (isDigit(c) || c === '.' || c === '_') {
        p++;
      } else if (c === 'e' || c === 'E') {
        p++;
        if (p < this.src.length && (this.src.charAt(p) === '+' || this.src.charAt(p) === '-')) {
          p++;
        }
      } else if (this.rule.cssMode && (c >= 'a' && c <= 'z' || c === '%')) {
        // CSS 单位（px, em, rem, vh, %, deg 等）合并为数字 token
        p++;
      } else if ((c === 'f' || c === 'F' || c === 'l' || c === 'L' || c === 'u' || c === 'U') && !this.rule.cssMode) {
        // C/Java 数值后缀
        p++;
        break;
      } else {
        break;
      }
    }
    this.emit(TokenKind.Number, start, p);
    return true;
  }

  private tryIdentifier(): boolean {
    const ch: string = this.src.charAt(this.pos);
    // CSS 选择器前缀类名 .class、#id
    if (this.rule.cssMode && (ch === '.' || ch === '#' || ch === '@')) {
      const next: string = this.pos + 1 < this.src.length ? this.src.charAt(this.pos + 1) : '';
      if (isIdentStart(next)) {
        const start: number = this.pos;
        let p: number = this.pos + 1;
        while (p < this.src.length && (isIdentChar(this.src.charAt(p)) || this.src.charAt(p) === '-')) {
          p++;
        }
        this.emit(TokenKind.Keyword, start, p);
        return true;
      }
    }

    if (!isIdentStart(ch)) {
      return false;
    }
    const start: number = this.pos;
    let p: number = this.pos + 1;
    while (p < this.src.length && isIdentChar(this.src.charAt(p))) {
      p++;
    }
    const word: string = this.src.substring(start, p);

    // Python f/r/b 字符串前缀（f"..."）
    if (this.rule.pythonStrings && (word === 'f' || word === 'r' || word === 'b' || word === 'u' ||
      word === 'fr' || word === 'rf')) {
      if (p < this.src.length && (this.src.charAt(p) === '"' || this.src.charAt(p) === "'")) {
        // 交由后续字符串分支处理（将前缀作为 Plain 或一同消费）
        this.emit(TokenKind.Keyword, start, p);
        return true;
      }
    }

    // HTML 标签名判定：紧跟在 < 或 </ 之后的标识符作为关键字
    if (this.rule.htmlMode) {
      if (this.lastSigChar === '<' || this.lastSigChar === '/') {
        this.emit(TokenKind.Keyword, start, p);
        return true;
      }
    }

    // CSS 属性名或伪类判定：单词后紧跟 ':' 或 '{' 作为关键字
    if (this.rule.cssMode) {
      let look: number = p;
      while (look < this.src.length && (this.src.charAt(look) === ' ' || this.src.charAt(look) === '\t')) {
        look++;
      }
      if (look < this.src.length && (this.src.charAt(look) === ':' || this.src.charAt(look) === '{' ||
        this.src.charAt(look) === ',')) {
        this.emit(TokenKind.Keyword, start, p);
        return true;
      }
    }

    // 关键字匹配
    const keyMatch: boolean = this.rule.caseInsensitiveKeywords
      ? this.rule.keywords.has(word.toUpperCase())
      : this.rule.keywords.has(word);
    if (keyMatch) {
      this.emit(TokenKind.Keyword, start, p);
      return true;
    }

    // 普通标识符
    this.emit(TokenKind.Plain, start, p);
    return true;
  }

  /** 合并相邻且相同 kind 的 Token（大幅压缩 Span 个数，优化渲染性能）。 */
  private mergeAdjacent(tokens: HighlightToken[]): HighlightToken[] {
    if (tokens.length <= 1) {
      return tokens;
    }
    const merged: HighlightToken[] = [];
    let cur: HighlightToken = tokens[0];
    for (let i: number = 1; i < tokens.length; i++) {
      const next: HighlightToken = tokens[i];
      if (next.kind === cur.kind) {
        cur.text += next.text;
      } else {
        merged.push(cur);
        cur = next;
      }
    }
    merged.push(cur);
    return merged;
  }
}

const HIGHLIGHT_CACHE_LIMIT: number = 64;
const highlightCache: Map<string, HighlightToken[]> = new Map<string, HighlightToken[]>();

function normalizeLang(rawLang: string): string {
  const trimmed: string = rawLang.trim().toLowerCase();
  if (trimmed.startsWith('language-')) {
    return trimmed.substring(9);
  }
  return trimmed;
}

/**
 * 语法高亮入口函数（LRU 缓存上限 64）。
 * 若为未知语言，返回空数组，由调用方降级为单 Span 无色渲染。
 */
export function highlight(code: string, lang: string): HighlightToken[] {
  const norm: string = normalizeLang(lang);
  const rule: LangRule | undefined = RULES.get(norm);
  if (rule === undefined || code.length === 0) {
    return [];
  }
  const cacheKey: string = `${norm}\u0000${code.length}\u0000${code}`;
  const cached: HighlightToken[] | undefined = highlightCache.get(cacheKey);
  if (cached !== undefined) {
    highlightCache.delete(cacheKey);
    highlightCache.set(cacheKey, cached);
    return cached;
  }
  const tokenizer: Tokenizer = new Tokenizer(code, rule);
  const result: HighlightToken[] = tokenizer.run();

  if (highlightCache.size >= HIGHLIGHT_CACHE_LIMIT) {
    let oldestKey: string = '';
    highlightCache.forEach((_v: HighlightToken[], k: string) => {
      if (oldestKey.length === 0) {
        oldestKey = k;
      }
    });
    if (oldestKey.length > 0) {
      highlightCache.delete(oldestKey);
    }
  }
  highlightCache.set(cacheKey, result);
  return result;
}
