import { autoStartupManager, common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';
import { TransferService, LocalFile, ReceiveDecision, ActiveShare, TransferActivity } from '../services/TransferService';
import { TransferEvent } from '../services/TransferHistory';
import { Peer, Offer } from '../core/Protocol';
import { ConnectedDevice } from '../core/Visibility';
import { Runtime } from '../services/Runtime';
import { DeviceSections } from './DeviceSections';
import { ActivityPanel } from './ActivityPanel';
import { Appearance, Theme } from '../services/Appearance';

enum LinchuanPage { Home, History, Settings, Activity }

@Entry
@Component
struct Index {
  @State private screen: LinchuanPage = LinchuanPage.Home;
  @State private running: boolean = false;
  @State private searching: boolean = false;
  @State private hasSearched: boolean = false;
  @State private busy: boolean = false;
  @State private peers: Peer[] = [];
  @State private files: LocalFile[] = [];
  @State private events: TransferEvent[] = [];
  @State private transfers: TransferActivity[] = [];
  @State private shares: ActiveShare[] = [];
  @State private address: string = '';
  @State private message: string = '连接同一个 Wi-Fi，即可开始传输';
  @State private publicSeconds: number = 0;
  @State private devices: ConnectedDevice[] = [];
  @State private advanced: boolean = false;
  @State private theme: Theme = Theme.System;
  @State private changingTheme: boolean = true;
  @State private startupStatus: string = '';
  @State private notificationsEnabled: boolean | undefined = undefined;
  private checkedFirstLaunch: boolean = false;
  private readonly desktop: boolean = deviceInfo.deviceType === '2in1';
  private readonly pageScroller: Scroller = new Scroller();
  private shareRevision: number = 0;
  private service?: TransferService;

  aboutToAppear(): void {
    this.service = Runtime.get(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.service.onChange = () => this.sync();
    this.service.onOffer = (offer: Offer, timeout: number): Promise<ReceiveDecision> => new Promise(resolve => {
      let settled = false;
      const finish = (decision: ReceiveDecision): void => { if (!settled) { settled = true; clearTimeout(timer); resolve(decision); } };
      const timer = setTimeout(() => finish(false), timeout);
      const files = Object.keys(offer.files).map(id => offer.files[id]);
      const buttons: AlertDialogButtonOptions[] = [
        { value: '拒绝', action: () => finish(false) },
        { value: '仅接收本次', action: () => finish(true) }
      ];
      if (offer.info.quickSender === 1) {
        buttons.push({ value: '接收并允许以后自动接收', action: () => finish('always') });
      }
      this.getUIContext().showAlertDialog({
        title: `${this.service?.deviceName(offer.info) ?? offer.info.alias} 想发送文件`,
        message: `${files.length} 个文件 · ${(files.reduce((sum, f) => sum + f.size, 0) / 1048576).toFixed(2)} MiB\n${files.map(f => f.fileName).join('\n')}`,
        autoCancel: false,
        buttons,
        buttonDirection: DialogButtonDirection.VERTICAL,
        cancel: () => finish(false)
      });
    });
    this.run(async () => { await this.service?.start(); this.message = '选择文件，点击附近设备发送'; });
  }
  aboutToDisappear(): void { if (this.service) { this.service.onChange = () => {}; this.service.onOffer = async () => false; } }

  onPageShow(): void {
    this.refreshStartupStatus();
    this.checkPermissionsOnShow();
    if (this.screen === LinchuanPage.History) this.service?.refreshHistory();
  }

  onBackPress(): boolean {
    if (this.screen === LinchuanPage.Home) return false;
    this.openScreen(LinchuanPage.Home);
    return true;
  }

  private openScreen(screen: LinchuanPage): void {
    if (screen === this.screen) return;
    if (this.screen !== LinchuanPage.History) this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.screen = screen;
    if (screen === LinchuanPage.History) this.service?.refreshHistory();
    if (screen === LinchuanPage.Settings) {
      this.refreshStartupStatus();
      this.refreshPermissions();
    }
  }

  private screenTitle(): string {
    if (this.screen === LinchuanPage.History) return '传输记录';
    if (this.screen === LinchuanPage.Activity) return '活动';
    return '设置';
  }

  private async refreshPermissions(): Promise<void> {
    this.notificationsEnabled = await notificationManager.isNotificationEnabled().catch(() => undefined);
  }

  private async checkPermissionsOnShow(): Promise<void> {
    if (this.checkedFirstLaunch) {
      if (this.screen === LinchuanPage.Settings) await this.refreshPermissions();
      return;
    }
    this.checkedFirstLaunch = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = await preferences.getPreferences(context.getApplicationContext(), 'permissions');
      if (store.getSync('notificationRequested', false)) return;
      const enabled = await notificationManager.isNotificationEnabled();
      store.putSync('notificationRequested', true);
      await store.flush();
      if (!enabled) await notificationManager.requestEnableNotification(context);
    } catch (_) { /* Settings still lets the user change notification permission. */ }
    finally { if (this.screen === LinchuanPage.Settings) this.refreshPermissions(); }
  }

  private async openNotificationPermission(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await notificationManager.openNotificationSettingsWithResult(context);
      await this.refreshPermissions();
      return;
    } catch (_) { /* Fall back to the app's system settings. */ }
    try {
      await context.startAbility({
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: { pushParams: context.abilityInfo.bundleName }
      });
    } catch (_) {
      this.getUIContext().showAlertDialog({
        title: '开启通知',
        message: '在系统「设置 → 应用和元服务 → 邻传」中打开「通知」。',
        confirm: { value: '知道了', action: () => {} }
      });
    }
  }

  private async loadTheme(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.theme = await Appearance.read(context.getApplicationContext());
      if (this.theme !== Theme.System) context.getApplicationContext().setColorMode(Appearance.mode(this.theme));
    } catch (e) { this.message = `读取主题失败：${(e as Error).message}`; }
    finally { this.changingTheme = false; }
  }

  private async changeTheme(theme: Theme): Promise<void> {
    if (theme === this.theme || this.changingTheme) return;
    this.changingTheme = true;
    const context = (this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext();
    try {
      context.setColorMode(Appearance.mode(theme));
      await Appearance.save(context, theme);
      this.theme = theme;
    } catch (e) {
      context.setColorMode(Appearance.mode(this.theme));
      this.message = `保存主题失败：${(e as Error).message}`;
    } finally { this.changingTheme = false; }
  }

  private async refreshStartupStatus(): Promise<void> {
    if (!this.desktop || deviceInfo.sdkApiVersion < 21) return;
    try {
      this.startupStatus = await autoStartupManager.getAutoStartupStatusForSelf() ? '已开启' : '未开启';
    } catch (_) { this.startupStatus = ''; }
  }
  private sync(): void {
    if (!this.service) return;
    this.running = this.service.running;
    this.searching = this.service.searching;
    this.hasSearched = this.service.hasSearched;
    this.peers = this.service.peers.slice();
    this.files = this.service.files.slice();
    this.events = this.service.events.slice();
    this.transfers = this.service.activities();
    this.shares = this.service.activeShares();
    this.publicSeconds = this.service.visibility.remaining();
    this.devices = this.service.visibility.devices.slice();
    if (this.service.status) this.message = this.service.status;
    if (this.shareRevision !== this.service.shareRevision) {
      this.shareRevision = this.service.shareRevision;
      this.openScreen(LinchuanPage.Home);
    }
  }
  private async run(action: () => Promise<void>): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try { await action(); } catch (e) { this.message = (e as Error).message; }
    finally { this.busy = false; this.sync(); }
  }
  private async selectFiles(): Promise<boolean> {
    const select = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
    const uris = await select.select({ maxSelectNumber: 20 });
    if (!uris.length) return false;
    await this.service?.addFiles(uris);
    return true;
  }

  private async shareLink(): Promise<void> {
    if (this.files.length === 0 && !await this.selectFiles()) return;
    this.service?.startShare();
    this.message = '临时链接已生成，可在「活动」中复制';
  }

  private async copyLink(url: string): Promise<void> {
    await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url));
    this.message = '链接已复制';
  }

  private async startSend(peer: Peer): Promise<void> {
    try { await this.service?.send(peer); }
    catch (e) { this.message = (e as Error).message; }
  }

  private stopTransfer(activity: TransferActivity): void {
    if (activity.direction === 'send') this.service?.cancelSend(activity.id);
    else this.run(async () => { await this.service?.cancelReceive(activity.id); });
  }

  private visibilityStatus(): string {
    if (this.publicSeconds <= 0) return '仅连接过的设备可发现本机';
    const minutes = Math.floor(this.publicSeconds / 60).toString().padStart(2, '0');
    const seconds = (this.publicSeconds % 60).toString().padStart(2, '0');
    return `剩余 ${minutes}:${seconds} · 到期自动关闭`;
  }
  private changeVisibility(visible: boolean): void {
    if (!this.running || visible === (this.publicSeconds > 0)) return;
    this.run(async () => {
      if (visible) this.service?.openVisibility();
      else this.service?.closeVisibility();
    });
  }

  private toggleService(): void {
    this.run(async () => {
      if (this.running) { await this.service?.stop(); this.message = '服务已暂停'; }
      else { await this.service?.start(); this.message = '服务已启动，等待附近设备连接'; }
    });
  }

  @Builder
  private visibilityPanel() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Column({ space: 5 }) {
          Text('所有人可见').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(this.visibilityStatus()).fontSize(12).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.publicSeconds > 0 })
          .selectedColor($r('app.color.brand_fill')).enabled(this.running && !this.busy)
          .id('visibility-switch').accessibilityText('所有人可见，开启后持续 10 分钟')
          .onChange(visible => this.changeVisibility(visible))
      }.width('100%')
      if (!this.running && !this.busy) {
        Button('局域网服务未开启 · 去设置').fontSize(12).height(32)
          .backgroundColor($r('app.color.surface_action')).fontColor($r('app.color.text_link'))
          .onClick(() => this.openScreen(LinchuanPage.Settings))
      }
    }.width('100%').padding(14).borderRadius(18).backgroundColor($r('app.color.surface_card')).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private deviceSections() {
    DeviceSections({
      peers: this.peers,
      devices: this.devices,
      running: this.running,
      searching: this.searching,
      hasSearched: this.hasSearched,
      busy: this.busy,
      canSend: this.files.length > 0,
      onSearch: () => this.run(async () => { await this.service?.refresh(); }),
      onSend: (peer: Peer) => this.startSend(peer),
      onForget: (fingerprint: string) => this.run(async () => { this.service?.forgetDevice(fingerprint); }),
      onSetNickname: (fingerprint: string, nickname: string) => this.run(async () => { this.service?.setNickname(fingerprint, nickname); }),
      onSetAutoReceive: (fingerprint: string, enabled: boolean) => this.run(async () => { this.service?.setAutoReceive(fingerprint, enabled); })
    })
  }
  @Builder
  private fileList() {
    Column({ space: 12 }) {
      ForEach(this.files, (f: LocalFile) => {
        Row({ space: 12 }) {
          Text('↗').fontSize(24).fontColor($r('app.color.text_link')).width(36)
          Column({ space: 4 }) {
            Text(f.meta.fileName).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${(f.meta.size / 1048576).toFixed(2)} MiB`).fontSize(12).fontColor($r('app.color.text_muted'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('移除').type(ButtonType.Normal).fontSize(12).backgroundColor($r('app.color.surface_subtle')).fontColor($r('app.color.text_subtle'))
            .enabled(!this.busy).onClick(() => this.service?.removeFile(f.meta.id))
        }.width('100%').padding(14).borderRadius(14).backgroundColor($r('app.color.surface_card'))
      }, (f: LocalFile) => f.meta.id)
    }.width('100%')
  }

  @Builder
  private shareEntry() {
    Column({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Image($r('app.media.share_link')).width(38).height(38).padding(8)
            .backgroundColor($r('app.color.surface_selected')).borderRadius(12)
          Column({ space: 4 }) {
            Text('生成临时分享链接').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text('同一局域网内可用浏览器下载').fontSize(12)
              .fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(12)
      }.width('100%').borderRadius(18).backgroundColor($r('app.color.surface_card'))
        .enabled(this.running && !this.busy).id('home-share-link')
        .accessibilityText('生成临时分享链接')
        .onClick(() => this.run(() => this.shareLink()))
    }.width('100%').borderRadius(18).backgroundColor($r('app.color.surface_card'))
  }


  @Builder
  private sendPanel() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Column({ space: 7 }) {
          Text(this.files.length ? `已选择 ${this.files.length} 个文件` : '附近互传').fontSize(25).fontWeight(FontWeight.Bold).fontColor($r('app.color.brand_on_fill'))
          Text(this.files.length ? '从下方选择分享方式' : '选好文件，再选择分享方式').fontSize(13).fontColor('#DCE6FF')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.files.length ? '添加文件' : '选择文件').backgroundColor($r('app.color.surface_card')).fontColor($r('app.color.text_on_selected')).height(40).fontSize(13)
          .enabled(!this.busy).onClick(() => this.run(async () => {
            if (await this.selectFiles()) await this.service?.refresh();
          }))
      }.width('100%').padding(20).borderRadius(22)
        .linearGradient({ angle: 120, colors: [['#192A55', 0], [$r('app.color.brand_fill'), 1]] })
      this.visibilityPanel()
      if (this.files.length) this.fileList()
      this.shareEntry()
      this.deviceSections()
      Button(this.advanced ? '收起手动连接' : '找不到设备？手动连接').fontSize(12).fontColor($r('app.color.text_muted')).backgroundColor(Color.Transparent)
        .onClick(() => this.advanced = !this.advanced)
      if (this.advanced) { Row({ space: 10 }) {
        TextInput({ placeholder: '手动连接：192.168.1.10:53317', text: this.address }).layoutWeight(1).onChange(v => this.address = v)
        Button('连接').backgroundColor($r('app.color.surface_action')).fontColor($r('app.color.text_link')).enabled(this.running && !this.busy)
          .onClick(() => this.run(async () => { await this.service?.connect(this.address); }))
      }.width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private historyActions(id: string) {
    Row() {
      Button('删除').fontSize(13).height(42).backgroundColor($r('app.color.surface_warning'))
        .fontColor($r('app.color.text_warning')).accessibilityText('删除此记录').onClick(() => this.service?.removeEvent(id))
    }.height('100%').padding({ left: 6, right: 6 }).alignItems(VerticalAlign.Center)
  }

  @Builder
  private historyPanel() {
    Column({ space: 14 }) {
      Text('这里显示最近的发送和接收记录。左右滑动可删除单条记录，已接收的文件会保留。')
        .fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(22).width('100%')
      if (this.events.length === 0) {
        Text('暂无记录').fontColor($r('app.color.text_placeholder')).padding(40)
      } else {
        List({ space: 10 }) {
          ForEach(this.events, (event: TransferEvent) => {
            ListItem() {
              Column({ space: 6 }) {
                Row() {
                  Text(event.name).fontSize(16).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary')).layoutWeight(1)
                  Text(event.time).fontSize(12).fontColor($r('app.color.text_placeholder'))
                }.width('100%')
                Text(event.detail).fontSize(13).fontColor($r('app.color.text_muted')).wordBreak(WordBreak.BREAK_ALL)
              }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface_card')).borderRadius(14)
            }.swipeAction({ start: this.historyActions.bind(this, event.id), end: this.historyActions.bind(this, event.id),
              edgeEffect: SwipeEdgeEffect.None })
          }, (event: TransferEvent) => event.id)
        }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.None)
      }
    }.width('100%').constraintSize({ maxWidth: 760 }).layoutWeight(1).padding(16)
  }

  @Builder
  private notificationPermissionRow() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        if (this.notificationsEnabled === false) {
          Text('!').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#382800').textAlign(TextAlign.Center)
            .width(22).height(22).borderRadius(11).backgroundColor('#FFD66B')
        }
        Column({ space: 4 }) {
          Text('通知').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text('接收请求、完成通知和临时链接提醒').fontSize(12).lineHeight(19).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.notificationsEnabled === undefined ? '查看' : this.notificationsEnabled ? '已开启' : '去开启').fontSize(12)
          .fontColor($r('app.color.text_link'))
        Text('›').fontSize(18).fontColor($r('app.color.text_muted'))
      }.width('100%').padding(12)
    }.width('100%').borderRadius(12).padding(0).backgroundColor($r('app.color.surface_subtle'))
      .id('permission-notifications')
      .onClick(() => this.openNotificationPermission())
  }

  @Builder settingsPanel() {
    Column({ space: 16 }) {
      Column({ space: 12 }) {
        Text('外观主题').fontSize(17).fontWeight(FontWeight.Medium)
        Row({ space: 8 }) {
          ForEach(['跟随系统', '浅色', '深色'], (label: string, index: number) => {
            Button(label).type(ButtonType.Normal).borderRadius(12).layoutWeight(1).fontSize(13)
              .backgroundColor(this.theme === index ? $r('app.color.surface_selected') : $r('app.color.surface_subtle'))
              .fontColor(this.theme === index ? $r('app.color.text_on_selected') : $r('app.color.text_primary'))
              .enabled(!this.changingTheme).onClick(() => this.changeTheme(index))
          })
        }.width('100%')
      }.alignItems(HorizontalAlign.Start).width('100%').padding(16).borderRadius(18)
        .backgroundColor($r('app.color.surface_card'))
      Column({ space: 8 }) {
        Text('权限检查').fontSize(17).fontWeight(FontWeight.Medium)
        this.notificationPermissionRow()
      }.alignItems(HorizontalAlign.Start).width('100%').padding(16).borderRadius(18)
        .backgroundColor($r('app.color.surface_card'))
      Column({ space: 8 }) {
        Text(this.startupStatus ? `开机自启 · ${this.startupStatus}` : '开机自启').fontSize(17).fontWeight(FontWeight.Medium)
        Text(this.desktop ? '在系统设置的「应用和元服务 → 应用启动管理」中添加邻传。' : '手机和平板的应用启动由系统管理。')
          .fontSize(13).lineHeight(22).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start).width('100%').padding(16).borderRadius(18)
        .backgroundColor($r('app.color.surface_card'))
      Column({ space: 8 }) {
        Text('局域网服务').fontSize(17).fontWeight(FontWeight.Medium)
        Text('开启后可以发现设备、发送和接收文件。暂停会中断传输并关闭临时分享链接。')
          .fontSize(13).lineHeight(22).fontColor($r('app.color.text_secondary'))
        Button(this.running ? '暂停服务' : '启动服务').fontSize(13)
          .backgroundColor($r('app.color.surface_action')).fontColor($r('app.color.text_link'))
          .enabled(!this.busy).onClick(() => this.toggleService())
      }.alignItems(HorizontalAlign.Start).width('100%').padding(16).borderRadius(18)
        .backgroundColor($r('app.color.surface_card'))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private headerAction(icon: Resource, label: string, id: string, screen: LinchuanPage) {
    Button({ type: ButtonType.Circle }) {
      Image(icon).width(21).height(21).fillColor($r('app.color.text_primary'))
    }.width(40).height(40).backgroundColor($r('app.color.surface_subtle'))
      .id(id).accessibilityText(label).onClick(() => this.openScreen(screen))
  }

  @Builder
  private header() {
    Row({ space: 8 }) {
      if (this.screen === LinchuanPage.Home) {
        Image($r('app.media.app_icon')).width(40).height(40)
        Text($r('app.string.app_name')).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.transfers.length + this.shares.length > 0) {
          Stack({ alignContent: Alignment.TopEnd }) {
            this.headerAction($r('app.media.activity'), '活动', 'open-activity', LinchuanPage.Activity)
            Text(`${this.transfers.length + this.shares.length}`).fontSize(10).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.brand_on_fill')).backgroundColor($r('app.color.brand_fill'))
              .height(16).constraintSize({ minWidth: 16 }).padding({ left: 3, right: 3 })
              .textAlign(TextAlign.Center).borderRadius(8).offset({ x: 3, y: -3 }).hitTestBehavior(HitTestMode.None)
              .accessibilityLevel('no')
          }.width(40).height(40)
        }
        this.headerAction($r('app.media.history'), '传输记录', 'open-history', LinchuanPage.History)
        this.headerAction($r('app.media.settings'), '设置', 'open-settings', LinchuanPage.Settings)
      } else {
        this.headerAction($r('app.media.chevron_back'), '返回主页', 'back-home', LinchuanPage.Home)
        Text(this.screenTitle()).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .layoutWeight(1).padding({ left: 4 })
      }
    }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 12 }).backgroundColor($r('app.color.surface_card'))
  }

  build() {
    Column() {
      this.header()
      if (this.screen === LinchuanPage.History) {
        this.historyPanel()
      } else {
        Scroll(this.pageScroller) {
          Column() {
            if (this.screen === LinchuanPage.Home) { this.sendPanel() }
            else if (this.screen === LinchuanPage.Activity) {
              ActivityPanel({ transfers: this.transfers, shares: this.shares,
                onStop: (activity: TransferActivity) => this.stopTransfer(activity),
                onCopy: (url: string) => this.run(() => this.copyLink(url)),
                onRevoke: (token: string) => { this.service?.revokeShare(token); } })
            }
            else { this.settingsPanel() }
          }.width('100%').constraintSize({ maxWidth: 760 }).padding(16)
        }.layoutWeight(1).width('100%').align(Alignment.Top)
      }
      Column({ space: 5 }) {
        Text(this.busy ? '处理中，请稍候…' : this.message)
          .fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.padding({ left: 16, right: 16, top: 6, bottom: 6 }).width('100%').backgroundColor($r('app.color.surface_page'))
    }.height('100%').width('100%').backgroundColor($r('app.color.surface_page')).onAppear(() => this.loadTheme())
  }
}
