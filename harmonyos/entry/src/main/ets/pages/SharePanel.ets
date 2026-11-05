import { Peer } from '../core/Protocol';
import { common } from '@kit.AbilityKit';
import { ShareSession } from '../services/ShareSession';
import { pasteboard } from '@kit.BasicServicesKit';
import { DiscoveryRadar } from './DiscoveryRadar';
import { DeviceSections } from './DeviceSections';
import { ConnectedDevice } from '../core/Visibility';
import { Appearance, Theme } from '../services/Appearance';

@Entry({ useSharedStorage: true })
@Component
struct SharePanel {
  @LocalStorageProp('shareSessionId') private sessionId: number = 0;
  private model?: ShareSession;
  @State private peers: Peer[] = [];
  @State private devices: ConnectedDevice[] = [];
  @State private searching: boolean = false;
  @State private hasSearched: boolean = false;
  @State private selection: string = '正在读取分享内容…';
  @State private message: string = '';
  @State private ready: boolean = false;
  @State private sending: boolean = false;
  @State private sent: boolean = false;
  @State private progress: number = 0;
  @State private manual: boolean = false;
  @State private address: string = '';
  @State private link: string = '';
  @State private creatingLink: boolean = false;
  private timer: number = -1;
  private alive: boolean = false;

  aboutToAppear(): void {
    this.model = ShareSession.get(this.sessionId);
    this.alive = true;
    this.timer = setInterval(() => this.sync(), 350);
    this.start();
  }

  aboutToDisappear(): void {
    this.alive = false;
    clearInterval(this.timer);
  }

