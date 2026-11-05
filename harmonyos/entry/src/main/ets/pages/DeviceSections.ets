import { Peer } from '../core/Protocol';
import { ConnectedDevice } from '../core/Visibility';
import { DiscoveryRadar } from './DiscoveryRadar';

@CustomDialog
struct DeviceAliasDialog {
  controller?: CustomDialogController;
  @State nickname: string = '';
  originalName: string = '';
  onSave: (nickname: string) => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('设置别名').fontSize(20).fontWeight(FontWeight.Medium)
      Text('别名仅在本机显示，留空恢复设备名称。').fontSize(13).fontColor($r('app.color.text_secondary'))
      TextInput({ text: this.nickname, placeholder: this.originalName })
        .maxLength(80).onChange(value => this.nickname = value).id('device-nickname')
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).onClick(() => this.controller?.close())
        Button('保存').layoutWeight(1).onClick(() => {
          this.onSave(this.nickname);
          this.controller?.close();
        })
      }.width('100%')
    }.width('100%').padding(22)
  }
}

@Component
export struct DeviceSections {
  @Prop peers: Peer[] = [];
  @Prop devices: ConnectedDevice[] = [];
  @Prop running: boolean = false;
  @Prop searching: boolean = false;
  @Prop showInlineRadar: boolean = true;
  @Prop hasSearched: boolean = false;
  @Prop busy: boolean = false;
  @Prop canSend: boolean = false;
  onSearch: () => void = () => {};
  onSend: (peer: Peer) => void = () => {};
  onForget: (fingerprint: string) => void = () => {};
  onSetNickname: (fingerprint: string, nickname: string) => void = () => {};
  onSetAutoReceive: (fingerprint: string, enabled: boolean) => void = () => {};
  @State private offlineExpanded: boolean = false;
  private scroller: ListScroller = new ListScroller();
  private aliasDialog?: CustomDialogController;

  private editNickname(device: ConnectedDevice): void {
    this.scroller.closeAllSwipeActions();
    this.aliasDialog = new CustomDialogController({
      builder: DeviceAliasDialog({
        nickname: device.nickname ?? '',
        originalName: this.onlinePeer(device)?.info.alias ?? device.alias,
        onSave: (nickname: string) => this.onSetNickname(device.fingerprint, nickname)
      })
    });
    this.aliasDialog.open();
  }

  private onlinePeer(device: ConnectedDevice): Peer | undefined {
    return this.peers.find(peer => peer.info.fingerprint === device.fingerprint);
  }

  private offlineDevices(): ConnectedDevice[] {
    return this.devices.filter(device => !this.onlinePeer(device));
  }

  private newDevices(): Peer[] {
    return this.peers.filter(peer => !this.devices.some(device => device.fingerprint === peer.info.fingerprint));
  }

