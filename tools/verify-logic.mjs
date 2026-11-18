#!/usr/bin/env node
/**
 * 盒音工坊 · 纯逻辑回归检查（不需要手机、不需要 DevEco）
 *
 * 直接复用应用里的 SelfCheckService 断言，把它跑在 Node 上：
 * 把 ArkTS 源码复制成 .ts、替换 @kit.* 为本地桩、补全导入扩展名，
 * 然后调用真实的 runAll()。断言只有一份，不会和设备上的自检走偏。
 *
 * 用法：
 *   node tools/verify-logic.mjs
 *
 * 依赖 Node 22+（原生剥离 TS 类型）。失败时退出码为 1，可直接挂到 pre-push。
 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ETS = join(ROOT, 'entry/src/main/ets');
const TMP = join(ROOT, '.verify-tmp');

/** 需要复制的真实源码（相对 entry/src/main/ets） */
const SOURCES = [
  'common/utils/ByteUtils.ets',
  'models/ToneModel.ets',
  'services/SettingsService.ets',
  'services/ToneSynthesizerService.ets',
  'services/bluetooth/MbbProtocol.ets',
  'services/SelfCheckService.ets'
];

/** @kit.* 的桩：只保留被内联使用的形状，不实现任何真实能力 */
const KITS = {
  'AbilityKit': 'export const common = {};\n',
  'ArkData': 'export const preferences = {};\n',
  'BasicServicesKit': 'export class BusinessError extends Error {}\n',
  'PerformanceAnalysisKit': 'export const hilog = {};\n',
  'CryptoArchitectureKit': 'export const cryptoFramework = {};\n'
};

function fail(message) {
  console.error(`\x1b[31m  ✗\x1b[0m ${message}`);
  process.exit(1);
}

/** AppConstants 里有 enum，Node 不能剥离，只抽取自检用到的静态常量类 */
function constantSubset() {
  const text = readFileSync(join(ETS, 'common/constants/AppConstants.ets'), 'utf8');
  const wanted = ['ToneSpec', 'MbbSpec', 'AppStorageKey'];
  const blocks = [];
  for (const name of wanted) {
    const match = new RegExp(`export class ${name} \\{[\\s\\S]*?\\n\\}`).exec(text);
    if (match === null) {
      fail(`AppConstants 里找不到 ${name}，常量结构变了，需要更新本脚本`);
    }
    blocks.push(match[0]);
  }
  return blocks.join('\n\n') + '\n';
}

function kitStubs() {
  mkdirSync(join(TMP, 'kit'), { recursive: true });
  for (const [name, body] of Object.entries(KITS)) {
    writeFileSync(join(TMP, 'kit', `${name}.ts`), body, 'utf8');
  }
}

function loggerStub() {
  const path = join(TMP, 'common/utils/Logger.ts');
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, [
    'export type LogSink = (level: number, module: string, message: string) => void;',
    'export class Logger {',
    '  static setSink(sink: LogSink): void {}',
    '  static debug(module: string, message: string): void {}',
    '  static info(module: string, message: string): void {}',
    '  static warn(module: string, message: string): void { console.log(`  ! ${module}: ${message}`); }',
    '  static error(module: string, message: string): void { console.log(`  ERR ${module}: ${message}`); }',
    '  static exception(module: string, context: string, error: object): void {',
    '    console.log(`  ERR ${module}: ${context} ${JSON.stringify(error)}`);',
    '  }',
    '}',
    ''
  ].join('\n'), 'utf8');
}

function shaStub() {
  const path = join(TMP, 'common/utils/Sha256Utils.ts');
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, [
    "import { createHash } from 'node:crypto';",
    'export class Sha256Utils {',
    '  static digest(data: Uint8Array): Uint8Array {',
    "    return new Uint8Array(createHash('sha256').update(Buffer.from(data)).digest());",
    '  }',
    '}',
    ''
  ].join('\n'), 'utf8');
}

function i18nStub() {
  const path = join(TMP, 'common/i18n/I18n.ts');
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, [
    'export class I18n {',
    '  static t(key: string): string { return key; }',
    "  static f(key: string, args: string[]): string { return `${key}:${args.join(',')}`; }",
    '}',
    ''
  ].join('\n'), 'utf8');
}

/** 改写导入：去掉 .ets、补 .ts、@kit.* 指向桩、纯类型模块改成 import type */
function rewrite(source, target, text) {
  let out = text;
  out = out.replace(/from '(@kit\.[A-Za-z]+)'/g, (_all, spec) => {
    const name = spec.slice(5);
    const rel = relative(dirname(target), join(TMP, 'kit', `${name}.ts`)).replace(/\\/g, '/');
    return `from '${rel.startsWith('.') ? rel : `./${rel}`}'`;
  });
  out = out.replace(/from '(\.[^']*)'/g, (all, spec) => {
    if (spec.endsWith('.ts')) return all;
    return `from '${spec}.ts'`;
  });
  // ToneModel 只导出类型，必须写成 import type，否则 Node 会当作值去找导出
  out = out.split('\n').map((line) => {
    if (line.startsWith('import {') && /ToneModel\.ts'/.test(line)) {
      return line.replace('import {', 'import type {');
    }
    return line;
  }).join('\n');
  return out;
}

function build() {
  rmSync(TMP, { recursive: true, force: true });
  kitStubs();
  loggerStub();
  shaStub();
  i18nStub();

  const constants = join(TMP, 'common/constants/AppConstants.ts');
  mkdirSync(dirname(constants), { recursive: true });
  writeFileSync(constants, constantSubset(), 'utf8');

  for (const rel of SOURCES) {
    const source = join(ETS, rel);
    if (!existsSync(source)) {
      fail(`源码缺失：${rel}`);
    }
    const target = join(TMP, rel.replace(/\.ets$/, '.ts'));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, rewrite(source, target, readFileSync(source, 'utf8')), 'utf8');
  }
}

build();

const entry = pathToFileURL(join(TMP, 'services/SelfCheckService.ts')).href;
const module = await import(entry);
const SelfCheckService = module.SelfCheckService;
if (SelfCheckService === undefined) {
  fail('SelfCheckService 没有导出 runAll');
}

const report = SelfCheckService.runAll();
for (const item of report.items) {
  const mark = item.passed ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m';
  const detail = item.passed ? '' : `  ← ${item.detail}`;
  console.log(`  ${mark} ${item.name}${detail}`);
}
console.log();
if (report.failed === 0) {
  console.log(`\x1b[32m自检通过 ${report.passed}/${report.total}\x1b[0m，耗时 ${report.elapsedMs}ms（Node · 不依赖设备）`);
  process.exit(0);
}
console.log(`\x1b[31m自检失败 ${report.failed}/${report.total}\x1b[0m，耗时 ${report.elapsedMs}ms`);
process.exit(1);
