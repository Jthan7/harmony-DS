#!/usr/bin/env node
/**
 * 修复 DevEco Studio ets-loader 的 syscap 检查误报（工具链 bug）。
 *
 * Bug：checkSyscapAbility（api_check_utils.js）取 API 声明第一个 @syscap 标签的
 * comment 原文与 device-define 纯名称集合做 has() 比对，不剥离 `[since ...]` 后缀。
 * 带 `[since 9 - 11]` / `[since 12]` 双标签的 API（cryptoFramework、audio namespace 等）
 * 恒不命中 → 每次真实编译误报 "The system capacity of this api ... is not supported
 * on all devices"。同文件 checkPermissionValue 已用 extractVersionRange + replace
 * 剥离后缀，syscap 路径漏做。
 *
 * 补丁：原字符串比对失败时，任一 @syscap 标签剥离 `[since ...]` 后缀后命中
 * syscapIntersectionSet 即放行（保留真实不支持的告警，只消除带版本后缀的误报）。
 *
 * 用法：
 *   node patch-syscap-check.js            # 打补丁（幂等；自动备份原文件到本目录）
 *   node patch-syscap-check.js --revert   # 从备份还原
 *
 * 注意：SDK 升级/修复安装后本补丁会丢失，需重新执行。
 * 目标文件路径可用环境变量 ETL_API_CHECK_UTILS 覆盖。
 */
const fs = require('fs');
const path = require('path');

const TARGET =
  process.env.ETL_API_CHECK_UTILS ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/lib/fast_build/system_api/api_check_utils.js';
const BAK = path.join(__dirname, 'api_check_utils.js.orig');

const MATCH =
  'has(a)){const e=new _syscap_warning_suppressor.SyscapWarningSuppressor(t,i);';
const REPLACEMENT =
  "has(a)){var _scAny=!1;for(var _s=0;_s<t.length;_s++){var _o=t[_s];if(_o&&_o.tagName&&'string'==typeof _o.comment&&_o.tagName.escapedText.toString()===_api_check_define.SYSCAP_TAG_CHECK_NAME){var _p=_o.comment.replace(/\\[since[^\\]]*\\]/g,'').trim();if(_main.projectConfig.syscapIntersectionSet.has(_p)){_scAny=!0;break}}}if(_scAny){return!1}const e=new _syscap_warning_suppressor.SyscapWarningSuppressor(t,i);";
const MARKER = 'var _scAny=!1';

function fail(msg) {
  console.error('[patch-syscap-check] ' + msg);
  process.exit(1);
}

function main() {
  if (!fs.existsSync(TARGET)) {
    fail('target not found: ' + TARGET);
  }
  const original = fs.readFileSync(TARGET, 'utf8');

  if (process.argv.includes('--revert')) {
    if (!fs.existsSync(BAK)) {
      fail('no backup at ' + BAK + ', cannot revert');
    }
    fs.writeFileSync(TARGET, fs.readFileSync(BAK, 'utf8'));
    console.log('[patch-syscap-check] reverted from ' + BAK);
    return;
  }

  if (original.includes(MARKER)) {
    console.log('[patch-syscap-check] already patched, nothing to do');
    return;
  }

  const count = original.split(MATCH).length - 1;
  if (count !== 1) {
    fail('expected exactly 1 match site, found ' + count + ' — SDK layout changed, aborting');
  }

  if (!fs.existsSync(BAK)) {
    fs.writeFileSync(BAK, original);
    console.log('[patch-syscap-check] backup written: ' + BAK);
  }

  const patched = original.replace(MATCH, () => REPLACEMENT);
  fs.writeFileSync(TARGET, patched);
  console.log('[patch-syscap-check] patched checkSyscapAbility in ' + TARGET);
}

main();
