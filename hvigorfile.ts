import { appTasks, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import type { OhosAppContext } from '@ohos/hvigor-ohos-plugin';
import type { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';

/**
 * release 签名密码不写进 build-profile.json5。
 *
 * hvigor 只接受 DevEco 用本机密钥材料加密后的密码串（明文会报
 * "Invalid initialization vector"），所以这里做同样的事：
 * 读 signing/keystore-password.txt，用 signing/material 里的密钥材料
 * 按 AES-128-GCM 加密，再把密文注入内存中的构建配置。
 *
 * 算法对齐 hvigor-ohos-plugin/src/utils/decipher-util.js。
 */
const PASSWORD_FILE: string = 'signing/keystore-password.txt';
const MATERIAL_DIR: string = 'signing/material';
/** hvigor 解密时异或用的固定组件 */
const COMPONENT: number[] = [49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119];

interface SigningMaterial {
  storePassword: string;
  keyPassword: string;
  [key: string]: string;
}

interface SigningConfig {
  name: string;
  material: SigningMaterial;
  [key: string]: string | SigningMaterial;
}

interface ProductConfig {
  name: string;
  signingConfig?: string;
  [key: string]: string | undefined;
}

interface BuildProfile {
  app: {
    signingConfigs?: SigningConfig[];
    products?: ProductConfig[];
  };
}

function readSingleFile(dir: string): Buffer {
  const names: string[] = fs.readdirSync(dir).filter((name: string) => name !== '.DS_Store');
  if (names.length !== 1) {
    throw new Error(`${dir} 里应只有一个文件，实际 ${names.length} 个`);
  }
  return fs.readFileSync(path.join(dir, names[0]));
}

function xorAll(parts: Buffer[]): Buffer {
  let acc: Buffer = Buffer.from(parts[0]);
  for (let i = 1; i < parts.length; i++) {
    const next: Buffer = parts[i];
    if (next.length !== acc.length) {
      throw new Error('签名材料组件长度不一致');
    }
    const out: Buffer = Buffer.alloc(acc.length);
    for (let j = 0; j < acc.length; j++) {
      out[j] = acc[j] ^ next[j];
    }
    acc = out;
  }
  return acc;
}

function aesGcmDecrypt(key: Buffer, payload: Buffer): Buffer {
  const bodyLength: number = payload.readUInt32BE(0);
  const ivLength: number = payload.length - 4 - bodyLength;
  const iv: Buffer = payload.subarray(4, 4 + ivLength);
  const decipher = crypto.createDecipheriv('aes-128-gcm', key, iv);
  decipher.setAuthTag(payload.subarray(payload.length - 16));
  return Buffer.concat([
    decipher.update(payload.subarray(4 + ivLength, payload.length - 16)),
    decipher.final()
  ]);
}

/** 由 signing/material 推导出加密用的工作密钥 */
function loadWorkKey(projectPath: string): Buffer {
  const base: string = path.resolve(projectPath, MATERIAL_DIR);
  const fdParts: Buffer[] = ['0', '1', '2'].map((name: string) =>
    readSingleFile(path.join(base, 'fd', name)));
  const salt: Buffer = readSingleFile(path.join(base, 'ac'));
  const workMaterial: Buffer = readSingleFile(path.join(base, 'ce'));
  const rootKey: Buffer = crypto.pbkdf2Sync(
    xorAll([...fdParts, Buffer.from(COMPONENT)]).toString(), salt, 10000, 16, 'sha256');
  return aesGcmDecrypt(rootKey, workMaterial);
}

function encryptPassword(workKey: Buffer, plain: string): string {
  const iv: Buffer = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-128-gcm', workKey, iv);
  const body: Buffer = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag: Buffer = cipher.getAuthTag();
  const header: Buffer = Buffer.alloc(4);
  header.writeUInt32BE(body.length + tag.length, 0);
  return Buffer.concat([header, iv, body, tag]).toString('hex');
}

function readPassword(projectPath: string): string | undefined {
  const file: string = path.resolve(projectPath, PASSWORD_FILE);
  if (!fs.existsSync(file)) {
    return undefined;
  }
  const password: string = fs.readFileSync(file, 'utf8').split(/\r?\n/)[0].trim();
  return password.length > 0 ? password : undefined;
}

function releaseSigningPlugin(): HvigorPlugin {
  return {
    pluginId: 'boxtoneReleaseSigning',
    apply(node: HvigorNode): void {
      const context: OhosAppContext | undefined =
        node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext | undefined;
      if (context === undefined) {
        return;
      }
      let buildMode: string;
      try {
        buildMode = context.getBuildMode();
      } catch (error) {
        console.warn('[signing] 无法读取 buildMode，跳过签名密码注入');
        return;
      }
      if (buildMode !== 'release') {
        return;
      }

      const projectPath: string = context.getProjectPath();
      const password: string | undefined = readPassword(projectPath);
      if (password === undefined) {
        console.warn(`[signing] 未找到 ${PASSWORD_FILE} 或内容为空，release 构建会因签名失败而中止`);
        return;
      }
      if (!fs.existsSync(path.resolve(projectPath, MATERIAL_DIR))) {
        console.warn('[signing] 缺少 signing/material（DevEco 加密密码用的本机密钥材料），' +
          '请在 DevEco 签名配置里应用一次以生成');
        return;
      }

      const profile: BuildProfile = context.getBuildProfileOpt() as BuildProfile;
      const signingConfigs: SigningConfig[] = profile.app.signingConfigs ?? [];
      const release: SigningConfig | undefined =
        signingConfigs.find((item: SigningConfig) => item.name === 'release');
      if (release === undefined) {
        console.warn('[signing] build-profile.json5 里没有名为 release 的签名配置');
        return;
      }

      const missing: string[] = [release.material.storeFile, release.material.profile, release.material.certpath]
        .filter((file: string) => !fs.existsSync(path.resolve(projectPath, file)));
      if (missing.length > 0) {
        console.warn(`[signing] 缺少签名材料：${missing.join('、')}`);
      }

      const encrypted: string = encryptPassword(loadWorkKey(projectPath), password);
      release.material.storePassword = encrypted;
      release.material.keyPassword = encrypted;

      const productName: string = context.getCurrentProduct().getProductName();
      const product: ProductConfig | undefined = (profile.app.products ?? [])
        .find((item: ProductConfig) => item.name === productName);
      if (product !== undefined) {
        product.signingConfig = 'release';
      }

      context.setBuildProfileOpt(profile);
      console.log('[signing] 已用本地密钥材料加密 release 签名密码');
    }
  };
}

export default {
  system: appTasks,
  plugins: [releaseSigningPlugin()]
}
