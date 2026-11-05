import { socket, http, connection } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { Visibility, VisibilitySnapshot, ReplayGuard, proofPayload, DiscoveryProof } from '../core/Visibility';
import { BackgroundTransfer } from './BackgroundTransfer';
import { TransferNotifications } from './TransferNotifications';
import { HISTORY_LIMIT, TransferEvent, TransferHistory } from './TransferHistory';
import { DeviceInfo, Peer, FileMeta, Grant, Offer, Prepared, SessionStore, ProtocolError, PORT, GROUP, METADATA_LIMIT, SESSION_TTL, validInfo, validateOffer, escapeHtml } from '../core/Protocol';
import { HttpParser, RequestHead } from '../core/HttpParser';
import { IncomingFile, streamFile } from './FileBody';
import { uploadFile } from './HttpUpload';

export interface LocalFile { meta: FileMeta; uri: string; }
export type ReceiveDecision = boolean | 'always';
export interface ShareLink { token: string; url: string; expires: number; }
export interface ActiveShare extends ShareLink { fileNames: string[]; }
export interface TransferActivity {
  id: string;
  direction: 'send' | 'receive';
  peer: string;
  detail: string;
  progress: number;
  stopping: boolean;
}
interface SendTask extends TransferActivity { fingerprint: string; abort?: () => void; }
interface BrowserShare extends ShareLink { files: LocalFile[]; }
interface Reply { status: number; type: string; body: Uint8Array; file?: LocalFile; shareToken?: string; }
interface DiscoveryMessage extends DeviceInfo { quickSenderQuery?: number; }
interface UploadConnection { sessionId: string; close: () => void; }

export class TransferService {
  info: DeviceInfo = { alias: '邻传', version: '2.1', deviceModel: 'HarmonyOS', deviceType: 'mobile', fingerprint: '', port: PORT, protocol: 'http', download: false };
  peers: Peer[] = [];
  files: LocalFile[] = [];
  events: TransferEvent[] = [];
  private transientEvents: TransferEvent[] = [];
  private readonly history: TransferHistory;
  ip: string = '';
  running: boolean = false;
  private browserShares: Map<string, BrowserShare> = new Map();
  private browserPort: number = 0;
  onChange: () => void = () => {};
  onOffer: (offer: Offer, timeout: number) => Promise<ReceiveDecision> = async () => false;
  visibility: Visibility = new Visibility();
  status: string = '';
  searching: boolean = false;
  hasSearched: boolean = false;
  shareRevision: number = 0;
  private prefs?: preferences.Preferences;
  private replay: ReplayGuard = new ReplayGuard();
  private background?: BackgroundTransfer;
  private notices: TransferNotifications = new TransferNotifications();
  private automaticNotices: Map<string, Promise<number>> = new Map();
  private readonly discoveryOnly: boolean;
  private ready?: Promise<void>;
  private searchTimer: number = -1;
  private searchRound: number = 0;
  private searchedAddresses: Set<string> = new Set();
  private sends: Map<string, SendTask> = new Map();
  private backgrounded: boolean = false;
  private wakeOffer?: (foreground: boolean) => void;
  private receiveTasks: Set<string> = new Set();
  private context: common.Context;
  private server?: socket.TCPSocketServer;
  private udp?: socket.MulticastSocket;
  private sessions: SessionStore = new SessionStore();
  private clients: Map<number, socket.TCPSocketConnection> = new Map();
  private uploads: Map<number, UploadConnection> = new Map();
  private timer: number = -1;
  private pending: boolean = false;

  constructor(context: common.Context, discoveryOnly: boolean = false) {
    this.context = context;
    this.history = new TransferHistory(context.getApplicationContext?.().filesDir ?? context.filesDir);
    this.discoveryOnly = discoveryOnly;
    if (!discoveryOnly) this.background = new BackgroundTransfer(context as common.UIAbilityContext);
    this.info.quickSender = 1;
    this.info.deviceModel = deviceInfo.productModel;
    this.info.deviceType = deviceInfo.deviceType === '2in1' ? 'desktop' : 'mobile';
    this.info.alias = `邻传 · ${deviceInfo.deviceType === 'tablet' ? '平板' : deviceInfo.deviceType === '2in1' ? '电脑' : '手机'}`;
  }
  initialize(): Promise<void> {
    if (!this.ready) this.ready = this.load();
    return this.ready;
  }
  private async load(): Promise<void> {
    this.prefs = await preferences.getPreferences(this.context, 'quicksender');
    this.info.fingerprint = this.prefs.getSync('fingerprint', '') as string;
    if (!this.info.fingerprint) {
      this.info.fingerprint = this.id();
      this.prefs.putSync('fingerprint', this.info.fingerprint);
      this.prefs.flushSync();
    }
    try { this.visibility.restore(JSON.parse(this.prefs.getSync('visibility', '{}') as string) as VisibilitySnapshot); }
    catch (_) { this.visibility.close(); }
    this.refreshHistory();
  }
  private persist(): void {
    if (!this.prefs) throw new Error('设置尚未加载');
    this.prefs.putSync('visibility', JSON.stringify(this.visibility.snapshot()));
    this.prefs.flushSync();
    this.onChange();
  }
  openVisibility(): void { this.visibility.open(); this.persist(); this.publicAnnounce(false).catch(() => {}); }
  closeVisibility(): void {
    this.visibility.close();
    this.peers = this.peers.filter(p => p.publicDiscovery || !!this.visibility.get(p.info.fingerprint)?.secret);
    this.persist();
  }
  forgetDevice(fingerprint: string): void {
    this.visibility.remove(fingerprint);
    this.peers = this.peers.filter(p => p.info.fingerprint !== fingerprint);
    this.persist();
  }
  setAutoReceive(fingerprint: string, enabled: boolean): void {
    this.visibility.setAutoReceive(fingerprint, enabled);
    this.persist();
  }
  setNickname(fingerprint: string, nickname: string): void {
    if (this.visibility.setNickname(fingerprint, nickname)) this.persist();
  }
  deviceName(device: DeviceInfo): string {
    return this.visibility.get(device.fingerprint)?.nickname || device.alias;
  }
  setForeground(foreground: boolean): void {
    this.backgrounded = !foreground;
    if (foreground) {
      this.expirePeers();
      this.wakeOffer?.(true);
    } else {
      this.finishSearch();
    }
    this.updateTransferActivity(true);
    this.onChange();
  }

