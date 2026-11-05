import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export enum Theme { System, Light, Dark }

export class Appearance {
  static async read(context: common.Context): Promise<Theme> {
    const store = await preferences.getPreferences(context, 'appearance');
    const value = await store.get('theme', Theme.System);
    if (value === Theme.Light || value === Theme.Dark) return value;
    return Theme.System;
  }

  static async save(context: common.Context, theme: Theme): Promise<void> {
    const store = await preferences.getPreferences(context, 'appearance');
    const previous = await store.get('theme', Theme.System);
    await store.put('theme', theme);
    try { await store.flush(); }
    catch (e) {
      await store.put('theme', previous);
      throw e as Error;
    }
  }

  static mode(theme: Theme): ConfigurationConstant.ColorMode {
    if (theme === Theme.Dark) return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (theme === Theme.Light) return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }
}
