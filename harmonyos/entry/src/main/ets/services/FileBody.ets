import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { FileMeta, ProtocolError } from '../core/Protocol';

const BUFFER_SIZE = 256 * 1024;

export async function streamFile(uri: string, size: number, sendHeader: () => Promise<void>,
  sendChunk: (chunk: ArrayBuffer) => Promise<void>): Promise<void> {
  const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
  try {
    if ((await fs.stat(file.fd)).size !== size) throw new ProtocolError(410, '文件大小已改变，请重新选择');
    await sendHeader();
    const buffer = new ArrayBuffer(BUFFER_SIZE);
    let remaining = size;
    while (remaining > 0) {
      const count = await fs.read(file.fd, buffer, { length: Math.min(remaining, buffer.byteLength) });
      if (count <= 0) throw new Error('文件读取不完整');
      await sendChunk(count === buffer.byteLength ? buffer : buffer.slice(0, count));
      remaining -= count;
    }
  } finally { await fs.close(file); }
}

export class IncomingFile {
  private file?: fs.File;
  private digest?: cryptoFramework.Md;
  private temp: string;
  private readonly path: string;
  private readonly meta: FileMeta;

  constructor(path: string, meta: FileMeta) {
    this.path = path;
    this.meta = meta;
    this.temp = `${path}.part`;
    if (meta.sha256) this.digest = cryptoFramework.createMd('SHA256');
    this.file = fs.openSync(this.temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
  }

  write(chunk: Uint8Array): void {
    const file = this.file;
    if (!file) throw new ProtocolError(403, '接收已停止');
    this.digest?.updateSync({ data: chunk });
    for (let offset = 0; offset < chunk.length;) {
      const count = fs.writeSync(file.fd, chunk.slice(offset).buffer);
      if (count <= 0) throw new Error('写入失败');
      offset += count;
    }
  }

  commit(): void {
    const digest = this.digest?.digestSync();
    if (digest) {
      const hex = Array.from(digest.data).map(byte => byte.toString(16).padStart(2, '0')).join('');
      if (hex !== this.meta.sha256?.toLowerCase()) throw new ProtocolError(422, '文件校验失败');
    }
    this.close();
    fs.renameSync(this.temp, this.path);
  }

  discard(): void {
    try { this.close(); } catch (_) { /* Continue removing the partial file. */ }
    try { fs.unlinkSync(this.temp); } catch (_) { /* Already removed or committed. */ }
  }

  private close(): void {
    if (!this.file) return;
    const file = this.file;
    this.file = undefined;
    fs.closeSync(file);
  }
}
