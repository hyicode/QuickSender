import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'LinchuanLive';

// Keep an actual transfer alive, never use a transfer task for idle discovery.
export class BackgroundTransfer {
  private count: number = 0;
  private active: boolean = false;
  private notificationId: number = -1;
  private taskId?: number;
  private nextUpdate: number = 0;
  private lastUpdate: string = '';
  private published: boolean = false;
  private lastError?: number;
  private queue: Promise<void> = Promise.resolve();
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  async begin(): Promise<void> {
    this.count++;
    this.queue = this.queue.catch(() => {}).then(async () => {
      if (this.active) return;
      try {
        const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: 'com.quicksender.app', abilityName: 'EntryAbility' }],
          operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0, wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
        const task = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent);
        this.notificationId = task.notificationId;
        this.taskId = task.continuousTaskId;
        this.nextUpdate = 0;
        this.lastUpdate = '';
        this.published = false;
        this.lastError = undefined;
        this.active = true;
        hilog.info(0, TAG, '后台传输任务已开始，通知 %{public}d，渠道 %{public}d，类型 %{public}d',
          task.notificationId, task.slotType, task.contentType);
      } catch (e) {
        hilog.warn(0, TAG, '申请后台传输失败 %{public}d', (e as BusinessError).code);
        throw new Error('无法申请后台传输，请保持应用在前台后重试');
      }
    }).catch((e: Error) => { this.count = Math.max(0, this.count - 1); throw e; });
    await this.queue;
  }

  progress(title: string, text: string, percentage: number, force: boolean = false): void {
    const now = Date.now();
    if (!this.active || this.notificationId < 0 || (!force && now < this.nextUpdate)) return;
    const update = `${title}\n${text}\n${percentage}`;
    if (!force && update === this.lastUpdate) return;
    const id = this.notificationId;
    this.lastUpdate = update;
    this.nextUpdate = now + 500;
    notificationManager.publish({
      id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title, text,
          progress: { maxValue: 100, currentValue: percentage, isPercentage: true } } },
      template: { name: 'downloadTemplate', data: { title, fileName: text, progressValue: percentage } }
    }).then(() => {
      if (this.notificationId !== id || this.published) return;
      this.published = true;
      hilog.info(0, TAG, '系统已接收传输进度更新，通知 %{public}d', id);
    }).catch((error: BusinessError) => {
      if (this.notificationId !== id) return;
      if (this.lastUpdate === update) this.lastUpdate = '';
      if (this.lastError === error.code) return;
      this.lastError = error.code;
      hilog.warn(0, TAG, '传输进度更新失败 %{public}d %{public}s', error.code, error.message);
    });
  }

  async end(): Promise<void> {
    this.count = Math.max(0, this.count - 1);
    this.queue = this.queue.catch(() => {}).then(async () => {
      if (!this.count && this.active) {
        this.active = false;
        this.notificationId = -1;
        if (this.taskId !== undefined && this.taskId >= 0) {
          await backgroundTaskManager.stopBackgroundRunning(this.context, this.taskId).catch(() => {});
        } else await backgroundTaskManager.stopBackgroundRunning(this.context).catch(() => {});
        this.taskId = undefined;
      }
    });
    await this.queue;
  }
}
