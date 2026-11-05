const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const Module = require('node:module');
const { EventEmitter } = require('node:events');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript');
for (const ext of ['.ts', '.ets']) require.extensions[ext] = (mod, name) => {
  mod._compile(ts.transpileModule(fs.readFileSync(name, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText, name);
};
const prefStores = new Map();
const native = {
  '@kit.NetworkKit': { socket: {}, http: { RequestMethod: { POST: 'POST', GET: 'GET' }, HttpDataType: { STRING: 1 } }, connection: {} },
  '@kit.CoreFileKit': { fileIo: {} },
  '@kit.AbilityKit': { UIAbility: class {}, ShareExtensionAbility: class {} },
  '@kit.PerformanceAnalysisKit': { hilog: { error() {}, info() {}, warn() {} } },
  '@kit.ArkUI': {},
  '@kit.ShareKit': { systemShare: { getSharedData: async want => ({ getRecords: () => want.records || [] }) } },
  '@kit.BackgroundTasksKit': { backgroundTaskManager: {} },
  '@kit.NotificationKit': { notificationManager: { SlotType: { SOCIAL_COMMUNICATION: 1, SERVICE_INFORMATION: 2, CONTENT_INFORMATION: 3 } } },
  '@kit.BasicServicesKit': { deviceInfo: { productModel: 'Test', deviceType: 'phone' } },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
    TextDecoder: { create: () => ({ decodeWithStream: b => new TextDecoder().decode(b) }) }
  } },
  '@kit.ArkData': { preferences: { getPreferences: async context => {
    if (!prefStores.has(context)) {
      const values = new Map();
      prefStores.set(context, { getSync: (k, d) => values.has(k) ? values.get(k) : d, putSync: (k, v) => values.set(k, v), flushSync() {} });
    }
    return prefStores.get(context);
  } } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: {
    createSymKeyGenerator: alg => { assert.equal(alg, 'HMAC'); return { convertKey: async blob => blob.data }; },
    createMac: alg => {
      assert.equal(alg, 'SHA256'); let hmac;
      return { init: async key => { hmac = crypto.createHmac('sha256', key); }, update: async blob => hmac.update(blob.data), doFinal: async () => ({ data: hmac.digest() }) };
    }
  } }
};
const originalLoad = Module._load;
Module._load = function(name, ...rest) { return native[name] || originalLoad.call(this, name, ...rest); };
const base = '../entry/src/main/ets/';
const { Visibility, PUBLIC_DURATION } = require(base + 'core/Visibility.ts');
const { TransferService } = require(base + 'services/TransferService.ets');
const { TransferNotifications } = require(base + 'services/TransferNotifications.ets');
const { HttpParser } = require(base + 'core/HttpParser.ts');
const EntryAbility = require(base + 'entryability/EntryAbility.ets').default;
const { Runtime } = require(base + 'services/Runtime.ets');
const { ShareSession } = require(base + 'services/ShareSession.ets');
const QuickShareExtension = require(base + 'entryability/QuickShareExtension.ets').default;
const info = fp => ({ alias: fp, fingerprint: fp, version: '2.1', port: 53317, protocol: 'http', deviceModel: 'test', deviceType: 'mobile', download: false, quickSender: 1 });
const offer = device => ({ info: device, files: { file: { id: 'file', fileName: 'test.txt', size: 1, fileType: 'text/plain' } } });
const head = (path, method = 'POST') => ({ path: '/api/localsend/v2/' + path, method, query: new Map(), length: 0, expect: false });
const body = value => new TextEncoder().encode(JSON.stringify(value));
async function service(context = {}) {
  const s = new TransferService(context); await s.initialize(); s.running = true;
  s.background = { begin: async () => {}, end: async () => {}, progress() {} };
  return s;
}

test('完成通知保留，撤销临时链接只移除对应提醒', async t => {
  const kit = native['@kit.NotificationKit'].notificationManager;
  const ability = native['@kit.AbilityKit'];
  const requests = [];
  const cancelled = [];
  kit.ContentType = { NOTIFICATION_CONTENT_BASIC_TEXT: 0 };
  kit.publish = async request => { requests.push(request); };
  kit.cancel = async id => { cancelled.push(id); };
  ability.wantAgent = {
    OperationType: { START_ABILITY: 0 },
    WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 },
    getWantAgent: async () => { throw Error('agent unavailable'); }
  };
  t.after(() => {
    delete kit.ContentType;
    delete kit.publish;
    delete kit.cancel;
    delete ability.wantAgent;
  });
  const notices = new TransferNotifications();
  const expires = Date.now() + 600000;
  await notices.shareActive('first', 1, expires);
  await notices.complete('接收完成', 2, '电脑');
  await notices.shareActive('second', 3, expires);
  notices.closeShare('first');
  assert.equal(requests.length, 3);
  assert.equal(requests[0].autoDeletedTime, expires);
  assert.equal(requests[1].autoDeletedTime, undefined);
  assert.equal(requests[1].tapDismissed, true);
  assert.deepEqual(cancelled, [requests[0].id]);
  assert.equal(new Set(requests.map(request => request.id)).size, 3);
  const auto = await notices.automaticReceive('电脑', 2);
  await notices.completeAutomatic(auto, '电脑', 2);
  assert.deepEqual(requests.slice(3).map(request => [
    request.id, request.notificationSlotType, request.content.normal.title, request.autoDeletedTime
  ]), [[auto, kit.SlotType.CONTENT_INFORMATION, '已自动接受分享', undefined],
    [auto, kit.SlotType.CONTENT_INFORMATION, '自动接收完成', undefined]]);
});

