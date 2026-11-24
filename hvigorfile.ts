import { appTasks, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import type { OhosAppContext } from '@ohos/hvigor-ohos-plugin';
import type { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';

/**
 * 签名密码不写进 build-profile.json5。
 *
 * hvigor 只接受用本机密钥材料加密后的密码串（明文会报
 * "Invalid initialization vector"，空串则报 00303116 长度不足），
 * 所以这里做同样的事：读本地密码文件，用对应 material 按 AES-128-GCM
 * 加密后注入内存中的构建配置，仓库里只留空字段。
 *
 * 算法与 material 位置对齐 hvigor-ohos-plugin/src/utils/decipher-util.js：
 * 解密用的 material 固定取 storeFile 同级的 material/ 目录。
 */
interface SignProfile {
  /** build-profile.json5 里的 signingConfigs[].name */
  configName: string;
  /** 明文密码文件，相对工程根目录；同名 .enc 则视为已加密密文 */
  passwordFile: string;
}

interface LoadedPassword {
  value: string;
  /** true 表示读到的已是 hvigor 可解密的密文，直接注入即可 */
  encrypted: boolean;
}

const RELEASE_PROFILE: SignProfile = {
  configName: 'release',
  passwordFile: 'signing/keystore-password.txt'
};
const DEBUG_PROFILE: SignProfile = {
  configName: 'debug',
  passwordFile: 'signing/debug-password.txt'
};

/** hvigor 解密时异或用的固定组件 */
const COMPONENT: number[] = [49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119];

interface SigningMaterial {
  storeFile: string;
  storePassword: string;
  keyPassword: string;
  keyAlias: string;
  signAlg: string;
  profile: string;
  certpath: string;
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

/** 由 material 目录推导出加密用的工作密钥 */
function loadWorkKey(materialDir: string): Buffer {
  const fdParts: Buffer[] = ['0', '1', '2'].map((name: string) =>
    readSingleFile(path.join(materialDir, 'fd', name)));
  const salt: Buffer = readSingleFile(path.join(materialDir, 'ac'));
  const workMaterial: Buffer = readSingleFile(path.join(materialDir, 'ce'));
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

function readPassword(file: string): LoadedPassword | undefined {
  if (fs.existsSync(file)) {
    const password: string = fs.readFileSync(file, 'utf8').split(/\r?\n/)[0].trim();
    if (password.length > 0) {
      return { value: password, encrypted: false };
    }
  }
  // 备用通道：DevEco 生成的密文原样注入，不需要知道明文
  const encoded: string = file.replace(/\.txt$/, '.enc');
  if (encoded !== file && fs.existsSync(encoded)) {
    const cipher: string = fs.readFileSync(encoded, 'utf8').split(/\r?\n/)[0].trim();
    if (cipher.length > 0) {
      return { value: cipher, encrypted: true };
    }
  }
  return undefined;
}

function selectProfile(buildMode: string): SignProfile {
  // BOX_SIGN 可以强制指定签名，与 buildMode 解耦：
  // release 编译 + debug 签名是日常验证混淆的常用组合（发布证书侧载会被系统拒绝）
  const forced: string = process.env.BOX_SIGN ?? '';
  if (forced === 'debug' || forced === 'release') {
    return forced === 'release' ? RELEASE_PROFILE : DEBUG_PROFILE;
  }
  return buildMode === 'release' ? RELEASE_PROFILE : DEBUG_PROFILE;
}

function signingPlugin(): HvigorPlugin {
  return {
    pluginId: 'boxtoneSigning',
    apply(node: HvigorNode): void {
      const context: OhosAppContext | undefined =
        node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext | undefined;
      if (context === undefined) {
        return;
      }

      let buildMode: string = 'debug';
      try {
        buildMode = context.getBuildMode();
      } catch (error) {
        console.warn('[signing] 无法读取 buildMode，按 debug 处理');
      }

      const target: SignProfile = selectProfile(buildMode);
      const projectPath: string = context.getProjectPath();
      const passwordFile: string = path.resolve(projectPath, target.passwordFile);
      const password: LoadedPassword | undefined = readPassword(passwordFile);
      if (password === undefined) {
        console.warn(`[signing] 未找到 ${target.passwordFile}（或其 .enc 密文），${buildMode} 构建会因签名失败而中止`);
        return;
      }

      const profile: BuildProfile = context.getBuildProfileOpt() as BuildProfile;
      const signingConfigs: SigningConfig[] = profile.app.signingConfigs ?? [];
      const config: SigningConfig | undefined =
        signingConfigs.find((item: SigningConfig) => item.name === target.configName);
      if (config === undefined) {
        console.warn(`[signing] build-profile.json5 里没有名为 ${target.configName} 的签名配置`);
        return;
      }

      // hvigor 的解密 material 固定取 storeFile 同级的 material/ 目录
      const materialDir: string =
        path.resolve(projectPath, path.dirname(config.material.storeFile), 'material');
      if (!fs.existsSync(materialDir)) {
        console.warn(`[signing] 缺少密钥材料目录 ${path.relative(projectPath, materialDir)}，` +
          '请在 DevEco 的签名配置里应用一次以生成');
        return;
      }

      const missing: string[] = [config.material.storeFile, config.material.profile, config.material.certpath]
        .filter((file: string) => !fs.existsSync(path.resolve(projectPath, file)));
      if (missing.length > 0) {
        console.warn(`[signing] 缺少签名文件：${missing.join('、')}`);
      }

      try {
        const encrypted: string = password.encrypted
          ? password.value
          : encryptPassword(loadWorkKey(materialDir), password.value);
        config.material.storePassword = encrypted;
        config.material.keyPassword = encrypted;
      } catch (error) {
        console.warn(`[signing] 密码加密失败（material 与密钥库可能不匹配）：${(error as Error).message}`);
        return;
      }

      const productName: string = context.getCurrentProduct().getProductName();
      const product: ProductConfig | undefined = (profile.app.products ?? [])
        .find((item: ProductConfig) => item.name === productName);
      if (product !== undefined) {
        product.signingConfig = target.configName;
      }

      context.setBuildProfileOpt(profile);
      console.log(`[signing] ${buildMode} 构建使用 ${target.configName} 签名，密码已用本地材料加密注入`);
    }
  };
}

export default {
  system: appTasks,
  plugins: [signingPlugin()]
}
