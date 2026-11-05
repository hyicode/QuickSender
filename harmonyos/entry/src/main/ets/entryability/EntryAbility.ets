import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { Runtime } from '../services/Runtime';

export default class EntryAbility extends UIAbility {
  private shares: Promise<void> = Promise.resolve();
  onCreate(want: Want): void { this.receiveShare(want); }
  onNewWant(want: Want): void { this.receiveShare(want); }
  private receiveShare(want: Want): void {
    if (want.action !== 'ohos.want.action.sendData') return;
    this.shares = this.shares.then(async () => {
      const service = Runtime.get(this.context);
      try {
        await service.initialize();
        const data = await systemShare.getSharedData(want);
        const uris: string[] = [];
        for (const record of data.getRecords()) {
          if (record.uri && !uris.includes(record.uri)) uris.push(record.uri);
        }
        if (!uris.length) throw new Error('请选择图片、视频或文件分享给邻传');
        await service.importSharedFiles(uris);
      } catch (e) { service.status = (e as Error).message; service.onChange(); }
    }).catch(() => {});
  }
  onForeground(): void { Runtime.get(this.context).setForeground(true); }
  onBackground(): void { Runtime.get(this.context).setForeground(false); }
  onDestroy(): void { Runtime.destroy().catch(() => {}); }
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
  }
}
