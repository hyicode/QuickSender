import { wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const INCOMING_ID = 60500;
const TAG = 'LinchuanNotice';

export class TransferNotifications {
  private static nextId: number = 1000000 + Date.now() % 1000000000;
  private links: Map<string, number> = new Map();

  async incoming(sender: string, count: number, until: number, automatic: boolean = false): Promise<boolean> {
    if (automatic) {
      return this.publish(INCOMING_ID, '自动接收等待继续', `${sender} 发来 ${count} 个文件，点按继续。`,
        notificationManager.SlotType.CONTENT_INFORMATION, until);
    }
    return this.publish(INCOMING_ID, '有新的文件分享', `${sender} 想发送 ${count} 个文件，点按查看。`,
      notificationManager.SlotType.SOCIAL_COMMUNICATION, until);
  }

  async clearIncoming(): Promise<void> {
    try { await notificationManager.cancel(INCOMING_ID); } catch (_) { /* Already removed. */ }
  }

  async complete(title: string, count: number, otherDevice: string): Promise<void> {
    await this.publish(TransferNotifications.nextId++, title, `${count} 个文件 · ${otherDevice}`,
      notificationManager.SlotType.SERVICE_INFORMATION);
  }

  async automaticReceive(sender: string, count: number): Promise<number> {
    const id = TransferNotifications.nextId++;
    await this.publish(id, '已自动接受分享', `${sender} · ${count} 个文件`, notificationManager.SlotType.CONTENT_INFORMATION);
    return id;
  }

  async completeAutomatic(id: number, sender: string, count: number): Promise<void> {
    await this.publish(id, '自动接收完成', `${sender} · ${count} 个文件`, notificationManager.SlotType.CONTENT_INFORMATION);
  }

  async shareActive(token: string, count: number, until: number): Promise<void> {
    if (this.links.has(token) || Date.now() >= until) return;
    const id = TransferNotifications.nextId++;
    this.links.set(token, id);
    const published = await this.publish(id, '临时分享链接生效中', `${count} 个文件 · 有效至 ${new Date(until).toLocaleTimeString()}`,
      notificationManager.SlotType.SERVICE_INFORMATION, until, false);
    if (published && this.links.get(token) !== id) await this.clear(id);
  }

  closeShare(token: string): void {
    const id = this.links.get(token);
    if (id === undefined) return;
    this.links.delete(token);
    this.clear(id);
  }

  private async clear(id: number): Promise<void> {
    try { await notificationManager.cancel(id); } catch (_) { /* Already removed. */ }
  }

  private async publish(id: number, title: string, text: string, slot: notificationManager.SlotType, until?: number,
    tapDismissed: boolean = true): Promise<boolean> {
    try {
      const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: 'com.quicksender.app', abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: id,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] }).catch(() => undefined);
      if (until !== undefined && Date.now() >= until) return false;
      const request: notificationManager.NotificationRequest = { id, notificationSlotType: slot, wantAgent: agent, tapDismissed,
        content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title, text } } };
      if (until !== undefined) request.autoDeletedTime = until;
      await notificationManager.publish(request);
      hilog.info(0, TAG, '通知已发布 %{public}d，类别 %{public}s', id, title);
      return true;
    } catch (e) {
      const error = e as BusinessError;
      hilog.warn(0, TAG, '通知发布失败 %{public}d %{public}s', error.code, error.message);
      return false;
    }
  }
}
