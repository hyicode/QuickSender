import { DeviceInfo } from './Protocol';

export const PUBLIC_DURATION = 10 * 60 * 1000;
export interface ConnectedDevice {
  fingerprint: string;
  alias: string;
  nickname?: string;
  deviceType: string;
  address: string;
  port: number;
  lastConnected: number;
  secret: string;
  autoReceive?: boolean;
}
export interface VisibilitySnapshot { publicUntil: number; devices: ConnectedDevice[]; }

// Persist the deadline, never an elapsed counter. Re-check at every network authorization boundary.
export class Visibility {
  publicUntil: number = 0;
  devices: ConnectedDevice[] = [];
  revision: number = 0;
  isPublic(now: number = Date.now()): boolean { return Number.isFinite(this.publicUntil) && now < this.publicUntil; }
  remaining(now: number = Date.now()): number { return this.isPublic(now) ? Math.ceil((this.publicUntil - now) / 1000) : 0; }
  open(now: number = Date.now()): void { if (!this.isPublic(now)) { this.publicUntil = now + PUBLIC_DURATION; this.revision++; } }
  close(): void { this.publicUntil = 0; this.revision++; }
  get(fingerprint: string): ConnectedDevice | undefined { return this.devices.find(d => d.fingerprint === fingerprint); }
  remove(fingerprint: string): void { this.devices = this.devices.filter(d => d.fingerprint !== fingerprint); this.revision++; }
  setAutoReceive(fingerprint: string, enabled: boolean): void {
    const device = this.get(fingerprint);
    if (!device?.secret || (device.autoReceive === true) === enabled) return;
    this.devices = this.devices.map(d => d === device ? { ...d, autoReceive: enabled } : d);
    this.revision++;
  }
  setNickname(fingerprint: string, nickname: string): boolean {
    const device = this.get(fingerprint);
    const name = nickname.trim();
    if (!device || (device.nickname ?? '') === name) return false;
    if (name.length > 80) throw new Error('设备别名最多 80 个字符');
    this.devices = this.devices.map(d => d === device ? { ...d, nickname: name || undefined } : d);
    return true;
  }
  connect(info: DeviceInfo, address: string, secret: string, now: number = Date.now(), enableAutoReceive: boolean = false): void {
    const previous = this.get(info.fingerprint);
    const d: ConnectedDevice = { fingerprint: info.fingerprint, alias: info.alias, deviceType: info.deviceType,
      nickname: previous?.nickname,
      address, port: info.port, lastConnected: now, secret,
      autoReceive: !!secret && (enableAutoReceive || (previous?.secret === secret && previous.autoReceive === true)) };
    this.devices = [d, ...this.devices.filter(v => v.fingerprint !== d.fingerprint)].slice(0, 100);
  }
  restore(snapshot: VisibilitySnapshot, now: number = Date.now()): void {
    this.publicUntil = Number.isFinite(snapshot?.publicUntil) && snapshot.publicUntil > now && snapshot.publicUntil <= now + PUBLIC_DURATION ? snapshot.publicUntil : 0;
    this.devices = Array.isArray(snapshot?.devices) ? snapshot.devices.filter(d => !!d && typeof d.fingerprint === 'string' &&
      typeof d.alias === 'string' && typeof d.secret === 'string' && typeof d.address === 'string' && Number.isInteger(d.port)).slice(0, 100) : [];
  }
  snapshot(): VisibilitySnapshot { return { publicUntil: this.publicUntil, devices: this.devices }; }
}

export interface DiscoveryProof { nonce: string; time: number; mac: string; }
export function proofPayload(sender: string, receiver: string, purpose: string, nonce: string, time: number): string {
  return JSON.stringify([sender, receiver, purpose, nonce, time]);
}
export class ReplayGuard {
  private nonces: Map<string, number> = new Map();
  valid(proof: DiscoveryProof, now: number = Date.now()): boolean {
    this.nonces.forEach((expires, key) => { if (expires <= now) this.nonces.delete(key); });
    return !!proof && typeof proof.nonce === 'string' && proof.nonce.length <= 128 && proof.nonce.length >= 16 &&
      Number.isFinite(proof.time) && Math.abs(now - proof.time) < 60000 && /^[a-f0-9]{64}$/.test(proof.mac) && !this.nonces.has(proof.nonce);
  }
  consume(proof: DiscoveryProof, now: number = Date.now()): void { this.nonces.set(proof.nonce, now + 120000); }
}
