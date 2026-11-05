import { common, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Peer } from '../core/Protocol';
import { LocalFile, ShareLink, TransferService } from './TransferService';
import { Runtime } from './Runtime';

export class ShareSession {
  private static nextId: number = 0;
  private static activeSessions: Map<number, ShareSession> = new Map();

  static register(model: ShareSession): number {
    const id = ++ShareSession.nextId;
    ShareSession.activeSessions.set(id, model);
    return id;
  }

  static get(id: number): ShareSession | undefined { return ShareSession.activeSessions.get(id); }

  static async release(id: number): Promise<void> {
    const model = ShareSession.activeSessions.get(id);
    ShareSession.activeSessions.delete(id);
    await model?.dispose();
  }

  files: LocalFile[] = [];
  service?: TransferService;
  sending: boolean = false;
  private sendId: string = '';
  link?: ShareLink;
  private creatingLink?: Promise<ShareLink>;
  private context: common.Context;
  private want: Want;
  private session: UIExtensionContentSession;
  private owned: boolean = false;
  private closed: boolean = false;
  private startup?: Promise<void>;

  constructor(context: common.Context, want: Want, session: UIExtensionContentSession) {
    this.context = context;
    this.want = want;
    this.session = session;
  }

  start(): Promise<void> {
    if (!this.startup) this.startup = this.load();
    return this.startup;
  }

  private async load(): Promise<void> {
    let stage = '读取分享内容';
    try {
      const data = await systemShare.getSharedData(this.want);
      if (this.closed) return;
      const uris: string[] = [];
      for (const record of data.getRecords()) {
        if (record.uri && !uris.includes(record.uri)) uris.push(record.uri);
      }
      if (!uris.length) throw new Error('没有可发送的照片、视频或文件');

      stage = '打开所选文件';
      const active = Runtime.active();
      const service = active ?? new TransferService(this.context, true);
      this.service = service;
      this.owned = !active;
      this.files = await service.prepareFiles(uris);
      if (this.closed) return;
      if (this.owned) {
        stage = '读取设备设置';
        await service.initialize();
        if (this.closed) return;
        stage = '启动设备搜索';
        await service.start();
      }
      if (!this.closed) service.refresh().catch(() => {});
    } catch (e) {
      hilog.error(0x0000, 'QuickSenderShare', '%{public}s失败', stage);
      throw new Error(`${stage}失败：${(e as Error).message}`);
    }
  }

  async send(peer: Peer): Promise<void> {
    const service = this.service;
    if (!service || this.closed || this.sending) return;
    this.sending = true;
    try { await service.send(peer, this.files, true, id => { this.sendId = id; }); }
    finally { this.sendId = ''; this.sending = false; }
  }

  sendProgress(): number { return this.service?.sendProgress(this.sendId) ?? 0; }

  cancelSend(): void { if (this.sendId) this.service?.cancelSend(this.sendId); }

  async createLink(): Promise<void> {
    if (!this.service || this.closed || this.creatingLink) return;
    if (this.link && this.service.isShareActive(this.link.token)) return;
    this.creatingLink = this.service.createWindowLink(this.files);
    try { this.link = await this.creatingLink; }
    finally { this.creatingLink = undefined; }
  }

  finish(success: boolean): Promise<void> {
    return this.session.terminateSelfWithResult({ resultCode: success ? 0 : 1 });
  }

  async dispose(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.cancelSend();
    await this.startup?.catch(() => {});
    await this.creatingLink?.catch(() => undefined);
    if (this.link) this.service?.revokeShare(this.link.token);
    if (this.owned) await this.service?.stop();
  }
}