  private confirmForget(device: ConnectedDevice): void {
    this.scroller.closeAllSwipeActions();
    this.getUIContext().showAlertDialog({
      title: '删除连接过的设备？',
      message: `删除 ${device.nickname || device.alias} 后，下次连接需要重新确认。已接收的文件会保留。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => this.onForget(device.fingerprint) }
    });
  }

  private toggleAutoReceive(device: ConnectedDevice): void {
    this.scroller.closeAllSwipeActions();
    if (device.autoReceive) {
      this.onSetAutoReceive(device.fingerprint, false);
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '开启自动接收？',
      message: `邻传将自动接收 ${device.nickname || device.alias} 发来的文件。之后可在这里关闭。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '开启', action: () => this.onSetAutoReceive(device.fingerprint, true) }
    });
  }

  @Builder
  private deviceActions(device: ConnectedDevice) {
    Row({ space: 6 }) {
      Button('设置别名').fontSize(12).height(42).backgroundColor($r('app.color.surface_action'))
        .fontColor($r('app.color.text_link')).enabled(!this.busy).onClick(() => this.editNickname(device))
      Button(!device.secret ? '自动接收不可用' : device.autoReceive ? '关闭自动接收' : '开启自动接收')
        .fontSize(12).height(42).backgroundColor($r('app.color.surface_action')).fontColor($r('app.color.text_link'))
        .enabled(!!device.secret && !this.busy).onClick(() => this.toggleAutoReceive(device))
      Button('删除').fontSize(13).height(42).backgroundColor($r('app.color.surface_warning'))
        .fontColor($r('app.color.text_warning')).enabled(!this.busy).onClick(() => this.confirmForget(device))
    }.height('100%').padding({ left: 6, right: 6 }).alignItems(VerticalAlign.Center)
  }

  @Builder
  private deviceRow(alias: string, type: string, detail: string, peer?: Peer) {
    Row({ space: 12 }) {
      Image(type === 'mobile' || type === 'tablet' ? $r('app.media.device_phone') : $r('app.media.device_pc'))
        .width(40).height(40).padding(8).backgroundColor($r('app.color.surface_selected')).borderRadius(12)
      Column({ space: 4 }) {
        Text(alias).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(detail).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (peer) {
        Button('发送').fontSize(13).height(36).backgroundColor($r('app.color.brand_fill'))
          .enabled(this.canSend && !this.busy).onClick(() => { if (peer) this.onSend(peer); })
      }
    }.width('100%').padding(12).backgroundColor($r('app.color.surface_card')).borderRadius(16)
  }

  @Builder
  private connectedRow(device: ConnectedDevice, peer?: Peer) {
    ListItem() {
      this.deviceRow(device.nickname || (peer?.info.alias ?? device.alias), device.deviceType,
        `${peer ? '在线' : '离线'} · ${device.autoReceive ? '自动接收已开启' : '每次确认'}`, peer)
    }.swipeAction({ start: this.deviceActions.bind(this, device), end: this.deviceActions.bind(this, device),
      edgeEffect: SwipeEdgeEffect.None })
  }

  build() {
    List({ space: 8, scroller: this.scroller }) {
      ListItem() {
        Row({ space: 8 }) {
          Text('连接过的设备').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
          if (this.searching && this.peers.length > 0) {
            Row({ space: 6 }) {
              LoadingProgress().width(16).height(16).color($r('app.color.text_link'))
              Text('正在搜索…').fontSize(13).fontColor($r('app.color.text_link'))
            }.height(34).padding({ left: 12, right: 12 }).borderRadius(17)
              .backgroundColor($r('app.color.surface_action')).id('search-in-progress')
          } else {
            Button(this.searching ? '正在搜索…' : '搜索附近设备').fontSize(13).height(34)
              .backgroundColor($r('app.color.surface_action')).fontColor($r('app.color.text_link'))
              .enabled(this.running && !this.searching && !this.busy).onClick(() => this.onSearch())
          }
        }.width('100%')
      }
      if (this.searching && this.peers.length === 0 && this.showInlineRadar) {
        ListItem() {
          Stack({ alignContent: Alignment.Center }) {
            DiscoveryRadar()
          }.width('100%').height(156).clip(true).id('search-radar').accessibilityText('正在搜索附近设备')
        }
      }
      if (this.devices.length > 0) {
        ListItem() {
          Text('左右滑动设备行可设置别名、管理自动接收或删除记录').fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }
      if (this.devices.length === this.offlineDevices().length) {
        ListItem() {
          Text(this.devices.length ? '暂无在线设备' : '暂无连接记录').fontSize(13)
            .fontColor($r('app.color.text_secondary')).padding({ top: 6, bottom: 6 })
        }
      }
      ForEach(this.devices.filter(device => !!this.onlinePeer(device)), (device: ConnectedDevice) => {
        this.connectedRow(device, this.onlinePeer(device))
      }, (device: ConnectedDevice) => `${device.fingerprint}:${device.nickname}:${device.autoReceive}:${this.onlinePeer(device)?.address}:${this.onlinePeer(device)?.info.alias}`)
      if (this.offlineDevices().length > 0) {
        ListItem() {
          Button(`${this.offlineExpanded ? '收起' : '展开'}离线设备（${this.offlineDevices().length}）`)
            .fontSize(13).height(34).backgroundColor(Color.Transparent).fontColor($r('app.color.text_link'))
            .onClick(() => this.offlineExpanded = !this.offlineExpanded)
        }
        if (this.offlineExpanded) {
          ForEach(this.offlineDevices(), (device: ConnectedDevice) => {
            this.connectedRow(device)
          }, (device: ConnectedDevice) => `${device.fingerprint}:${device.nickname}:${device.autoReceive}`)
        }
      }
      ListItem() {
        Text('未连接过的设备').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .padding({ top: 12 })
      }
      if (this.newDevices().length === 0) {
        ListItem() {
          Text(this.searching ? '正在查找附近设备…' : this.hasSearched ? '暂未发现新设备，请确认接收方已开启「所有人可见」。' : '点「搜索附近设备」查找可连接的设备。')
            .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).padding({ top: 4, bottom: 4 })
        }
      }
      ForEach(this.newDevices(), (peer: Peer) => {
        ListItem() {
          this.deviceRow(peer.info.alias, peer.info.deviceType, '可连接', peer)
        }
      }, (peer: Peer) => `${peer.info.fingerprint}:${peer.address}:${peer.info.alias}`)
    }.width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.PARENT_FIRST })
  }
}
