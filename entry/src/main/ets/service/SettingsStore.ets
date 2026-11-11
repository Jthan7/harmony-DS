import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'app_settings';
const KEY_AUTO_READ: string = 'autoReadAnswer';
const KEY_THINKING: string = 'thinkingEnabled';
const KEY_SEARCH: string = 'searchEnabled';

/**
 * 轻量设置持久化（基于 Preferences）：自动朗读开关等跨重启配置
 */
export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  private static async ensure(context: common.Context): Promise<preferences.Preferences | null> {
    if (SettingsStore.store !== null) {
      return SettingsStore.store;
    }
    try {
      SettingsStore.store = await preferences.getPreferences(context, PREF_NAME);
      return SettingsStore.store;
    } catch (e) {
      return null;
    }
  }

  static async getAutoRead(context: common.Context): Promise<boolean> {
    return SettingsStore.getBool(context, KEY_AUTO_READ);
  }

  static async putAutoRead(context: common.Context, value: boolean): Promise<void> {
    await SettingsStore.putBool(context, KEY_AUTO_READ, value);
  }

  /** 深度思考开关：跨重启记忆 */
  static async getThinkingEnabled(context: common.Context): Promise<boolean> {
    return SettingsStore.getBool(context, KEY_THINKING);
  }

  static async putThinkingEnabled(context: common.Context, value: boolean): Promise<void> {
    await SettingsStore.putBool(context, KEY_THINKING, value);
  }

  /** 联网搜索开关：跨重启记忆 */
  static async getSearchEnabled(context: common.Context): Promise<boolean> {
    return SettingsStore.getBool(context, KEY_SEARCH);
  }

  static async putSearchEnabled(context: common.Context, value: boolean): Promise<void> {
    await SettingsStore.putBool(context, KEY_SEARCH, value);
  }

  private static async getBool(context: common.Context, key: string): Promise<boolean> {
    const store: preferences.Preferences | null = await SettingsStore.ensure(context);
    if (store === null) {
      return false;
    }
    let value: preferences.ValueType = false;
    try {
      value = store.getSync(key, false);
    } catch (e) {
      return false;
    }
    return value === true;
  }

  private static async putBool(context: common.Context, key: string, value: boolean): Promise<void> {
    const store: preferences.Preferences | null = await SettingsStore.ensure(context);
    if (store === null) {
      return;
    }
    try {
      await store.put(key, value);
      await store.flush();
    } catch (e) {
      // 持久化失败忽略，仅影响下次启动默认值
    }
  }
}
