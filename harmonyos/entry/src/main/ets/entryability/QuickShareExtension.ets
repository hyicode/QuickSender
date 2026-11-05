import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { ShareSession } from '../services/ShareSession';

export default class QuickShareExtension extends ShareExtensionAbility {
  private sessions: Map<UIExtensionContentSession, number> = new Map();

  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    const model = new ShareSession(this.context.getApplicationContext(), want, session);
    const id = ShareSession.register(model);
    this.sessions.set(session, id);
    const storage = new LocalStorage();
    storage.setOrCreate('shareSessionId', id);
    session.loadContent('pages/SharePanel', storage);
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    const id = this.sessions.get(session);
    if (id !== undefined) ShareSession.release(id).catch(() => {});
    this.sessions.delete(session);
  }

  onDestroy(): void {
    this.sessions.forEach(id => ShareSession.release(id).catch(() => {}));
    this.sessions.clear();
  }
}