test('图库独立窗口发送的记录可在主应用查看，删除后重启也不会恢复', async t => {
  const filesDir = fs.mkdtempSync(path.join(os.tmpdir(), 'linchuan-history-'));
  const fileIo = native['@kit.CoreFileKit'].fileIo;
  const io = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    mkdirSync: directory => fs.mkdirSync(directory, { recursive: true }),
    statSync: fs.statSync,
    openSync: target => ({ fd: fs.openSync(target, 'w') }),
    writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes)),
    closeSync: file => fs.closeSync(file.fd),
    renameSync: fs.renameSync,
    unlinkSync: fs.unlinkSync,
    listFileSync: fs.readdirSync,
    readTextSync: target => fs.readFileSync(target, 'utf8')
  };
  Object.assign(fileIo, io);
  t.after(() => {
    for (const key of Object.keys(io)) delete fileIo[key];
    const historyDir = path.join(filesDir, 'transfer-history');
    if (fs.existsSync(historyDir)) {
      for (const name of fs.readdirSync(historyDir)) fs.unlinkSync(path.join(historyDir, name));
      fs.rmdirSync(historyDir);
    }
    fs.rmdirSync(filesDir);
  });
  const main = await service({ filesDir: path.join(filesDir, 'entry'), getApplicationContext: () => ({ filesDir }) });
  const share = new TransferService({ filesDir }, true);
  await share.initialize();
  share.running = true;
  const device = info('我的电脑');
  const file = { meta: offer(device).files.file, uri: 'file://from-gallery' };
  share.request = async () => JSON.stringify({ sessionId: 'session', files: { file: 'token' } });
  share.uploadToPeer = async (_peer, _path, _file, _task, onBytes) => onBytes(file.meta.size);
  await share.send({ info: device, address: 'ip', seen: Date.now() }, [file], true);
  main.refreshHistory();
  assert.deepEqual(main.events.map(({ name, detail }) => [name, detail]),
    [['发送完成', 'test.txt · 发给 我的电脑']]);
  main.removeEvent(main.events[0].id);
  assert.deepEqual((await service({ filesDir })).events, []);
});

test('按编号删除单条传输记录，保留内容相同的其他记录', async () => {
  const s = await service();
  s.log('接收完成', '同名文件.txt');
  s.log('接收完成', '同名文件.txt');
  const [newer, older] = s.events;
  assert.notEqual(newer.id, older.id);
  s.removeEvent(older.id);
  assert.deepEqual(s.events, [newer]);
});

test('分享窗口独立选文件，复用现有发现服务且关闭时保留主界面', async () => {
  const context = {};
  const existing = Runtime.get(context);
  existing.running = true;
  existing.files = [{ uri: 'file://main' }];
  existing.prepareFiles = async uris => uris.map(uri => ({ uri }));
  existing.refresh = async () => {};
  let resultCode;
  let sent;
  existing.send = async (peer, files, foregroundOnly) => { sent = { peer, files, foregroundOnly }; };
  const model = new ShareSession(context, { records: [{ uri: 'file://photo' }, { uri: 'file://photo' }] },
    { terminateSelfWithResult: async result => { resultCode = result.resultCode; } });
  try {
    await model.start();
    const peer = { info: info('receiver'), address: '192.168.1.3', seen: Date.now() };
    await model.send(peer);
    assert.deepEqual(sent, { peer, files: [{ uri: 'file://photo' }], foregroundOnly: true });
    assert.deepEqual(existing.files, [{ uri: 'file://main' }]);
    await model.finish(true);
    await model.dispose();
    assert.equal(resultCode, 0);
    assert.equal(existing.running, true);
  } finally { await Runtime.destroy(); }
});

