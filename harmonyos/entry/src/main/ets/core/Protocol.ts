export const PORT = 53317;
export const GROUP = '224.0.0.167';
export const METADATA_LIMIT = 65536;
export const SESSION_TTL = 10 * 60 * 1000;

import { DiscoveryProof } from './Visibility';

export interface DeviceInfo {
  alias: string;
  version: string;
  deviceModel: string;
  deviceType: string;
  fingerprint: string;
  port: number;
  protocol: string;
  download: boolean;
  announce?: boolean;
  quickSender?: number;
  proof?: DiscoveryProof;
}
export interface Peer { info: DeviceInfo; address: string; seen: number; publicDiscovery?: boolean; }
export interface FileMeta { id: string; fileName: string; size: number; fileType: string; sha256?: string; }
export interface Offer { info: DeviceInfo; files: Record<string, FileMeta>; }
export interface Prepared { sessionId: string; files: Record<string, string>; pairSecret?: string; }
export interface Grant { meta: FileMeta; token: string; busy: boolean; done: boolean; received: number; }
export interface ReceiveSession { id: string; address: string; sender: string; expires: number; grants: Map<string, Grant>; }

export class ProtocolError extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

export function safeName(name: string): string {
  if (typeof name !== 'string' || name.length === 0 || name.length > 240 || /[\\/\x00-\x1f]/.test(name) || name === '.' || name === '..') {
    throw new ProtocolError(400, '文件名无效');
  }
  return name;
}

export function validInfo(info: DeviceInfo): boolean {
  return !!info && typeof info.alias === 'string' && info.alias.length <= 120 &&
    typeof info.fingerprint === 'string' && info.fingerprint.length > 0 && info.fingerprint.length <= 256 &&
    typeof info.version === 'string' && info.version.startsWith('2.') &&
    Number.isInteger(info.port) && info.port > 0 && info.port <= 65535 &&
    (info.protocol === 'http' || info.protocol === 'https');
}

export function validateOffer(offer: Offer): FileMeta[] {
  if (!offer || !validInfo(offer.info) || !offer.files || Array.isArray(offer.files)) throw new ProtocolError(400, '无效的传输请求');
  const keys = Object.keys(offer.files);
  if (keys.length < 1 || keys.length > 20) throw new ProtocolError(400, '一次最多 20 个文件');
  const result: FileMeta[] = [];
  for (const key of keys) {
    const f = offer.files[key];
    if (!f || f.id !== key || key.length > 256 || !Number.isSafeInteger(f.size) || f.size < 0 ||
      typeof f.fileType !== 'string' || f.fileType.length > 256 || (f.sha256 !== undefined && f.sha256 !== null && !/^[a-f0-9]{64}$/i.test(f.sha256))) {
      throw new ProtocolError(400, '无效的文件信息');
    }
    safeName(f.fileName);
    result.push(f);
  }
  return result;
}

export class SessionStore {
  sessions: Map<string, ReceiveSession> = new Map();
  create(offer: Offer, address: string, randomId: () => string, now: number = Date.now()): Prepared {
    const metas = validateOffer(offer);
    this.prune(now);
    if (this.sessions.size >= 8) throw new ProtocolError(429, '传输会话过多');
    const id = randomId();
    const grants: Map<string, Grant> = new Map();
    const files: Record<string, string> = {};
    for (const meta of metas) {
      const token = randomId();
      grants.set(meta.id, { meta, token, busy: false, done: false, received: 0 });
      Object.defineProperty(files, meta.id, { value: token, enumerable: true, configurable: true });
    }
    this.sessions.set(id, { id, address, sender: offer.info.alias, expires: now + SESSION_TTL, grants });
    return { sessionId: id, files };
  }
  claim(id: string, fileId: string, token: string, address: string, now: number = Date.now()): Grant {
    this.prune(now);
    const session = this.sessions.get(id);
    const grant = session?.grants.get(fileId);
    if (!session || !grant || session.address !== address || grant.token !== token) throw new ProtocolError(403, '传输凭据已失效');
    if (grant.busy || grant.done) throw new ProtocolError(409, '文件正在传输或已经完成');
    grant.busy = true;
    session.expires = now + SESSION_TTL;
    return grant;
  }
  cancel(id: string, address: string): void {
    const s = this.sessions.get(id);
    if (!s || s.address !== address) throw new ProtocolError(403, '无效的会话');
    this.sessions.delete(id);
  }
  prune(now: number): void {
    this.sessions.forEach((s, id) => {
      if (s.expires <= now && !Array.from(s.grants.values()).some(grant => grant.busy)) this.sessions.delete(id);
    });
  }
}

export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
