import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { streamFile } from './FileBody';

export interface UploadRequest {
  address: string;
  port: number;
  path: string;
  uri: string;
  size: number;
}

export async function uploadFile(request: UploadRequest, setAbort: (abort?: () => void) => void,
  onBytes: (count: number) => void): Promise<void> {
  const client = socket.constructTCPSocketInstance();
  let timer = -1;
  let interrupted = false;
  let replied = false;
  let header = '';
  let fail: (error: Error) => void = () => {};
  let acknowledge: () => void = () => {};
  const failure = new Promise<void>((_resolve, reject) => {
    fail = error => { interrupted = true; reject(error); };
  });
  const response = new Promise<void>(resolve => { acknowledge = resolve; });
  const touch = (): void => {
    clearTimeout(timer);
    timer = setTimeout(() => fail(new Error('已取得接收授权，但上传长时间无响应。请检查两台设备的网络连接后重试。')), 120000);
  };
  client.on('error', () => fail(new Error('文件传输连接中断')));
  client.on('close', () => { if (!replied) fail(new Error('对方提前关闭了传输连接')); });
  client.on('message', message => {
    if (replied || interrupted) return;
    touch();
    header += util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(message.message));
    while (true) {
      const end = header.indexOf('\r\n\r\n');
      if (end < 0 && header.length <= 16384) return;
      const status = end >= 0 && end <= 16384 ? /^HTTP\/1\.[01] (\d{3})(?: |\r)/.exec(header) : null;
      if (!status) { fail(new Error('对方返回了无效的 HTTP 响应')); return; }
      const code = Number(status[1]);
      header = header.slice(end + 4);
      if (code < 200 && code >= 100) continue;
      if (code < 200 || code >= 300) { fail(new Error(`对方拒绝文件传输（HTTP ${code}）`)); return; }
      replied = true;
      acknowledge();
      return;
    }
  });
  const send = async (data: string | ArrayBuffer): Promise<void> => {
    if (interrupted) throw new Error('文件传输已停止');
    await client.send({ data });
    if (interrupted) throw new Error('文件传输已停止');
    touch();
  };
  const run = async (): Promise<void> => {
    await client.connect({ address: { address: request.address, port: request.port, family: 1 }, timeout: 5000 });
    await streamFile(request.uri, request.size, async () => {
      await send(`POST ${request.path} HTTP/1.1\r\nHost: ${request.address}:${request.port}\r\n` +
        `Content-Type: application/octet-stream\r\nContent-Length: ${request.size}\r\nConnection: close\r\n\r\n`);
    }, async chunk => { await send(chunk); onBytes(chunk.byteLength); });
    await response;
  };
  setAbort(() => fail(new Error('发送已取消')));
  touch();
  try { await Promise.race([run(), failure]); }
  finally {
    clearTimeout(timer);
    interrupted = true;
    setAbort(undefined);
    await client.close().catch(() => {});
  }
}