test('发现服务空闲时不发送探测，分享窗口按需扫描且关闭时释放组播', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'setTimeout'] });
  const kit = native['@kit.NetworkKit'];
  let closed = false;
  const packets = [];
  kit.connection.getDefaultNet = async () => ({});
  kit.connection.getConnectionProperties = async () => ({ linkAddresses: [{ address: { address: '192.168.1.2' } }] });
  kit.socket.constructTCPSocketServerInstance = () => assert.fail('分享窗口不应启动接收服务');
  kit.socket.constructMulticastSocketInstance = () => ({ setExtraOptions: async () => {}, on: () => {}, bind: async () => {},
    addMembership: async () => {}, send: async packet => packets.push(JSON.parse(packet.data)), close: async () => { closed = true; } });
  const isolated = new TransferService({}, true);
  try {
    await isolated.initialize();
    isolated.visibility.open();
    await isolated.start();
    t.mock.timers.tick(20000);
    assert.deepEqual(packets, []);
    await isolated.refresh();
    assert.deepEqual(packets, [{ quickSenderQuery: 1 }]);
    assert.equal(isolated.searching, true);
    await isolated.refresh();
    t.mock.timers.tick(3999);
    assert.equal(isolated.searching, true);
    t.mock.timers.tick(1);
    assert.equal(isolated.searching, false);
    t.mock.timers.tick(20000);
    assert.equal(isolated.searching, false);
    assert.equal(packets.length, 1);
  } finally { await isolated.stop(); }
  assert.equal(closed, true);
});

test('分享窗口使用应用上下文，页面存储只传会话编号', async () => {
  const applicationContext = {};
  const extension = new QuickShareExtension();
  extension.context = { getApplicationContext: () => applicationContext };
  const previous = global.LocalStorage;
  global.LocalStorage = class {
    setOrCreate(key, value) { this[key] = value; }
  };
  let id;
  const content = {
    loadContent(page, storage) {
      assert.equal(page, 'pages/SharePanel');
      assert.equal(typeof storage.shareSessionId, 'number');
      assert.deepEqual(Object.keys(storage), ['shareSessionId']);
      id = storage.shareSessionId;
    }
  };
  try {
    extension.onSessionCreate({ records: [] }, content);
    assert.equal(ShareSession.get(id).context, applicationContext);
    extension.onSessionDestroy(content);
    assert.equal(ShareSession.get(id), undefined);
  } finally { global.LocalStorage = previous; }
});

test('搜索期间保留在线设备，结束后移除未重新响应的已连接设备', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const s = await service();
  const responsive = info('responsive');
  const silent = info('silent');
  s.visibility.connect(responsive, 'a', 'secret-a');
  s.visibility.connect(silent, 'b', 'secret-b');
  s.remember(responsive, 'a');
  s.remember(silent, 'b');
  s.request = async () => { throw new Error('no response'); };

  await s.refresh();
  assert.equal(s.peers.length, 2);
  s.remember(responsive, 'a');
  t.mock.timers.tick(3999);
  assert.equal(s.peers.length, 2);
  t.mock.timers.tick(1);
  assert.deepEqual(s.peers.map(peer => peer.info.fingerprint), ['responsive']);
});

test('分享窗口链接只包含本次文件，撤销不影响主界面的链接', async () => {
  const s = await service();
  s.ip = '192.168.1.2';
  s.browserPort = 53317;
  s.files = [{ uri: 'file://main', meta: { id: 'main', fileName: 'main.txt', size: 3 } }];
  const main = new URL(s.startShare()).pathname;
  const selected = [{ uri: 'file://photo', meta: { id: 'photo', fileName: 'photo.jpg', size: 3 } }];
  const link = await s.createWindowLink(selected);
  const windowPath = new URL(link.url).pathname;
  const page = { ...head('', 'GET'), path: windowPath };
  const response = await s.route(page, body({}), '192.168.1.3');
  const html = new TextDecoder().decode(response.body);
  assert.match(html, /photo\.jpg/);
  assert.doesNotMatch(html, /main\.txt/);
  s.revokeShare(link.token);
  await assert.rejects(s.route(page, body({}), '192.168.1.3'), e => e.status === 410);
  assert.equal((await s.route({ ...page, path: main }, body({}), '192.168.1.3')).status, 200);
});

test('多条临时链接保留各自的文件，撤销单条链接不影响其他链接', async () => {
  const s = await service(); s.ip = '192.168.1.2'; s.browserPort = 53317;
  const pathFor = name => ({ uri: `file://${name}`, meta: { id: name, fileName: name, size: 1 } });
  s.files = [pathFor('one.txt')];
  const first = new URL(s.startShare()).pathname;
  s.removeFile('one.txt');
  s.files = [pathFor('two.txt')];
  const second = new URL(s.startShare()).pathname;
  assert.deepEqual(s.activeShares().map(share => share.fileNames), [['two.txt'], ['one.txt']]);
  const get = path => s.route({ ...head('', 'GET'), path }, body({}), 'ip');
  assert.match(new TextDecoder().decode((await get(first)).body), /one\.txt/);
  s.revokeShare(s.activeShares()[0].token);
  await assert.rejects(get(second), e => e.status === 410);
  assert.equal((await get(first)).status, 200);
});