  private async loadTheme(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIExtensionContext;
      const theme = await Appearance.read(context.getApplicationContext());
      if (this.alive && theme !== Theme.System) context.setColorMode(Appearance.mode(theme));
    } catch (_) { /* Keep the host appearance when the share session is closing. */ }
  }

  private async start(): Promise<void> {
    try {
      if (!this.model) throw new Error('分享窗口无法读取本次内容，请重新分享');
      await this.model.start();
      if (!this.alive) return;
      const files = this.model.files;
      this.selection = files.length === 1 ? files[0].meta.fileName : `${files.length} 个文件`;
      this.ready = true;
      this.sync();
    } catch (e) {
      if (!this.alive) return;
      this.selection = '无法准备本次分享';
      this.message = (e as Error).message;
    }
  }

  private sync(): void {
    const service = this.model?.service;
    if (!service) return;
    if (this.peers.length !== service.peers.length || service.peers.some((peer, index) => peer !== this.peers[index])) {
      this.peers = service.peers.slice();
    }
    if (this.devices.length !== service.visibility.devices.length ||
      service.visibility.devices.some((device, index) => device !== this.devices[index])) {
      this.devices = service.visibility.devices.slice();
    }
    this.searching = service.searching;
    this.hasSearched = service.hasSearched;
    if (this.sending) this.progress = this.model?.sendProgress() ?? 0;
    const link = this.model?.link;
    this.link = link && service.isShareActive(link.token) ? link.url : '';
  }

  private async refresh(): Promise<void> {
    this.message = '';
    try {
      const search = this.model?.service?.refresh();
      this.sync();
      await search;
    }
    catch (e) { if (this.alive) this.message = (e as Error).message; }
  }

  private async connect(): Promise<void> {
    this.message = '';
    try { await this.model?.service?.connect(this.address); }
    catch (e) { if (this.alive) this.message = (e as Error).message; }
  }

  private async send(peer: Peer): Promise<void> {
    if (this.sending || this.sent) return;
    this.message = '等待对方确认接收…';
    this.progress = 0;
    this.sending = true;
    try {
      await this.model?.send(peer);
      if (!this.alive) return;
      this.sent = true;
      this.message = `发送完成 · ${this.model?.service?.deviceName(peer.info) ?? peer.info.alias}`;
    } catch (e) {
      if (this.alive) this.message = (e as Error).message;
    } finally {
      if (this.alive) this.sending = false;
    }
  }

  private async close(): Promise<void> {
    try { await this.model?.finish(this.sent); }
    catch (e) { if (this.alive) this.message = (e as Error).message; }
  }

  private async shareLink(): Promise<void> {
    if (this.creatingLink) return;
    this.creatingLink = true;
    try {
      await this.model?.createLink();
      if (!this.alive) return;
      this.sync();
      if (this.link) {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.link));
        if (this.alive) this.message = '链接已复制';
      }
    } catch (e) {
      if (this.alive) this.message = (e as Error).message;
    } finally {
      if (this.alive) this.creatingLink = false;
    }
  }

  private updateDevice(action: () => void): void {
    try {
      action();
      this.sync();
    } catch (e) { this.message = (e as Error).message; }
  }

  @Builder
  private linkCard() {
    Column({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Image($r('app.media.share_link')).width(24).height(24)
          Column({ space: 4 }) {
            Text(this.link ? '临时链接已生成' : this.creatingLink ? '正在生成临时分享链接…' : '生成临时分享链接')
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(this.link ? '关闭此窗口后链接失效' : '同一局域网内可用浏览器下载')
              .fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(2)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.link) {
            Text('复制链接').fontSize(13).fontColor($r('app.color.text_link'))
          }
        }.width('100%')
      }.width('100%').backgroundColor(Color.Transparent).enabled(!this.sending && !this.creatingLink)
        .accessibilityText(this.link ? '复制临时分享链接' : '生成临时分享链接').onClick(() => this.shareLink())
      if (this.link) {
        Text(this.link).fontSize(11).fontColor($r('app.color.text_secondary')).wordBreak(WordBreak.BREAK_ALL).maxLines(2)
          .copyOption(CopyOptions.LocalDevice).width('100%')
      }
    }.padding(12).width('100%').backgroundColor($r('app.color.surface_card')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.border_subtle') })
  }

  @Builder
  private content() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Image($r('app.media.app_icon')).width(38).height(38)
        Column({ space: 4 }) {
          Text('附近分享').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text(this.selection).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.sent ? '完成' : '×').fontSize(this.sent ? 14 : 24).height(40).constraintSize({ minWidth: 40 })
          .backgroundColor($r('app.color.surface_card')).fontColor($r('app.color.text_primary')).accessibilityText(this.sent ? '完成' : '关闭分享窗口')
          .onClick(() => this.close())
      }.width('100%')

      if (this.sending) {
        Progress({ value: this.progress, total: 100 }).width('100%').color($r('app.color.brand_fill'))
        Button('取消发送').fontSize(13).backgroundColor($r('app.color.surface_action')).fontColor($r('app.color.text_link'))
          .onClick(() => this.model?.cancelSend())
      }
      if (this.message) {
        Text(this.message).fontSize(13).fontColor(this.sent ? $r('app.color.text_success_dark') : $r('app.color.text_secondary')).width('100%')
      }
      if (this.ready && !this.sent) {
        Scroll() {
          DeviceSections({
            peers: this.peers,
            devices: this.devices,
            running: this.ready,
            searching: this.searching,
            showInlineRadar: false,
            hasSearched: this.hasSearched,
            busy: this.sending,
            canSend: this.ready,
            onSearch: () => this.refresh(),
            onSend: (peer: Peer) => this.send(peer),
            onForget: (fingerprint: string) => this.updateDevice(() => { this.model?.service?.forgetDevice(fingerprint); }),
            onSetNickname: (fingerprint: string, nickname: string) => this.updateDevice(() => {
              this.model?.service?.setNickname(fingerprint, nickname);
            }),
            onSetAutoReceive: (fingerprint: string, enabled: boolean) => this.updateDevice(() => {
              this.model?.service?.setAutoReceive(fingerprint, enabled);
            })
          })
        }.width('100%').layoutWeight(1).align(Alignment.Top)
        if (this.manual) {
          Row({ space: 8 }) {
            TextInput({ placeholder: '接收方 IP 地址', text: this.address }).layoutWeight(1).onChange(value => this.address = value)
            Button('查找').fontSize(13).enabled(!this.sending).onClick(() => this.connect())
          }.width('100%')
        } else {
          Button('按 IP 查找').fontSize(12).height(30).backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary')).enabled(!this.sending)
            .onClick(() => this.manual = true)
        }
      }
      if (this.ready && !this.sent) this.linkCard()
    }.width('100%').height('100%').padding({ left: 18, right: 18, top: 16, bottom: 14 })
      .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.ready && !this.sent && this.searching && this.peers.length === 0) DiscoveryRadar({ areaHeight: '80%' })
      this.content()
    }.width('100%').height('100%').clip(true).backgroundColor($r('app.color.surface_share')).onAppear(() => this.loadTheme())
  }
}
