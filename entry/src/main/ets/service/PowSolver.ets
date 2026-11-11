import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { PowChallengeInfo } from './PowChallenge';
import { parseDeepSeekHashWords, deepSeekHashV1Matches } from './DeepSeekHash';
import { solvePowNative } from 'libentry.so';

@Concurrent
function solvePowTask(salt: string, challenge: string, difficulty: number, expireAt: number): number {
  const targetWords: number[] = parseDeepSeekHashWords(challenge.toLowerCase());
  // 原生 C 快路径；异常或内部错误（-2）时回退纯 TS 暴力循环
  let n: number = -2;
  try {
    n = solvePowNative(salt, challenge, difficulty, expireAt);
  } catch (e) {
    n = -2;
  }
  // 单次 ArkTS 哈希校验原生结果，防移植不一致导致票据被服务端拒绝
  if (n >= 0 && deepSeekHashV1Matches(`${salt}_${expireAt}_${n}`, targetWords)) {
    return n;
  }
  for (let i: number = 0; i < difficulty; i++) {
    if (deepSeekHashV1Matches(`${salt}_${expireAt}_${i}`, targetWords)) {
      return i;
    }
  }
  return -1;
}

/**
 * PoW 求解器：找 n ∈ [0, difficulty) 使
 * DeepSeekHashV1(`${salt}_${expireAt}_${n}`) === challenge（哈希全等）。
 * 优先走原生 C 求解（约百倍于纯 TS），失败自动回退纯 TS 循环；
 * 在 taskpool 线程执行，后台预热场景可指定低优先级减少调度争抢。
 */
export class PowSolver {
  static readonly DEFAULT_DIFFICULTY: number = 144000;

  static async solve(ch: PowChallengeInfo, lowPriority: boolean = false): Promise<number> {
    let difficulty: number = ch.difficulty;
    if (difficulty <= 0) {
      difficulty = PowSolver.DEFAULT_DIFFICULTY;
    }
    const task: taskpool.Task = new taskpool.Task(
      solvePowTask, ch.salt, ch.challenge, difficulty, ch.expireAt);
    const priority: taskpool.Priority = lowPriority ? taskpool.Priority.LOW : taskpool.Priority.MEDIUM;
    let result: object;
    try {
      result = await taskpool.execute(task, priority);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      throw new Error(`PoW task dispatch failed: ${err.message ?? 'unknown'}`);
    }
    const answer: number = Number(result);
    if (answer < 0) {
      throw new Error('PoW solve failed: answer not found');
    }
    return answer;
  }
}