test('默认仅连接过的设备；窗口到期精确恢复，重复开启不延长', () => {
  const v = new Visibility(); assert.equal(v.isPublic(1000), false);
  v.open(1000); v.open(3000); assert.equal(v.publicUntil, 1000 + PUBLIC_DURATION);
  assert.equal(v.remaining(1000), 600); assert.equal(v.isPublic(1000 + PUBLIC_DURATION - 1), true);
  assert.equal(v.isPublic(1000 + PUBLIC_DURATION), false);
  v.close(); assert.equal(v.isPublic(2000), false);
});
test('重启恢复原始到期时间，过期或非法时间不能重新开放', () => {
  const v = new Visibility(); v.open(1000);
  const restored = new Visibility(); restored.restore(v.snapshot(), 2000);
  assert.equal(restored.publicUntil, 601000); assert.equal(restored.remaining(2000), 599);
  restored.restore(v.snapshot(), 601000); assert.equal(restored.isPublic(601000), false);
  restored.restore({ publicUntil: Infinity, devices: [] }, 2000); assert.equal(restored.isPublic(2000), false);
});
test('稳定身份和连接记录跨实例保留，删除也持久化', async () => {
  const context = {}; const a = await service(context);
  a.visibility.connect(info('peer'), '192.168.1.2', 'secret'); a.persist();
  const b = await service(context); assert.equal(a.info.fingerprint, b.info.fingerprint);
  assert.equal(b.visibility.devices.length, 1); b.forgetDevice('peer');
  const c = await service(context); assert.equal(c.visibility.devices.length, 0);
});

