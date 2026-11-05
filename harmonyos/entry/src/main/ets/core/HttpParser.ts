import { METADATA_LIMIT, ProtocolError } from './Protocol';

export interface RequestHead { method: string; path: string; query: Map<string, string>; length: number; expect: boolean; }
type BodyWriter = (chunk: Uint8Array) => void;

// One request per connection, with strict length framing. Chunked requests are deliberately rejected.
export class HttpParser {
  head: RequestHead | undefined = undefined;
  private header: number[] = [];
  private chunks: Uint8Array[] = [];
  private size: number = 0;
  private writer?: BodyWriter;
  private readonly openBody?: (head: RequestHead) => BodyWriter | undefined;
  complete: boolean = false;

  constructor(openBody?: (head: RequestHead) => BodyWriter | undefined) { this.openBody = openBody; }

  get bodyBytes(): number { return this.size; }

  push(chunk: Uint8Array): void {
    if (this.complete) throw new ProtocolError(400, '不支持流水线请求');
    let offset = 0;
    if (!this.head) {
      for (; offset < chunk.length; offset++) {
        this.header.push(chunk[offset]);
        const n = this.header.length;
        if (n > 16384) throw new ProtocolError(431, '请求头过大');
        if (n >= 4 && this.header[n - 4] === 13 && this.header[n - 3] === 10 && this.header[n - 2] === 13 && this.header[n - 1] === 10) {
          this.parseHead(); offset++; break;
        }
      }
    }
    if (this.head) {
      if (offset < chunk.length) {
        const part = chunk.subarray(offset);
        this.size += part.length;
        if (this.size > this.head.length) throw new ProtocolError(400, '内容长度不匹配');
        if (this.writer) this.writer(part);
        else this.chunks.push(part.slice());
      }
      this.complete = this.size === this.head.length;
    }
  }
  body(): Uint8Array {
    if (!this.complete) throw new ProtocolError(400, '请求未完成');
    if (this.writer) throw new ProtocolError(400, '文件已直接写入磁盘');
    const body = new Uint8Array(this.size);
    let offset = 0;
    this.chunks.forEach(c => { body.set(c, offset); offset += c.length; });
    return body;
  }
  private parseHead(): void {
    const text = this.header.map(c => String.fromCharCode(c)).join('');
    const lines = text.split('\r\n');
    const first = lines.shift()!.split(' ');
    if (first.length !== 3 || !/^HTTP\/1\.[01]$/.test(first[2]) || !first[1].startsWith('/')) throw new ProtocolError(400, '无效的 HTTP 请求');
    const headers: Map<string, string> = new Map();
    for (const line of lines) {
      if (!line) continue;
      const colon = line.indexOf(':');
      if (colon <= 0) throw new ProtocolError(400, '无效的请求头');
      const key = line.slice(0, colon).toLowerCase();
      if (headers.has(key)) throw new ProtocolError(400, '重复的请求头');
      headers.set(key, line.slice(colon + 1).trim());
    }
    if (headers.has('transfer-encoding')) throw new ProtocolError(501, '暂不支持 chunked 传输');
    const raw = headers.get('content-length') || '0';
    if (!/^\d+$/.test(raw)) throw new ProtocolError(400, '无效的内容长度');
    const length = Number(raw);
    if (!Number.isSafeInteger(length)) throw new ProtocolError(400, '无效的文件长度');
    const parts = first[1].split('?');
    const query: Map<string, string> = new Map();
    if (parts[1]) for (const pair of parts[1].split('&')) {
      const index = pair.indexOf('=');
      if (index < 0) continue;
      const key = decodeURIComponent(pair.slice(0, index));
      if (query.has(key)) throw new ProtocolError(400, '重复的参数');
      query.set(key, decodeURIComponent(pair.slice(index + 1)));
    }
    this.head = { method: first[0], path: parts[0], query, length, expect: headers.get('expect')?.toLowerCase() === '100-continue' };
    this.writer = this.openBody?.(this.head);
    if (!this.writer && length > METADATA_LIMIT) throw new ProtocolError(413, '元数据过大');
    this.header = [];
  }
}
