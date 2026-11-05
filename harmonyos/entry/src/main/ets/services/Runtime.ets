import { common } from '@kit.AbilityKit';
import { TransferService } from './TransferService';

export class Runtime {
  private static instance?: TransferService;
  static get(context: common.UIAbilityContext): TransferService {
    if (!Runtime.instance) Runtime.instance = new TransferService(context);
    return Runtime.instance;
  }
  static active(): TransferService | undefined {
    return Runtime.instance?.running ? Runtime.instance : undefined;
  }
  static async destroy(): Promise<void> {
    if (Runtime.instance) await Runtime.instance.stop();
    Runtime.instance = undefined;
  }
}