test('设备别名跨重连和重启保留，清空后使用最新设备名称', async () => {
  const context = {};
  const s = await service(context);
  const peer = info('peer');
  s.visibility.connect(peer, 'ip', 'secret');
  const revision = s.visibility.revision;
  s.setNickname(peer.fingerprint, ' 我的电脑 ');
  assert.equal(s.visibility.revision, revision);
  const renamedPeer = { ...peer, alias: '新设备名' };
  s.visibility.connect(renamedPeer, 'ip', 'secret');
  s.persist();
  const restored = await service(context);
  assert.equal(restored.deviceName(renamedPeer), '我的电脑');
  assert.equal(restored.visibility.get(peer.fingerprint).secret, 'secret');
  restored.setNickname(peer.fingerprint, '  ');
  assert.equal((await service(context)).deviceName(renamedPeer), '新设备名');
});
test('受限模式只匿名搜索，不泄露设备信息或响应陌生注册', async () => {
  const s = await service(); const packets = [];
  s.udp = { send: async message => packets.push(JSON.parse(message.data)) }; await s.refresh();
  assert.deepEqual(packets, [{ quickSenderQuery: 1 }]);
  await s.receiveDiscovery('{"quickSenderQuery":1}', '192.168.1.2');
  assert.equal(packets.length, 1);
  await assert.rejects(s.route(head('info', 'GET'), body({}), '192.168.1.2'), e => e.status === 403);
  await assert.rejects(s.route(head('register'), body(info('stranger')), '192.168.1.2'), e => e.status === 403);
  assert.equal(s.peers.length, 0);
  s.finishSearch();
});
test('所有人可见允许发现但不会把发现当成连接记录', async () => {
  const s = await service(); s.openVisibility();
  assert.equal((await s.route(head('register'), body(info('stranger')), '192.168.1.2')).status, 200);
  assert.equal(s.peers.length, 1); assert.equal(s.visibility.devices.length, 0);
  s.closeVisibility(); assert.equal(s.peers.length, 0);
});
test('只有接收方公开时，发送方仍能发现并发起首次发送', async () => {
  const sender = await service(); const receiver = await service();
  receiver.openVisibility();
  receiver.udp = { send: async packet => sender.receiveDiscovery(packet.data, '192.168.1.3') };
  sender.udp = { send: async packet => receiver.receiveDiscovery(packet.data, '192.168.1.2') };
  await sender.refresh();
  assert.equal(sender.peers[0].info.fingerprint, receiver.info.fingerprint);
  assert.equal(receiver.peers.length, 0);
  sender.closeVisibility(); assert.equal(sender.peers.length, 1);
  receiver.onOffer = async () => true;
  sender.files = [{ uri: 'file://test', meta: offer(sender.info).files.file }];
  sender.uploadToPeer = async (_peer, _path, file, _task, onBytes) => onBytes(file.meta.size);
  sender.request = async (url, payload) => url.endsWith('/prepare-upload')
    ? new TextDecoder().decode((await receiver.route(head('prepare-upload'), body(JSON.parse(payload)), '192.168.1.2')).body) : '';
  await sender.send(sender.peers[0]);
  assert.equal(sender.events[0].name, '发送完成');
  assert.equal(sender.visibility.isPublic(), false);
  assert.ok(sender.visibility.get(receiver.info.fingerprint)?.secret);
  sender.finishSearch();
});
test('陌生设备在受限模式下不能弹出接收确认', async () => {
  const s = await service(); let prompts = 0; s.onOffer = async () => { prompts++; return true; };
  await assert.rejects(s.route(head('prepare-upload'), body(offer(info('stranger'))), 'ip'), e => e.status === 403);
  assert.equal(prompts, 0);
});
test('自动接收必须明确授权并验证配对凭据，关闭后恢复确认', async () => {
  const a = await service(); const b = await service();
  b.openVisibility();
  b.onOffer = async () => 'always';
  const reply = await b.route(head('prepare-upload'), body(offer(a.info)), 'a');
  const prepared = JSON.parse(new TextDecoder().decode(reply.body));
  a.visibility.connect(b.info, 'b', prepared.pairSecret);
  assert.equal(b.visibility.get(a.info.fingerprint).autoReceive, true);
  let prompts = 0;
  const autoNotices = [];
  b.notices.automaticReceive = async (...details) => { autoNotices.push(details); return 1; };
  b.onOffer = async () => { prompts++; return false; };
  await assert.rejects(b.route(head('prepare-upload'), body(offer(a.info)), 'a'), e => e.status === 403);
  assert.equal(prompts, 1);
  b.closeVisibility();
  const signed = await a.identity(b.info.fingerprint, 'prepare-upload');
  assert.equal((await b.route(head('prepare-upload'), body(offer(signed)), 'a')).status, 200);
  assert.equal(prompts, 1);
  b.setAutoReceive(a.info.fingerprint, false);
  const next = await a.identity(b.info.fingerprint, 'prepare-upload');
  await assert.rejects(b.route(head('prepare-upload'), body(offer(next)), 'a'), e => e.status === 403);
  assert.equal(prompts, 2);
  assert.equal(autoNotices.length, 1);
  b.setAutoReceive(a.info.fingerprint, true);
  const afterOptIn = await a.identity(b.info.fingerprint, 'prepare-upload');
  assert.equal((await b.route(head('prepare-upload'), body(offer(afterOptIn)), 'a')).status, 200);
  assert.equal(prompts, 2);
  assert.equal(autoNotices.length, 2);
});
test('拒绝连接不留记录；确认连接生成独立凭据并持久化', async () => {
  const s = await service(); s.openVisibility();
  s.onOffer = async () => false;
  await assert.rejects(s.route(head('prepare-upload'), body(offer(info('a'))), 'ip'), e => e.status === 403);
  assert.equal(s.visibility.devices.length, 0);
  s.onOffer = async () => true;
  const prepared = JSON.parse(new TextDecoder().decode((await s.route(head('prepare-upload'), body(offer(info('a'))), 'ip')).body));
  assert.ok(prepared.sessionId); assert.ok(prepared.pairSecret);
  assert.equal(s.visibility.get('a').secret, prepared.pairSecret);
});
test('确认期间结束可见性或删除设备，旧请求不能恢复授权', async () => {
  const s = await service(); s.openVisibility();
  s.onOffer = async () => { s.closeVisibility(); return true; };
  await assert.rejects(s.route(head('prepare-upload'), body(offer(info('a'))), 'ip'), e => e.status === 403);
  assert.equal(s.visibility.devices.length, 0);
});
test('已连接设备经认证定向发现，支持双方均处于受限模式', async () => {
  const a = await service(); const b = await service();
  a.visibility.connect(b.info, 'b', 'shared-secret'); b.visibility.connect(a.info, 'a', 'shared-secret');
  a.request = async (url, payload) => new TextDecoder().decode((await b.route(head('register'), body(JSON.parse(payload)), 'a')).body);
  await a.discoverKnown(b.info.fingerprint, 'b');
  assert.equal(a.peers.length, 1); assert.equal(b.peers.length, 1);
  assert.equal(a.visibility.isPublic(), false); assert.equal(b.visibility.isPublic(), false);
});
test('伪造指纹、错误凭据、重放和删除后的凭据均被拒绝', async () => {
  const a = await service(); const b = await service();
  a.visibility.connect(b.info, 'b', 'secret'); b.visibility.connect(a.info, 'a', 'secret');
  await assert.rejects(b.route(head('register'), body(a.info), 'a'), e => e.status === 403);
  const signed = await a.identity(b.info.fingerprint, 'register');
  assert.equal((await b.route(head('register'), body(signed), 'a')).status, 200);
  await assert.rejects(b.route(head('register'), body(signed), 'a'), e => e.status === 403);
  const fresh = await a.identity(b.info.fingerprint, 'register'); b.forgetDevice(a.info.fingerprint);
  await assert.rejects(b.route(head('register'), body(fresh), 'a'), e => e.status === 403);
});
test('认证凭据绑定请求用途，不能从发现接口挪到传输接口', async () => {
  const a = await service(); const b = await service();
  a.visibility.connect(b.info, 'b', 'secret'); b.visibility.connect(a.info, 'a', 'secret');
  const signed = await a.identity(b.info.fingerprint, 'register');
  await assert.rejects(b.route(head('prepare-upload'), body(offer(signed)), 'a'), e => e.status === 403);
});
test('LocalSend 记录不作为可信认证凭据，仅开放窗口中可连接', async () => {
  const s = await service(); s.visibility.connect(info('legacy'), 'ip', '');
  s.setAutoReceive('legacy', true);
  assert.equal(s.visibility.get('legacy').autoReceive, false);
  await assert.rejects(s.route(head('register'), body(info('legacy')), 'ip'), e => e.status === 403);
  s.openVisibility(); assert.equal((await s.route(head('register'), body(info('legacy')), 'ip')).status, 200);
});
test('后台请求通知后回到前台确认，确认前不启动后台传输', async () => {
  const s = await service(); s.openVisibility(); s.setForeground(false);
  let confirmed = false;
  let tasks = 0;
  let cleared = false;
  let notify;
  const notified = new Promise(resolve => notify = resolve);
  s.notices = { incoming: async () => { notify(); return true; }, clearIncoming: async () => { cleared = true; } };
  s.background.begin = async () => { tasks++; };
  s.onOffer = async () => { confirmed = true; return true; };
  const pending = s.route(head('prepare-upload'), body(offer(info('a'))), 'ip');
  await notified;
  assert.equal(confirmed, false);
  assert.equal(tasks, 0);
  assert.equal(s.visibility.devices.length, 0);
  s.setForeground(true);
  assert.equal((await pending).status, 200);
  assert.equal(confirmed, true);
  assert.equal(tasks, 1);
  assert.equal(cleared, true);
});