  private async waitForForeground(offer: Offer, until: number, automatic: boolean = false): Promise<boolean> {
    if (!this.backgrounded) return true;
    const wake = new Promise<boolean>(resolve => {
      const timer = setTimeout(() => this.wakeOffer?.(false), Math.max(0, until - Date.now()));
      this.wakeOffer = foreground => { clearTimeout(timer); this.wakeOffer = undefined; resolve(foreground); };
    });
    const published = await this.notices.incoming(this.deviceName(offer.info), Object.keys(offer.files).length, until, automatic);
    if (!published) this.wakeOffer?.(false);
    const foreground = await wake;
    await this.notices.clearIncoming();
    return foreground;
  }
  private async mac(secret: string, payload: string): Promise<string> {
    const key = await cryptoFramework.createSymKeyGenerator('HMAC').convertKey({ data: this.encode(secret) });
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(key);
    await mac.update({ data: this.encode(payload) });
    return Array.from((await mac.doFinal()).data).map(n => n.toString(16).padStart(2, '0')).join('');
  }
  private async identity(target: string, purpose: string): Promise<DeviceInfo> {
    const info = JSON.parse(JSON.stringify(this.info)) as DeviceInfo;
    const known = this.visibility.get(target);
    if (known?.secret) {
      const nonce = this.id(); const time = Date.now();
      const proof: DiscoveryProof = { nonce, time, mac: await this.mac(known.secret, proofPayload(this.info.fingerprint, target, purpose, nonce, time)) };
      info.proof = proof;
    }
    return info;
  }
  private async verified(info: DeviceInfo, purpose: string): Promise<boolean> {
    const known = this.visibility.get(info.fingerprint);
    const proof = info.proof;
    if (!known?.secret || !proof || !this.replay.valid(proof)) return false;
    const expected = await this.mac(known.secret, proofPayload(info.fingerprint, this.info.fingerprint, purpose, proof.nonce, proof.time));
    if (expected !== proof.mac || this.visibility.get(info.fingerprint)?.secret !== known.secret || !this.replay.valid(proof)) return false;
    this.replay.consume(proof);
    return true;
  }
  private id(): string { return util.generateRandomUUID(true); }
  private encode(s: string): Uint8Array { return s.length ? new util.TextEncoder().encodeInto(s) : new Uint8Array(0); }
  private decode(b: Uint8Array): string { return util.TextDecoder.create('utf-8').decodeWithStream(b); }
  private log(name: string, detail: string, remember: boolean = false): void {
    const now = new Date();
    const event: TransferEvent = { id: this.id(), name, detail, time: now.toLocaleString(), createdAt: now.getTime() };
    if (!remember || !this.history.save(event)) {
      this.transientEvents = [event, ...this.transientEvents].slice(0, HISTORY_LIMIT);
    }
    this.refreshHistory();
  }
  refreshHistory(): void {
    this.events = [...this.transientEvents, ...this.history.list()]
      .sort((a, b) => b.createdAt - a.createdAt).slice(0, HISTORY_LIMIT);
    this.onChange();
  }
  removeEvent(id: string): void {
    const event = this.events.find(item => item.id === id);
    if (!event) return;
    this.history.remove(event);
    this.transientEvents = this.transientEvents.filter(item => item.id !== id);
    this.refreshHistory();
  }
  async start(): Promise<void> {
    await this.initialize();
    if (this.running) return;
    const net = await connection.getDefaultNet();
    const properties = await connection.getConnectionProperties(net);
    this.ip = properties.linkAddresses.map(a => a.address.address).find(a => /^\d+\.\d+\.\d+\.\d+$/.test(a) && !a.startsWith('127.')) || '';
    if (!this.ip) throw new Error('请先连接到有 IPv4 地址的局域网');
    try {
      if (!this.discoveryOnly) {
        this.server = socket.constructTCPSocketServerInstance();
        this.server.on('connect', client => this.accept(client));
        await this.server.listen({ address: this.ip, port: PORT, family: 1 });
        const bound = await this.server.getLocalAddress();
        this.info.port = bound.port || PORT;
        this.browserPort = this.info.port;
      }
      this.running = true;
      this.timer = setInterval(() => {
        this.expirePeers();
        this.sessions.prune(Date.now());
        this.receiveTasks.forEach(id => { if (!this.sessions.sessions.has(id)) this.endReceiveTask(id).catch(() => {}); });
        this.updateTransferActivity();
        this.browserShares.forEach((share, token) => {
          if (Date.now() >= share.expires) this.revokeShare(token);
        });
        if (this.visibility.publicUntil && !this.visibility.isPublic()) this.closeVisibility();
        this.onChange();
      }, 1000);
      try {
        this.udp = socket.constructMulticastSocketInstance();
        await this.udp.setExtraOptions({ reuseAddress: true }).catch(() => {});
        this.udp.on('message', message => {
          if (message.message.byteLength > 4096) return;
          this.receiveDiscovery(this.decode(new Uint8Array(message.message)), message.remoteInfo.address).catch(() => {});
        });
        await this.udp.bind({ address: '0.0.0.0', port: PORT, family: 1 });
        await this.udp.addMembership({ address: GROUP, port: PORT, family: 1 });
        this.publicAnnounce(false).catch(() => {});
      } catch (_) { this.log('设备发现受限', '可通过 IP 手动连接；请检查组播与端口占用'); }
      this.log('服务已启动', `${this.ip}:${this.info.port}`);
    } catch (e) { await this.stop(); throw e as Error; }
  }
  async stop(): Promise<void> {
    this.running = false;
    this.finishSearch();
    this.hasSearched = false;
    this.wakeOffer?.(false);
    clearInterval(this.timer);
    this.sends.forEach(task => this.cancelSend(task.id));
    this.browserShares.forEach(share => this.notices.closeShare(share.token));
    this.browserShares.clear();
    this.browserPort = 0;
    this.sessions.sessions.clear();
    for (const id of Array.from(this.receiveTasks)) await this.endReceiveTask(id);
    this.uploads.forEach(upload => upload.close());
    this.clients.forEach(c => { c.close().catch(() => {}); });
    this.clients.clear();
    this.uploads.clear();
    if (this.udp) { await this.udp.close().catch(() => {}); this.udp = undefined; }
    if (this.server) { await this.server.close().catch(() => {}); this.server = undefined; }
    this.peers = [];
    this.onChange();
  }
  private expirePeers(): void {
    this.peers = this.peers.filter(p => Date.now() - p.seen < 90000);
  }
  private finishSearch(): void {
    if (!this.searching) return;
    clearTimeout(this.searchTimer);
    this.searching = false;
    this.searchedAddresses.clear();
    this.onChange();
  }
  async refresh(): Promise<void> {
    if (!this.running || this.searching) return;
    this.searchRound++;
    this.searching = true;
    this.hasSearched = true;
    this.expirePeers();
    // A fresh response replaces the previous peer entry in remember().
    const awaitingReply = new Set(this.peers.filter(peer => !!this.visibility.get(peer.info.fingerprint)?.secret));
    this.searchTimer = setTimeout(() => {
      this.peers = this.peers.filter(peer => !awaitingReply.has(peer));
      this.finishSearch();
    }, 4000);
    this.onChange();
    for (const device of this.visibility.devices.slice()) {
      if (device.secret) this.probeKnown(device.fingerprint, device.address);
    }
    if (!this.discoveryOnly && this.visibility.isPublic()) await this.publicAnnounce(true);
    else if (this.udp) {
      await this.udp.send({ data: '{"quickSenderQuery":1}', address: { address: GROUP, port: PORT, family: 1 } });
    }
  }
  private async endReceiveTask(id: string): Promise<void> {
    if (!this.receiveTasks.delete(id)) return;
    this.automaticNotices.delete(id);
    this.updateTransferActivity();
    this.onChange();
    await this.background?.end();
  }

