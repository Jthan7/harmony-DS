import { util } from '@kit.ArkTS';

/**
 * SSE (text/event-stream) 增量解析器。
 * 按行拆分流式数据，返回每条 "data: ..." 事件的负载文本（不含 "data:" 前缀）。
 */
export class SseParser {
  private buffer: string = '';
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  push(chunk: ArrayBuffer): string[] {
    const bytes: Uint8Array = new Uint8Array(chunk);
    this.buffer += this.decoder.decodeToString(bytes, { stream: true });
    const events: string[] = [];
    let idx: number = this.buffer.indexOf('\n');
    while (idx >= 0) {
      const line: string = this.buffer.substring(0, idx);
      this.buffer = this.buffer.substring(idx + 1);
      this.consumeLine(line, events);
      idx = this.buffer.indexOf('\n');
    }
    return events;
  }

  /** 流结束时调用，处理残留在缓冲中的最后一行（无换行结尾）。 */
  flush(): string[] {
    const events: string[] = [];
    if (this.buffer.length > 0) {
      this.consumeLine(this.buffer, events);
      this.buffer = '';
    }
    return events;
  }

  private consumeLine(line: string, out: string[]): void {
    const trimmed: string = line.trim();
    if (trimmed.startsWith('data:')) {
      out.push(trimmed.substring(5).trim());
    }
  }
}