test('通知不可用时，连接请求在后台不静默接收', async () => {
  const s = await service(); s.openVisibility(); s.setForeground(false);
  await assert.rejects(s.route(head('prepare-upload'), body(offer(info('a'))), 'ip'), e => e.status === 409);
  assert.equal(s.visibility.devices.length, 0);
});

test('接收实况进度来自已授权的分包字节，全部写入后才通知完成', async () => {
  const s = await service({ filesDir: '/test' }); s.openVisibility(); s.onOffer = async () => true;
  s.history.save = () => false;
  const progress = [];
  const completions = [];
  let released = 0;
  s.background.progress = (_title, _text, percentage) => progress.push(percentage);
  s.background.end = async () => { released++; };
  s.notices.complete = async (...event) => { completions.push(event); };
  const proposed = offer(info('sender'));
  const block = new Uint8Array(256 * 1024);
  proposed.files.file.size = 34 * 1024 * 1024;
  const response = await s.route(head('prepare-upload'), body(proposed), 'ip');
  const prepared = JSON.parse(new TextDecoder().decode(response.body));
  const socket = new EventEmitter();
  const replies = [];
  let done;
  const finished = new Promise(resolve => done = resolve);
  socket.clientId = 1;
  socket.send = async value => { replies.push(value.data); };
  socket.close = async () => { socket.emit('close'); done(); };
  const fileIo = native['@kit.CoreFileKit'].fileIo;
  let written = 0;
  let committed = false;
  Object.assign(fileIo, { OpenMode: { CREATE: 1, READ_WRITE: 2 }, mkdirSync() { throw new Error('File exists'); },
    statSync: () => ({ isDirectory: () => true }), openSync: () => ({ fd: 1 }),
    writeSync: (_, bytes) => { assert.ok(bytes.byteLength <= block.byteLength); written += bytes.byteLength; return bytes.byteLength; },
    closeSync() {}, renameSync() { committed = true; }, unlinkSync() {} });
  const emit = data => socket.emit('message', { message: data.buffer, remoteInfo: { address: 'ip' } });
  try {
    s.setForeground(false);
    s.accept(socket);
    emit(new TextEncoder().encode(`POST /api/localsend/v2/upload?sessionId=${prepared.sessionId}&fileId=file&token=${prepared.files.file} HTTP/1.1\r\nContent-Length: ${proposed.files.file.size}\r\n\r\n`));
    const blocks = proposed.files.file.size / block.length;
    for (let i = 0; i < blocks / 2; i++) emit(block);
    assert.equal(progress.at(-1), 50);
    assert.equal(completions.length, 0);
    assert.equal(committed, false);
    for (let i = blocks / 2; i < blocks; i++) emit(block);
    await finished;
    assert.match(replies[0], /^HTTP\/1\.1 200 /);
    assert.deepEqual(completions, [['接收完成', 1, 'sender']]);
    assert.equal(written, proposed.files.file.size);
    assert.equal(committed, true);
    assert.equal(released, 1);
  } finally {
    await socket.close();
    for (const key of ['OpenMode', 'mkdirSync', 'statSync', 'openSync', 'writeSync', 'closeSync', 'renameSync', 'unlinkSync']) delete fileIo[key];
  }
});
test('文件已准备的传输会话不因可见性到期而中断', async () => {
  const s = await service(); s.openVisibility(); s.onOffer = async () => true;
  const reply = await s.route(head('prepare-upload'), body(offer(info('a'))), 'ip');
  const p = JSON.parse(new TextDecoder().decode(reply.body)); s.closeVisibility();
  assert.equal(s.sessions.claim(p.sessionId, 'file', p.files.file, 'ip').meta.fileName, 'test.txt');
});
test('系统分享导入替换旧选择；失败保留原选择', async () => {
  const s = await service(); const old = [{ uri: 'old' }]; s.files = old;
  s.addFiles = async uris => { s.files = uris.map(uri => ({ uri })); };
  await s.importSharedFiles(['new']); assert.equal(s.files[0].uri, 'new'); assert.equal(s.shareRevision, 1);
  s.addFiles = async () => { throw new Error('no permission'); };
  await assert.rejects(s.importSharedFiles(['bad'])); assert.equal(s.files[0].uri, 'new');
});
test('HTTP 分包、长度和重复参数检查', () => {
  const p = new HttpParser();
  p.push(Buffer.from('POST /api/localsend/v2/register HTTP/1.1\r\nContent-Length: 2\r\n'));
  assert.equal(p.complete, false); p.push(Buffer.from('\r\n{}')); assert.equal(p.complete, true);
  assert.equal(Buffer.from(p.body()).toString(), '{}');
  assert.throws(() => new HttpParser().push(Buffer.from('GET /?a=1&a=2 HTTP/1.1\r\n\r\n')));
});
test('错误密钥及过期的发现签名被拒绝', async () => {
  const a = await service(); const b = await service();
  a.visibility.connect(b.info, 'b', 'wrong'); b.visibility.connect(a.info, 'a', 'correct');
  const wrong = await a.identity(b.info.fingerprint, 'register');
  await assert.rejects(b.route(head('register'), body(wrong), 'a'), e => e.status === 403);
  a.visibility.connect(b.info, 'b', 'correct');
  const stale = await a.identity(b.info.fingerprint, 'register'); stale.proof.time -= 120000;
  await assert.rejects(b.route(head('register'), body(stale), 'a'), e => e.status === 403);
});
test('删除设备时仍等待确认的请求不能重新写回连接记录', async () => {
  const a = await service(); const b = await service();
  a.visibility.connect(b.info, 'b', 'secret'); b.visibility.connect(a.info, 'a', 'secret');
  b.onOffer = async () => { b.forgetDevice(a.info.fingerprint); return true; };
  const signed = await a.identity(b.info.fingerprint, 'prepare-upload');
  await assert.rejects(b.route(head('prepare-upload'), body(offer(signed)), 'a'), e => e.status === 403);
  assert.equal(b.visibility.devices.length, 0);
});
test('接收会话确认即获取后台任务，取消释放任务且不可重复取消', async () => {
  const s = await service(); let tasks = 0;
  s.background = { begin: async () => tasks++, end: async () => tasks--, progress() {} };
  s.openVisibility(); s.onOffer = async () => true;
  const p = JSON.parse(new TextDecoder().decode((await s.route(head('prepare-upload'), body(offer(info('a'))), 'ip')).body));
  assert.equal(tasks, 1);
  const cancel = head('cancel'); cancel.query.set('sessionId', p.sessionId);
  await assert.rejects(s.route(cancel, body({}), 'wrong-ip'), e => e.status === 403); assert.equal(tasks, 1);
  await s.route(cancel, body({}), 'ip'); assert.equal(tasks, 0);
  await assert.rejects(s.route(cancel, body({}), 'ip'), e => e.status === 403); assert.equal(tasks, 0);
});
test('发送端接收确认后保存双方凭据', async () => {
  const s = await service(); s.openVisibility(); const peer = info('receiver');
  s.files = [{ meta: offer(peer).files.file, uri: 'file://test' }];
  s.uploadToPeer = async (_peer, _path, file, _task, onBytes) => onBytes(file.meta.size);
  let requests = 0;
  s.request = async () => ++requests === 1 ? JSON.stringify({ sessionId: 'session', files: { file: 'token' }, pairSecret: 'paired' }) : '';
  await s.send({ info: peer, address: 'ip', seen: Date.now() });
  assert.equal(s.visibility.get('receiver').secret, 'paired');
  assert.equal(s.events[0].name, '发送完成');
  assert.deepEqual(s.activities(), []);
});

