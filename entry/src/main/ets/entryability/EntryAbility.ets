import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // 键盘避让使用压缩模式：键盘弹出时页面整体缩至键盘上方，
    // 保证输入卡片（含“深度思考/联网搜索”按钮行）完整可见，而非仅输入框可见。
    windowStage.getMainWindow().then((mainWindow: window.Window): void => {
      try {
        mainWindow.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
        hilog.info(DOMAIN, 'testTag', 'Keyboard avoid mode set to RESIZE.');
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set keyboard avoid mode. Cause: %{public}s', JSON.stringify(err));
      }
    }).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, 'testTag', 'getMainWindow failed. Cause: %{public}s', JSON.stringify(error));
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', 'Ability onBackground');
  }
}