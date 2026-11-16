/**
 * 盒音工坊 · 反馈转发服务
 *
 * 接收 App 的 POST /feedback（JSON），把描述、诊断日志和截图转发到邮箱。
 * 认证：Authorization: Bearer <FEEDBACK_TOKEN>
 * 接口契约与 entry/src/main/ets/services/FeedbackApiService.ets 对应。
 */

import http from 'node:http';
import nodemailer from 'nodemailer';

const PORT = Number(process.env.PORT || 9000);
const HOST = process.env.HOST || '0.0.0.0';
const TOKEN = (process.env.FEEDBACK_TOKEN || '').trim();
const SMTP_HOST = process.env.SMTP_HOST || 'smtp.qq.com';
const SMTP_PORT = Number(process.env.SMTP_PORT || 465);
const SMTP_USER = (process.env.SMTP_USER || '').trim();
const SMTP_PASS = (process.env.SMTP_PASS || '').trim();
const MAIL_TO = (process.env.MAIL_TO || SMTP_USER).trim();

/** 请求体上限：日志文本 + 3 张截图的 base64 */
const MAX_BODY_BYTES = 12 * 1024 * 1024;
const MAX_LOG_CHARS = 500000;
const MAX_DESCRIPTION_CHARS = 20000;
const MAX_IMAGES = 3;
/** 所有截图解码后的总量上限 */
const MAX_IMAGES_BYTES = 10 * 1024 * 1024;
/** 同一来源 5 分钟内最多提交次数 */
const RATE_LIMIT = 6;
const RATE_WINDOW_MS = 5 * 60 * 1000;

if (!TOKEN) {
  console.error('[fatal] 未设置 FEEDBACK_TOKEN，拒绝以无鉴权方式启动');
  process.exit(1);
}
if (!SMTP_USER || !SMTP_PASS) {
  console.error('[fatal] 缺少 SMTP_USER / SMTP_PASS');
  process.exit(1);
}

const transporter = nodemailer.createTransport({
  host: SMTP_HOST,
  port: SMTP_PORT,
  secure: SMTP_PORT === 465,
  auth: { user: SMTP_USER, pass: SMTP_PASS }
});

const rateHits = new Map();

function allowRequest(ip) {
  const now = Date.now();
  const recent = (rateHits.get(ip) || []).filter((t) => now - t < RATE_WINDOW_MS);
  if (recent.length >= RATE_LIMIT) {
    return false;
  }
  recent.push(now);
  rateHits.set(ip, recent);
  // 防止 Map 无限增长；清空只影响一次窗口，对个人服务够用
  if (rateHits.size > 5000) {
    rateHits.clear();
  }
  return true;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        const error = new Error('请求体过大');
        error.status = 413;
        reject(error);
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function reply(res, status, payload) {
  const text = JSON.stringify(payload);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(text);
}

function cleanLine(value, maxLength) {
  // 去掉换行，避免邮件头注入
  return String(value ?? '').replace(/[\r\n]+/g, ' ').trim().slice(0, maxLength);
}

function extOf(buffer) {
  if (buffer[0] === 0x89 && buffer[1] === 0x50) {
    return '.png';
  }
  if (buffer[0] === 0xff && buffer[1] === 0xd8) {
    return '.jpg';
  }
  if (buffer[0] === 0x52 && buffer[1] === 0x49 && buffer[8] === 0x57) {
    return '.webp';
  }
  if (buffer.length >= 12 && buffer.subarray(4, 8).toString('ascii') === 'ftyp') {
    return '.heic';
  }
  return '.jpg';
}

function mimeOf(ext) {
  if (ext === '.png') {
    return 'image/png';
  }
  if (ext === '.webp') {
    return 'image/webp';
  }
  if (ext === '.heic') {
    return 'image/heic';
  }
  return 'image/jpeg';
}

function buildAttachments(payload) {
  const attachments = [];
  const log = typeof payload.log === 'string' ? payload.log.slice(0, MAX_LOG_CHARS) : '';
  if (log) {
    attachments.push({
      filename: 'boxtone-feedback-log.txt',
      content: log,
      contentType: 'text/plain; charset=utf-8'
    });
  }

  const images = Array.isArray(payload.images) ? payload.images.slice(0, MAX_IMAGES) : [];
  let total = 0;
  let index = 0;
  for (const raw of images) {
    if (typeof raw !== 'string' || raw.length === 0) {
      continue;
    }
    const buffer = Buffer.from(raw, 'base64');
    if (buffer.length === 0) {
      continue;
    }
    total += buffer.length;
    if (total > MAX_IMAGES_BYTES) {
      break;
    }
    index += 1;
    const ext = extOf(buffer);
    attachments.push({
      filename: `feedback-${index}${ext}`,
      content: buffer,
      contentType: mimeOf(ext)
    });
  }
  return attachments;
}

function buildText(payload) {
  const lines = [
    '==== 盒音工坊 反馈 ====',
    `反馈类型：${cleanLine(payload.typeLabel, 40) || '未填写'}`,
    `应用版本：${cleanLine(payload.appVersion, 40)}`,
    `耳机：${cleanLine(payload.device, 80)}`,
    `联系方式：${cleanLine(payload.contact, 200) || '未填写'}`,
    `提交时间：${new Date(Number(payload.createdAt) || Date.now()).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}`,
    '',
    '描述：',
    String(payload.description ?? '').slice(0, MAX_DESCRIPTION_CHARS)
  ];
  return lines.join('\n');
}

async function handleFeedback(req, res) {
  if ((req.headers.authorization || '') !== `Bearer ${TOKEN}`) {
    reply(res, 401, { ok: false, message: 'unauthorized' });
    return;
  }
  if (!(req.headers['content-type'] || '').includes('application/json')) {
    reply(res, 415, { ok: false, message: 'content-type must be application/json' });
    return;
  }

  const ip = req.socket.remoteAddress || 'unknown';
  if (!allowRequest(ip)) {
    reply(res, 429, { ok: false, message: 'too many requests' });
    return;
  }

  let payload;
  try {
    payload = JSON.parse(await readBody(req));
  } catch (error) {
    reply(res, error.status || 400, { ok: false, message: 'invalid json' });
    return;
  }

  if (typeof payload.description !== 'string' || payload.description.trim().length === 0) {
    reply(res, 400, { ok: false, message: 'description required' });
    return;
  }

  const subject = `盒音工坊反馈 · ${cleanLine(payload.typeLabel, 40) || '反馈'}`;
  try {
    await transporter.sendMail({
      from: `"盒音工坊反馈" <${SMTP_USER}>`,
      to: MAIL_TO,
      subject: subject,
      text: buildText(payload),
      attachments: buildAttachments(payload)
    });
    console.log(`[feedback] sent to ${MAIL_TO} images=${(payload.images || []).length}`);
    reply(res, 200, { ok: true });
  } catch (error) {
    // 不打印正文，避免日志里出现用户信息
    console.error('[feedback] send failed:', error.message);
    reply(res, 502, { ok: false, message: 'mail delivery failed' });
  }
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    reply(res, 200, { ok: true });
    return;
  }
  if (req.method === 'POST' && req.url === '/feedback') {
    await handleFeedback(req, res);
    return;
  }
  reply(res, 404, { ok: false, message: 'not found' });
});

server.listen(PORT, HOST, () => {
  console.log(`[server] listening on ${HOST}:${PORT}`);
  transporter
    .verify()
    .then(() => console.log('[server] SMTP ready'))
    .catch((error) => console.error('[server] SMTP verify failed:', error.message));
});