test('本机停止接收只关闭选中会话的连接', async () => {
  const s = await service(); s.openVisibility(); s.onOffer = async () => true;
  const accept = async sender => JSON.parse(new TextDecoder().decode(
    (await s.route(head('prepare-upload'), body(offer(info(sender))), sender)).body)).sessionId;
  const first = await accept('first');
  const second = await accept('second');
  const closed = [];
  s.uploads.set(1, { sessionId: first, close: () => closed.push(1) });
  s.uploads.set(2, { sessionId: second, close: () => closed.push(2) });
  await s.cancelReceive(first);
  assert.deepEqual(closed, [1]);
  assert.deepEqual(s.activities().map(activity => activity.id), [second]);
  assert.equal(s.sessions.sessions.has(first), false);
});

test('大文件分块发送，停止一项只关闭对应设备的连接', async () => {
  const s = await service();
  const kit = native['@kit.NetworkKit'];
  const fileIo = native['@kit.CoreFileKit'].fileIo;
  const sizes = new Map([['one', 10], ['two', 33 * 1024 * 1024 + 1]]);
  const pendingUploads = new Map();
  const destroyed = new Set();
  const remoteCancels = [];
  let ready;
  const uploading = new Promise(resolve => { ready = resolve; });
  Object.assign(fileIo, { OpenMode: { READ_ONLY: 0 }, open: async uri => ({ fd: uri.slice(7) }),
    stat: async fd => ({ size: sizes.get(fd) }), read: async (_fd, buffer, options) => {
      assert.ok(buffer.byteLength <= 256 * 1024);
      return options.length;
    }, close: async () => {} });
  kit.http.createHttp = () => {
    return {
      request: async (url, options) => {
        const target = new URL(url);
        if (target.pathname.endsWith('/prepare-upload')) {
          const ids = Object.keys(JSON.parse(options.extraData).files);
          assert.deepEqual(ids, [target.hostname]);
          return { responseCode: 200, result: JSON.stringify({ sessionId: target.hostname, files: { [ids[0]]: 'token' } }) };
        }
        if (target.pathname.endsWith('/cancel')) {
          remoteCancels.push(target.hostname);
          return { responseCode: 200, result: '' };
        }
        assert.fail('文件内容应通过流式连接发送');
      },
      destroy() {}
    };
  };
  kit.socket.constructTCPSocketInstance = () => {
    const client = new EventEmitter();
    let host;
    let sent = 0;
    client.connect = async options => { host = options.address.address; };
    client.send = async ({ data }) => {
      if (typeof data === 'string') { assert.match(data, new RegExp(`Content-Length: ${sizes.get(host)}\\r\\n`)); return; }
      sent += data.byteLength;
      assert.ok(sent <= sizes.get(host));
      if (sent === sizes.get(host)) {
        pendingUploads.set(host, () => client.emit('message', { message: new TextEncoder().encode('HTTP/1.1 200 OK\r\n\r\n').buffer }));
        if (pendingUploads.size === 2) ready();
      }
    };
    client.close = async () => { destroyed.add(host); client.emit('close'); };
    return client;
  };
  const ids = new Map();
  function send(host) {
    const peer = { info: info(host), address: host, seen: Date.now() };
    s.files = [{ uri: `file://${host}`, meta: { ...offer(peer.info).files.file, id: host, size: sizes.get(host) } }];
    return s.send(peer, s.files, false, id => ids.set(host, id));
  }
  try {
    const a = send('one');
    const b = send('two');
    await uploading;
    assert.equal(s.activities().length, 2);
    s.cancelSend(ids.get('one'));
    await assert.rejects(a, /发送已取消/);
    assert.deepEqual([...destroyed], ['one']);
    assert.deepEqual(remoteCancels, ['one']);
    assert.equal(s.activities()[0].id, ids.get('two'));
    pendingUploads.get('two')();
    await b;
    assert.deepEqual(s.activities(), []);
  } finally {
    delete kit.http.createHttp;
    delete kit.socket.constructTCPSocketInstance;
    for (const key of ['OpenMode', 'open', 'stat', 'read', 'close']) delete fileIo[key];
  }
});
test('系统分享冷启动、热启动均加载文件并去重，普通启动不导入', async () => {
  const ability = new EntryAbility(); ability.context = {};
  const s = Runtime.get(ability.context); await s.initialize();
  const imported = []; s.importSharedFiles = async uris => imported.push(uris);
  ability.onCreate({ action: 'ohos.want.action.sendData', records: [{ uri: 'file://one' }, { uri: 'file://one' }, { content: 'ignored' }] });
  await ability.shares; assert.deepEqual(imported, [['file://one']]);
  ability.onNewWant({ action: 'ohos.want.action.sendData', records: [{ uri: 'file://two' }] });
  await ability.shares; assert.deepEqual(imported[1], ['file://two']);
  ability.onNewWant({ action: 'ohos.want.action.home' }); await ability.shares; assert.equal(imported.length, 2);
  ability.onNewWant({ action: 'ohos.want.action.sendData', records: [{ content: 'text' }] });
  await ability.shares; assert.match(s.status, /请选择/);
});