  sendProgress(id: string): number { return this.sends.get(id)?.progress ?? 0; }

  activities(): TransferActivity[] {
    const activities: TransferActivity[] = [];
    this.sends.forEach(task => {
      activities.push({ id: task.id, direction: 'send', peer: task.peer, detail: task.detail,
        progress: task.progress, stopping: task.stopping });
    });
    this.receiveTasks.forEach(id => {
      const session = this.sessions.sessions.get(id);
      if (!session) return;
      let total = 0;
      let received = 0;
      let completed = 0;
      session.grants.forEach(grant => {
        total += grant.meta.size;
        received += grant.done ? grant.meta.size : grant.received;
        if (grant.done) completed++;
      });
      activities.push({ id, direction: 'receive', peer: session.sender, detail: `${session.grants.size} 个文件`,
        progress: completed === session.grants.size ? 100 : total ? Math.min(99, Math.floor(received / total * 100)) : 0,
        stopping: false });
    });
    return activities;
  }

  async cancelReceive(id: string): Promise<void> {
    if (!this.sessions.sessions.delete(id) && !this.receiveTasks.has(id)) return;
    this.uploads.forEach(upload => {
      if (upload.sessionId === id) upload.close();
    });
    await this.endReceiveTask(id);
  }

  private updateTransferActivity(force: boolean = false): void {
    if (!this.background) return;
    let count = 0;
    let total = 0;
    let received = 0;
    this.receiveTasks.forEach(id => this.sessions.sessions.get(id)?.grants.forEach(grant => {
      count++;
      total += grant.meta.size;
      received += grant.done ? grant.meta.size : grant.received;
    }));
    if (count) this.background.progress('邻传正在接收', `${count} 个文件`,
      total ? Math.min(99, Math.floor(received / total * 100)) : 0, force);
    else if (this.sends.size) {
      let progress = 0;
      this.sends.forEach(task => { progress += task.progress; });
      this.background.progress('邻传正在发送', `${this.sends.size} 项传输`, Math.floor(progress / this.sends.size), force);
    }
  }
  private async publicAnnounce(announce: boolean): Promise<void> {
    if (!this.udp || !this.running || this.discoveryOnly || !this.visibility.isPublic()) return;
    this.info.announce = announce;
    await this.udp.send({ data: JSON.stringify(this.info), address: { address: GROUP, port: PORT, family: 1 } });
  }
  private async receiveDiscovery(data: string, address: string): Promise<void> {
    const info = JSON.parse(data) as DiscoveryMessage;
    if (info?.quickSenderQuery === 1) {
      await this.publicAnnounce(false);
      return;
    }
    if (!validInfo(info) || info.fingerprint === this.info.fingerprint) return;
    if (this.visibility.get(info.fingerprint)?.secret) {
      if (this.searching) this.probeKnown(info.fingerprint, address);
    } else this.remember(info, address, true);
    if (info.announce) await this.publicAnnounce(false);
  }
  private probeKnown(fingerprint: string, address: string): void {
    const key = `${fingerprint}\n${address}`;
    if (this.searchedAddresses.has(key)) return;
    this.searchedAddresses.add(key);
    this.discoverKnown(fingerprint, address, this.searchRound).catch(() => {});
  }
  private async discoverKnown(fingerprint: string, address: string, round?: number): Promise<boolean> {
    const device = this.visibility.get(fingerprint);
    if (!device?.secret || !this.running) return false;
    const identity = await this.identity(fingerprint, 'register');
    if (round !== undefined && (!this.searching || round !== this.searchRound)) return false;
    const text = await this.request(`http://${address}:${device.port}/api/localsend/v2/register`, JSON.stringify(identity), true,
      http.RequestMethod.POST, 2500);
    const info = JSON.parse(text) as DeviceInfo;
    if (!validInfo(info) || info.fingerprint !== fingerprint || !await this.verified(info, 'register-response')) return false;
    if (round !== undefined && (!this.searching || round !== this.searchRound)) return false;
    this.remember(info, address);
    device.address = address;
    return true;
  }
  private remember(info: DeviceInfo, address: string, publicDiscovery: boolean = false): void {
    if (!validInfo(info) || info.fingerprint === this.info.fingerprint) return;
    const clean = JSON.parse(JSON.stringify(info)) as DeviceInfo;
    clean.proof = undefined;
    this.peers = [...this.peers.filter(p => p.info.fingerprint !== info.fingerprint), { info: clean, address, seen: Date.now(), publicDiscovery }];
    this.onChange();
  }
  async connect(address: string): Promise<void> {
    const parts = address.trim().split(':');
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(parts[0]) || parts[0].split('.').some(v => Number(v) > 255)) throw new Error('请输入 IPv4 地址，可附加 :端口');
    const port = parts[1] ? Number(parts[1]) : PORT;
    if (parts.length > 2 || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error('端口无效');
    const known = this.visibility.devices.find(d => d.secret && d.address === parts[0] && d.port === port);
    if (known && await this.discoverKnown(known.fingerprint, parts[0]).catch(() => false)) return;
    const text = await this.request(`http://${parts[0]}:${port}/api/localsend/v2/info`, '', true, http.RequestMethod.GET);
    const info = JSON.parse(text) as DeviceInfo;
    info.port = port; info.protocol = 'http';
    if (!validInfo(info)) throw new Error('对方未返回有效的 LocalSend 设备信息');
    if (this.visibility.get(info.fingerprint)?.secret) {
      if (await this.discoverKnown(info.fingerprint, parts[0]).catch(() => false)) return;
      throw new Error('无法验证已连接的设备，请确认对方在线');
    }
    this.remember(info, parts[0], true);
  }
  async prepareFiles(uris: string[]): Promise<LocalFile[]> {
    if (uris.length > 20) throw new Error('最多选择 20 个文件');
    const added: LocalFile[] = [];
    for (const uri of uris) {
      const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = await fs.stat(file.fd);
        if (!Number.isSafeInteger(stat.size) || stat.size < 0) throw new Error('文件长度无效');
        const name = decodeURIComponent(uri.split('/').pop() || 'file');
        added.push({ meta: { id: this.id(), fileName: name, size: stat.size, fileType: 'application/octet-stream' }, uri });
      } finally { await fs.close(file); }
    }
    return added;
  }
  async addFiles(uris: string[]): Promise<void> {
    if (this.files.length + uris.length > 20) throw new Error('最多选择 20 个文件');
    const added = await this.prepareFiles(uris);
    this.files = [...this.files, ...added];
    this.onChange();
  }
  async importSharedFiles(uris: string[]): Promise<void> {
    const previous = this.files;
    this.files = [];
    try { await this.addFiles(uris); }
    catch (e) { this.files = previous; throw e as Error; }
    this.shareRevision++;
    this.status = '文件已准备好，点击附近设备即可发送';
    this.onChange();
  }
  removeFile(id: string): void { this.files = this.files.filter(f => f.meta.id !== id); this.onChange(); }
  startShare(): string {
    if (!this.running || !this.files.length) throw new Error('请先启动服务并选择文件');
    return this.newBrowserShare(this.files).url;
  }
  activeShares(): ActiveShare[] {
    const active: ActiveShare[] = [];
    this.browserShares.forEach(share => {
      if (Date.now() < share.expires) active.push({ token: share.token, url: share.url, expires: share.expires,
        fileNames: share.files.map(file => file.meta.fileName) });
    });
    return active.reverse();
  }
  isShareActive(token: string): boolean {
    const share = this.browserShares.get(token);
    return !!share && Date.now() < share.expires;
  }
  revokeShare(token: string): void {
    if (!this.browserShares.delete(token)) return;
    this.notices.closeShare(token);
    this.onChange();
  }
  async createWindowLink(files: LocalFile[]): Promise<ShareLink> {
    if (!this.running || !files.length) throw new Error('没有可分享的文件');
    if (!this.browserPort) {
      const server = socket.constructTCPSocketServerInstance();
      try {
        server.on('connect', client => this.accept(client));
        await server.listen({ address: this.ip, port: 0, family: 1 });
        const bound = await server.getLocalAddress();
        if (!bound.port || !this.running) throw new Error('无法启动临时链接');
        this.server = server;
        this.browserPort = bound.port;
      } catch (e) {
        await server.close().catch(() => {});
        throw e as Error;
      }
    }
    return this.newBrowserShare(files);
  }
  private newBrowserShare(files: LocalFile[]): BrowserShare {
    if (this.activeShares().length >= 10) throw new Error('最多同时保留 10 条临时链接，请先关闭一条');
    const token = this.id();
    const share: BrowserShare = { token, url: `http://${this.ip}:${this.browserPort}/s/${token}`,
      expires: Date.now() + 10 * 60 * 1000, files: files.slice() };
    this.browserShares.set(token, share);
    this.notices.shareActive(token, files.length, share.expires);
    this.onChange();
    return share;
  }
  async send(peer: Peer, filesToSend: LocalFile[] = this.files, foregroundOnly: boolean = false,
    onStarted?: (id: string) => void): Promise<void> {
    if (!this.running || !filesToSend.length) throw new Error('请先启动服务并选择文件');
    if (peer.info.protocol !== 'http') throw new Error('当前原型仅支持 HTTP，请在对方 LocalSend 中关闭加密后重试');
    if (this.sends.size >= 4) throw new Error('最多同时进行 4 项发送');
    if (Array.from(this.sends.values()).some(task => task.fingerprint === peer.info.fingerprint)) {
      throw new Error('已经有一项传输正在发送给该设备');
    }
    const selected = filesToSend.slice();
    const files: Record<string, FileMeta> = {};
    selected.forEach(f => { files[f.meta.id] = f.meta; });
    const base = `http://${peer.address}:${peer.info.port}/api/localsend/v2`;
    let sessionId = '';
    const revision = this.visibility.revision;
    const task: SendTask = { id: this.id(), fingerprint: peer.info.fingerprint, direction: 'send', peer: this.deviceName(peer.info),
      detail: `等待对方接收 · ${selected.length} 个文件`, progress: 0, stopping: false };
    this.sends.set(task.id, task);
    let backgroundStarted = false;
    try {
      onStarted?.(task.id);
      this.onChange();
      if (!foregroundOnly && this.background) {
        await this.background.begin();
        backgroundStarted = true;
        this.updateTransferActivity();
      }
      if (task.stopping) throw new Error('发送已取消');
      this.log('等待对方确认', task.peer);
      const identity = await this.identity(peer.info.fingerprint, 'prepare-upload');
      if (task.stopping) throw new Error('发送已取消');
      let text: string;
      try {
        text = await this.request(`${base}/prepare-upload`, JSON.stringify({ info: identity, files } as Offer), true,
        http.RequestMethod.POST, 120000, task);
      } catch (error) {
        const code = (error as BusinessError).code;
        if (code === 2300028 || code === 2300007) {
          throw new Error('未收到接收方响应。请在接收设备上确认；若未弹出接收请求，请检查双方是否在同一局域网，以及接收设备的防火墙是否允许邻传。');
        }
        throw error as Error;
      }
      if (!text) throw new Error('对方未选择文件');
      const prepared = JSON.parse(text) as Prepared;
      if (!prepared.sessionId || !prepared.files) throw new Error('对方返回了无效会话');
      sessionId = prepared.sessionId;
      if (task.stopping) throw new Error('发送已取消');
      if (this.visibility.revision === revision) {
        const secret = prepared.pairSecret || this.visibility.get(peer.info.fingerprint)?.secret || '';
        this.visibility.connect(peer.info, peer.address, secret);
        this.persist();
      }
      let completed = 0;
      const accepted = selected.filter(file => !!prepared.files[file.meta.id]);
      if (!accepted.length) throw new Error('对方未选择文件');
      const total = accepted.reduce((bytes, file) => bytes + file.meta.size, 0);
      let sent = 0;
      for (const f of accepted) {
        if (task.stopping) throw new Error('发送已取消');
        const token = prepared.files[f.meta.id];
        task.detail = f.meta.fileName;
        this.onChange();
        const path = `/api/localsend/v2/upload?sessionId=${encodeURIComponent(sessionId)}&fileId=${encodeURIComponent(f.meta.id)}&token=${encodeURIComponent(token)}`;
        await this.uploadToPeer(peer, path, f, task, count => {
          sent += count;
          const progress = Math.min(99, Math.floor(sent / total * 100));
          if (task.progress !== progress) { task.progress = progress; this.updateTransferActivity(); this.onChange(); }
        });
        if (++completed === accepted.length) task.progress = 100;
        this.log('发送完成', `${f.meta.fileName} · 发给 ${task.peer}`, true);
      }
      if (completed) await this.notices.complete('发送完成', completed, task.peer);
    } catch (e) {
      if (sessionId) await this.request(`${base}/cancel?sessionId=${encodeURIComponent(sessionId)}`, '', false,
        http.RequestMethod.POST, 2500).catch(() => '');
      if (task.stopping) throw new Error('发送已取消');
      throw e as Error;
    } finally {
      if (backgroundStarted) await this.background?.end();
      this.sends.delete(task.id);
      this.updateTransferActivity();
      this.onChange();
    }
  }
  cancelSend(id: string): void {
    const task = this.sends.get(id);
    if (!task || task.stopping || task.progress >= 100) return;
    task.stopping = true;
    task.abort?.();
    this.onChange();
  }
  private async uploadToPeer(peer: Peer, path: string, file: LocalFile, task: SendTask, onBytes: (count: number) => void): Promise<void> {
    await uploadFile({ address: peer.address, port: peer.info.port, path, uri: file.uri, size: file.meta.size },
      abort => { task.abort = abort; }, onBytes);
  }
  private async request(url: string, body: string | ArrayBuffer, json: boolean, method: http.RequestMethod = http.RequestMethod.POST,
    readTimeout: number = 120000, task?: SendTask): Promise<string> {
    const client = http.createHttp();
    try {
      const pending = client.request(url, {
        method, header: { 'Content-Type': json ? 'application/json' : 'application/octet-stream' },
        extraData: method === http.RequestMethod.GET ? undefined : body, connectTimeout: Math.min(5000, readTimeout), readTimeout, usingProxy: false,
        expectDataType: http.HttpDataType.STRING
      });
      const response = task ? await Promise.race([pending, new Promise<http.HttpResponse>((_resolve, reject) => {
        task.abort = () => reject(new Error('发送已取消'));
      })]) : await pending;
      if (response.responseCode < 200 || response.responseCode >= 300) throw new Error(`对方返回 ${response.responseCode}：${response.result}`);
      return response.result as string;
    } finally {
      if (task) task.abort = undefined;
      client.destroy();
    }
  }
  private accept(client: socket.TCPSocketConnection): void {
    if (!this.running || this.clients.size >= 4) { client.close().catch(() => {}); return; }
    this.clients.set(client.clientId, client);
    let address = '';
    let handled = false;
    let continued = false;
    let closed = false;
    let upload: Grant | undefined;
    let incoming: IncomingFile | undefined;
    let uploadId = '';
    let timeout = -1;
    const releaseUpload = (): void => {
      incoming?.discard();
      incoming = undefined;
      if (upload) { upload.received = 0; upload.busy = false; upload = undefined; }
    };
    const disconnect = (): void => {
      closed = true;
      releaseUpload();
      clearTimeout(timeout);
      this.clients.delete(client.clientId);
      this.uploads.delete(client.clientId);
    };
    const close = (): void => { disconnect(); client.close().catch(() => {}); };
    const touch = (): void => {
      if (closed) return;
      clearTimeout(timeout);
      timeout = setTimeout(close, 120000);
    };
    const parser = new HttpParser(head => {
      if (this.discoveryOnly || head.method !== 'POST' || head.path !== '/api/localsend/v2/upload') return undefined;
      upload = this.claimUpload(head, address);
      if (upload.meta.size !== head.length) throw new ProtocolError(400, '文件大小不匹配');
      uploadId = head.query.get('sessionId') || '';
      const dir = `${this.context.filesDir}/received`;
      try { fs.mkdirSync(dir, true); }
      catch (e) { if (!fs.statSync(dir).isDirectory()) throw e as Error; }
      const writer = new IncomingFile(`${dir}/${this.id()}_${upload.meta.fileName}`, upload.meta);
      incoming = writer;
      const grant = upload;
      this.uploads.set(client.clientId, { sessionId: uploadId, close });
      return chunk => {
        if (!this.sessions.sessions.has(uploadId)) throw new ProtocolError(403, '传输会话已结束');
        writer.write(chunk);
        grant.received += chunk.length;
        this.updateTransferActivity();
      };
    });
    touch();
    client.on('close', disconnect);
    client.on('error', close);
    client.on('message', message => {
      if (handled || closed) return;
      touch();
      address = message.remoteInfo.address;
      try {
        parser.push(new Uint8Array(message.message));
        if (parser.head?.expect && !continued && !parser.complete) {
          continued = true;
          client.send({ data: 'HTTP/1.1 100 Continue\r\n\r\n' }).catch(() => {});
        }
        if (parser.complete && parser.head) {
          handled = true;
          let response: Promise<Reply>;
          if (incoming && upload) {
            response = this.finishUpload(uploadId, upload, incoming);
            incoming = undefined;
            upload = undefined;
          } else response = this.route(parser.head, parser.body(), address, () => !closed);
          response.catch((error: Error) => this.errorReply(error))
            .then(reply => this.respond(client, reply, touch)).catch(() => {}).finally(disconnect);
        }
      } catch (e) {
        releaseUpload();
        handled = true;
        this.respond(client, this.errorReply(e as Error), touch).catch(() => {}).finally(disconnect);
      }
    });
  }

  private async finishUpload(id: string, grant: Grant, file: IncomingFile): Promise<Reply> {
    try {
      const session = this.sessions.sessions.get(id);
      if (!session) throw new ProtocolError(403, '传输会话已失效');
      file.commit();
      grant.done = true;
      session.expires = Date.now() + SESSION_TTL;
      this.log('接收完成', `${grant.meta.fileName} · 来自 ${session.sender}`, true);
      if (Array.from(session.grants.values()).every(g => g.done)) {
        const automaticNotice = this.automaticNotices.get(id);
        if (automaticNotice) await this.notices.completeAutomatic(await automaticNotice, session.sender, session.grants.size);
        else await this.notices.complete('接收完成', session.grants.size, session.sender);
        this.sessions.sessions.delete(id);
        await this.endReceiveTask(id);
      }
      return this.reply(200, '');
    } finally {
      if (!grant.done) file.discard();
      grant.busy = false;
      grant.received = 0;
    }
  }

  private errorReply(e: Error): Reply { return this.reply(e instanceof ProtocolError ? e.status : 500, e.message); }
  private reply(status: number, text: string, type: string = 'text/plain; charset=utf-8'): Reply { return { status, type, body: this.encode(text) }; }
  private async respond(client: socket.TCPSocketConnection, reply: Reply, touch: () => void): Promise<void> {
    let started = false;
    const send = async (data: string | ArrayBuffer): Promise<void> => {
      await client.send({ data });
      touch();
    };
    const sendHeader = async (response: Reply, length: number): Promise<void> => {
      const disposition = response.file ? `Content-Disposition: attachment; filename*=UTF-8''${encodeURIComponent(response.file.meta.fileName)}\r\n` : '';
      started = true;
      await send(`HTTP/1.1 ${response.status} Result\r\nContent-Type: ${response.type}\r\nContent-Length: ${length}\r\n` +
        `Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n${disposition}\r\n`);
    };
    const sendReply = async (response: Reply): Promise<void> => {
      await sendHeader(response, response.body.length);
      for (let offset = 0; offset < response.body.length; offset += 65536) {
        await send(response.body.slice(offset, offset + 65536).buffer);
      }
    };
    try {
      const file = reply.file;
      if (!file) await sendReply(reply);
      else await streamFile(file.uri, file.meta.size, async () => {
        if (!this.running || !this.isShareActive(reply.shareToken || '')) throw new ProtocolError(410, '分享已关闭或过期');
        await sendHeader(reply, file.meta.size);
        this.log('浏览器下载', file.meta.fileName);
      }, send);
    } catch (e) {
      if (!started) await sendReply(this.errorReply(e as Error));
    } finally { await client.close().catch(() => {}); }
  }

  private claimUpload(head: RequestHead, address: string): Grant {
    return this.sessions.claim(head.query.get('sessionId') || '', head.query.get('fileId') || '', head.query.get('token') || '', address);
  }
  private async route(head: RequestHead, body: Uint8Array, address: string,
    connected: () => boolean = () => true): Promise<Reply> {
    if (this.discoveryOnly && !(head.method === 'GET' && head.path.startsWith('/s/'))) {
      return this.reply(404, '请使用完整分享链接');
    }
    const prefix = '/api/localsend/v2';
    if (head.method === 'GET' && head.path === `${prefix}/info`) {
      if (!this.visibility.isPublic()) throw new ProtocolError(403, '仅连接过的设备');
      return this.reply(200, JSON.stringify(this.info), 'application/json');
    }
    if (head.method === 'POST' && head.path === `${prefix}/register`) {
      const info = JSON.parse(this.decode(body)) as DeviceInfo;
      if (!validInfo(info)) throw new ProtocolError(400, '设备信息无效');
      const verified = await this.verified(info, 'register');
      if (!verified && !this.visibility.isPublic()) throw new ProtocolError(403, '仅连接过的设备');
      if (verified || !this.visibility.get(info.fingerprint)?.secret) this.remember(info, address);
      return this.reply(200, JSON.stringify(verified ? await this.identity(info.fingerprint, 'register-response') : this.info), 'application/json');
    }
    if (head.method === 'POST' && head.path === `${prefix}/prepare-upload`) {
      if (body.length > METADATA_LIMIT) throw new ProtocolError(413, '元数据过大');
      const offer = JSON.parse(this.decode(body)) as Offer;
      validateOffer(offer);
      const fingerprint = offer.info.fingerprint;
      const known = await this.verified(offer.info, 'prepare-upload') ? this.visibility.get(fingerprint) : undefined;
      const trustedSecret = known?.secret || '';
      if (!trustedSecret && !this.visibility.isPublic()) throw new ProtocolError(403, '仅连接过的设备');
      const automatic = !!trustedSecret && known?.autoReceive === true;
      const revision = this.visibility.revision;
      const stillAuthorized = (): boolean => revision === this.visibility.revision &&
        (trustedSecret ? this.visibility.get(fingerprint)?.secret === trustedSecret : this.visibility.isPublic());
      if (this.pending) throw new ProtocolError(409, '正在等待另一个传输确认');
      let approved: ReceiveDecision = true;
      const until = Date.now() + 90000;
      this.pending = true;
      try {
        if (!automatic) {
          if (!await this.waitForForeground(offer, Math.min(until, Date.now() + 45000))) {
            throw new ProtocolError(409, '请先在接收设备打开邻传确认传输');
          }
          if (!this.running || !connected() || !stillAuthorized()) throw new ProtocolError(403, '接收请求已失效');
          approved = await this.onOffer(offer, Math.max(0, until - Date.now()));
        }
        if (!approved || !this.running || !connected()) throw new ProtocolError(403, '已拒绝传输');
        if (!stillAuthorized()) throw new ProtocolError(403, '接收授权已改变，请重试');
        // Acquire the system task before replying: upload bytes can arrive while the app is backgrounded.
        try { await this.background?.begin(); }
        catch (e) {
          if (!this.backgrounded || !await this.waitForForeground(offer, Math.min(until, Date.now() + 45000), automatic)) throw e as Error;
          if (!this.running || !connected() || !stillAuthorized()) throw new ProtocolError(403, '接收请求已失效');
          await this.background?.begin();
        }
      } finally {
        this.pending = false;
      }
      let sessionId = '';
      try {
        if (!this.running || !connected() || !stillAuthorized()) throw new ProtocolError(403, '接收授权已改变，请重试');
        const prepared = this.sessions.create(offer, address, () => this.id());
        sessionId = prepared.sessionId;
        const senderName = this.deviceName(offer.info);
        const session = this.sessions.sessions.get(sessionId);
        if (session) session.sender = senderName;
        const secret = trustedSecret || (offer.info.quickSender === 1 ? this.id() + this.id() : '');
        if (offer.info.quickSender === 1) prepared.pairSecret = secret;
        this.visibility.connect(offer.info, address, secret, Date.now(), approved === 'always');
        this.persist();
        this.receiveTasks.add(sessionId);
        this.updateTransferActivity();
        if (automatic) {
          const count = Object.keys(offer.files).length;
          this.automaticNotices.set(sessionId, this.notices.automaticReceive(senderName, count));
          this.log('自动接收', `${senderName} · ${count} 个文件`, true);
        }
        else this.onChange();
        return this.reply(200, JSON.stringify(prepared), 'application/json');
      } catch (e) {
        if (sessionId) this.sessions.sessions.delete(sessionId);
        await this.background?.end();
        throw e as Error;
      }
    }
    if (head.method === 'POST' && head.path === `${prefix}/cancel`) {
      const id = head.query.get('sessionId') || '';
      this.sessions.cancel(id, address);
      await this.cancelReceive(id);
      return this.reply(200, '');
    }
    if (head.method === 'GET' && head.path.startsWith('/s/')) {
      const parts = head.path.split('/');
      const share = this.browserShares.get(parts[2]);
      if (!share || Date.now() >= share.expires) throw new ProtocolError(410, '分享已关闭或过期');
      if (parts.length === 3) {
        const links = share.files.map(f => `<a href="/s/${share.token}/${encodeURIComponent(f.meta.id)}">${escapeHtml(f.meta.fileName)} <small>${(f.meta.size / 1024 / 1024).toFixed(2)} MiB</small></a>`).join('');
        return this.reply(200, `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>邻传 · 临时分享</title><style>body{font:16px system-ui;background:#f3f5fa;color:#17233c;margin:0;padding:8vw}main{max-width:640px;margin:auto;background:white;padding:32px;border-radius:24px}h1{color:#3767eb}a{display:block;padding:18px 0;color:#2455c9;border-bottom:1px solid #eee;text-decoration:none}small{float:right;color:#738099}p{color:#738099;line-height:1.8}</style><main><h1>邻传</h1><h2>来自附近的文件</h2><p>点击文件下载。链接有效至 ${escapeHtml(new Date(share.expires).toLocaleTimeString())}，仅在发送设备服务开启时有效。</p>${links}<p>局域网 HTTP 分享 · 请保持发送设备在前台</p></main></html>`, 'text/html; charset=utf-8');
      }
      const file = parts.length === 4 ? share.files.find(f => f.meta.id === decodeURIComponent(parts[3])) : undefined;
      if (!file) throw new ProtocolError(404, '文件不存在');
      return { status: 200, type: 'application/octet-stream', body: new Uint8Array(0), file, shareToken: share.token };
    }
    return this.reply(404, '请使用完整的邻传分享链接，或通过 LocalSend 连接');
  }
}
