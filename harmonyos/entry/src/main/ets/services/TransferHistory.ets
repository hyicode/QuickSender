import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface TransferEvent {
  id: string;
  name: string;
  detail: string;
  time: string;
  createdAt: number;
}

export const HISTORY_LIMIT = 30;
const EVENT_FILE = /^\d+-[0-9a-f-]{36}\.json$/i;

// Keep one atomic file per transfer so the share extension and main app can write independently.
export class TransferHistory {
  private readonly directory: string;

  constructor(filesDir: string) { this.directory = filesDir ? `${filesDir}/transfer-history` : ''; }

  save(event: TransferEvent): boolean {
    if (!this.directory) return false;
    const path = this.path(event);
    const temp = `${path}.part`;
    try {
      try { fs.mkdirSync(this.directory, true); }
      catch (e) { if (!fs.statSync(this.directory).isDirectory()) throw e as Error; }
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const bytes = new util.TextEncoder().encodeInto(JSON.stringify(event));
        if (fs.writeSync(file.fd, bytes.buffer) !== bytes.length) throw new Error('传输记录写入不完整');
      } finally { fs.closeSync(file); }
      fs.renameSync(temp, path);
      this.files().slice(HISTORY_LIMIT).forEach(name => this.unlink(`${this.directory}/${name}`));
      return true;
    } catch (_) {
      this.unlink(temp);
      return false;
    }
  }

  list(): TransferEvent[] {
    const events: TransferEvent[] = [];
    this.files().slice(0, HISTORY_LIMIT).forEach(name => {
      try {
        const event = JSON.parse(fs.readTextSync(`${this.directory}/${name}`)) as TransferEvent;
        if (this.path(event) === `${this.directory}/${name}`) events.push(event);
      } catch (_) { /* The entry may have been deleted by another window. */ }
    });
    return events;
  }

  remove(event: TransferEvent): void { if (this.directory) this.unlink(this.path(event)); }

  private files(): string[] {
    if (!this.directory) return [];
    try { return fs.listFileSync(this.directory).filter(name => EVENT_FILE.test(name)).sort().reverse(); }
    catch (_) { return []; }
  }

  private path(event: TransferEvent): string { return `${this.directory}/${event.createdAt}-${event.id}.json`; }

  private unlink(path: string): void { try { fs.unlinkSync(path); } catch (_) { /* Already removed. */ } }
}
