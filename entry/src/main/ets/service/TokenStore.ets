import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

const TOKEN_ALIAS: string = 'ds_user_token';

function strToBytes(input: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(input);
}

function bytesToStr(input: Uint8Array): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(input);
}

export class TokenStore {
  static get(): string {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, strToBytes(TOKEN_ALIAS));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result: Array<asset.AssetMap> = asset.querySync(query);
      if (result.length === 0) {
        return '';
      }
      const secretValue: asset.Value | undefined = result[0].get(asset.Tag.SECRET);
      if (secretValue instanceof Uint8Array) {
        return bytesToStr(secretValue);
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  static set(token: string): void {
    TokenStore.remove();
    try {
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.SECRET, strToBytes(token));
      attrs.set(asset.Tag.ALIAS, strToBytes(TOKEN_ALIAS));
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      asset.addSync(attrs);
    } catch (e) {
      console.error('TokenStore set failed');
    }
  }

  static remove(): void {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, strToBytes(TOKEN_ALIAS));
      asset.removeSync(query);
    } catch (e) {
      // 未找到时忽略
    }
  }
}
