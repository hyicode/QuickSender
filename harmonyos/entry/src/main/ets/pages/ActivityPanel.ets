import { ActiveShare, TransferActivity } from '../services/TransferService';

@Component
export struct ActivityPanel {
  @Prop transfers: TransferActivity[] = [];
  @Prop shares: ActiveShare[] = [];
  onStop: (activity: TransferActivity) => void = () => {};
  onCopy: (link: string) => void = () => {};
  onRevoke: (token: string) => void = () => {};

  build() {
    Column({ space: 14 }) {
      if (this.transfers.length === 0 && this.shares.length === 0) {
        Text('暂无进行中的传输或有效链接').fontSize(14).fontColor($r('app.color.text_secondary')).padding(24)
      }
      if (this.transfers.length > 0) {
        Text('正在传输').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        ForEach(this.transfers, (activity: TransferActivity) => {
          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Text(activity.direction === 'send' ? `发送给 ${activity.peer}` : `接收自 ${activity.peer}`)
                .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Button(activity.stopping ? '正在停止' : '停止传输').fontSize(12).height(32)
                .backgroundColor($r('app.color.surface_warning')).fontColor($r('app.color.text_warning'))
                .enabled(!activity.stopping && activity.progress < 100).onClick(() => this.onStop(activity))
            }.width('100%')
            Text(activity.detail).fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Progress({ value: activity.progress, total: 100, type: ProgressType.Linear }).width('100%')
              .color($r('app.color.brand_fill'))
            Text(`${activity.progress}%`).fontSize(12).fontColor($r('app.color.text_secondary'))
          }.width('100%').padding(14).alignItems(HorizontalAlign.Start).borderRadius(16)
            .backgroundColor($r('app.color.surface_card'))
        }, (activity: TransferActivity) => `${activity.id}:${activity.progress}:${activity.stopping}:${activity.detail}`)
      }
      if (this.shares.length > 0) {
        Text('有效的临时链接').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        ForEach(this.shares, (share: ActiveShare) => {
          Column({ space: 10 }) {
            Text(share.fileNames.join('、')).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`有效至 ${new Date(share.expires).toLocaleTimeString()}`).fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Text(share.url).fontSize(13).fontColor($r('app.color.text_secondary')).wordBreak(WordBreak.BREAK_ALL)
              .copyOption(CopyOptions.LocalDevice).width('100%')
            Row({ space: 10 }) {
              Button('复制链接').fontSize(13).backgroundColor($r('app.color.brand_fill'))
                .onClick(() => this.onCopy(share.url))
              Button('让链接失效').fontSize(13).backgroundColor($r('app.color.surface_warning'))
                .fontColor($r('app.color.text_warning')).onClick(() => this.onRevoke(share.token))
            }.width('100%')
          }.width('100%').padding(14).alignItems(HorizontalAlign.Start).borderRadius(16)
            .backgroundColor($r('app.color.surface_card'))
        }, (share: ActiveShare) => share.token)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
