import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DSLogin';
const PREF_NAME: string = 'auth_device';
const KEY_DEVICE_ID: string = 'auth_device_id';

/**
 * 设备标识持久化（RD-04）：
 * 首次调用生成 UUID v4（util.generateRandomUUID）存 Preferences（键 auth_device_id），
 * 之后直接返回缓存值。作为请求头 x-device-id 与请求体 device_id 字段使用；
 * 固定 device-id 有利于服务端风控画像稳定（与 Web 端 localStorage 持久化行为一致）。
 */
export class DeviceIdStore {
  private static store: preferences.Preferences | null = null;
  private static cachedId: string = '';

  private static async ensure(context: common.Context): Promise<preferences.Preferences | null> {
    if (DeviceIdStore.store !== null) {
      return DeviceIdStore.store;
    }
    try {
      DeviceIdStore.store = await preferences.getPreferences(context, PREF_NAME);
      return DeviceIdStore.store;
    } catch (e) {
      hilog.error(0x0000, TAG, 'deviceId preferences open failed');
      return null;
    }
  }

  /**
   * 获取（或首启创建并持久化）设备标识 UUID v4。
   * Preferences 不可用时退化为进程内内存 UUID，保证登录流程不中断。
   */
  static async getOrCreate(context: common.Context): Promise<string> {
    if (DeviceIdStore.cachedId.length > 0) {
      return DeviceIdStore.cachedId;
    }
    const store: preferences.Preferences | null = await DeviceIdStore.ensure(context);
    if (store === null) {
      DeviceIdStore.cachedId = util.generateRandomUUID(true);
      return DeviceIdStore.cachedId;
    }
    let saved: string = '';
    try {
      const value: preferences.ValueType = store.getSync(KEY_DEVICE_ID, '');
      saved = typeof value === 'string' ? value : '';
    } catch (e) {
      hilog.warn(0x0000, TAG, 'deviceId read failed, regenerate');
    }
    if (saved.length > 0) {
      DeviceIdStore.cachedId = saved;
      return saved;
    }
    const generated: string = util.generateRandomUUID(true);
    try {
      await store.put(KEY_DEVICE_ID, generated);
      await store.flush();
    } catch (e) {
      // 持久化失败不影响本次会话使用
      hilog.warn(0x0000, TAG, 'deviceId persist failed, using in-memory id');
    }
    DeviceIdStore.cachedId = generated;
    return generated;
  }
}
