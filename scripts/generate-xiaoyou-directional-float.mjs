import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const root = path.resolve(import.meta.dirname, "..");
const animationRoot = path.join(root, "public", "characters", "qijiang-xiaoyou", "animations");
const leftRoot = path.join(animationRoot, "walk_left");
const rightRoot = path.join(animationRoot, "walk_right");
const masterPath = path.join(root, "scripts", "assets", "qijiang-xiaoyou", "directional-float-left-master.png");
const bodyTop = [14, 10, 6, 10, 14, 10, 6, 10];
const bodyHeight = 824;

function sequence(value) {
  return String(value).padStart(4, "0");
}

function trailSvg(frameIndex) {
  const phase = [0, 8, 16, 24, 16, 8, 0, 8][frameIndex];
  const glow = [0.28, 0.34, 0.4, 0.46, 0.4, 0.34, 0.28, 0.34][frameIndex];
  return Buffer.from(`
    <svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="trail" x1="1" y1="0" x2="0" y2="0">
          <stop offset="0" stop-color="#8eeaff" stop-opacity="0"/>
          <stop offset="0.38" stop-color="#77d9ff" stop-opacity="${glow}"/>
          <stop offset="1" stop-color="#e8fcff" stop-opacity="0.1"/>
        </linearGradient>
        <radialGradient id="platform" cx="50%" cy="50%" rx="50%" ry="50%">
          <stop offset="0" stop-color="#dffaff" stop-opacity="0.68"/>
          <stop offset="0.55" stop-color="#74d8ff" stop-opacity="0.5"/>
          <stop offset="1" stop-color="#38b9ff" stop-opacity="0"/>
        </radialGradient>
        <filter id="blur" x="-35%" y="-100%" width="170%" height="300%">
          <feGaussianBlur stdDeviation="9"/>
        </filter>
        <filter id="soft" x="-35%" y="-100%" width="170%" height="300%">
          <feGaussianBlur stdDeviation="3"/>
        </filter>
      </defs>
      <ellipse cx="512" cy="954" rx="218" ry="31" fill="url(#platform)" filter="url(#blur)"/>
      <ellipse cx="512" cy="950" rx="172" ry="18" fill="none" stroke="#c8f7ff" stroke-width="3" opacity="${Math.min(0.9, glow + 0.4)}"/>
      <g fill="none" stroke-linecap="round" filter="url(#blur)">
        <path d="M 970 ${820 + phase} C 900 ${806 + phase}, 830 ${826 + phase}, 724 ${850 + phase}" stroke="url(#trail)" stroke-width="25"/>
        <path d="M 950 ${870 - phase / 2} C 878 ${854 - phase / 2}, 808 ${874 - phase / 2}, 704 ${895 - phase / 2}" stroke="url(#trail)" stroke-width="18"/>
        <path d="M 930 ${914 + phase / 3} C 858 ${900 + phase / 3}, 786 ${912 + phase / 3}, 688 ${928 + phase / 3}" stroke="#8eeaff" stroke-opacity="${glow * 0.72}" stroke-width="11"/>
      </g>
      <g fill="none" stroke="#e8fcff" stroke-linecap="round" filter="url(#soft)" opacity="${Math.min(0.82, glow + 0.28)}">
        <path d="M 948 ${835 + phase} L 808 ${855 + phase}" stroke-width="4"/>
        <path d="M 920 ${886 - phase / 2} L 776 ${902 - phase / 2}" stroke-width="3"/>
      </g>
      <g fill="#e8fcff" stroke="#77d9ff" stroke-width="2" opacity="${Math.min(0.9, glow + 0.38)}">
        <path d="M ${900 - phase} ${790 + phase} l 8 12 -8 12 -8 -12 z"/>
        <path d="M ${854 + phase / 2} ${872 - phase / 2} l 6 9 -6 9 -6 -9 z"/>
        <path d="M ${946 - phase / 2} ${918 + phase / 3} l 5 8 -5 8 -5 -8 z"/>
      </g>
    </svg>
  `);
}

async function normalizedBody(master, top) {
  const trimmed = await sharp(master)
    .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 }, threshold: 1 })
    .resize({ height: bodyHeight, fit: "inside", withoutEnlargement: false })
    .png({ compressionLevel: 9 })
    .toBuffer({ resolveWithObject: true });
  const left = Math.round((1024 - trimmed.info.width) / 2);
  return sharp({ create: { width: 1024, height: 1024, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: trimmed.data, left, top }])
    .png({ compressionLevel: 9 })
    .toBuffer();
}

async function validatePng(buffer, label) {
  const metadata = await sharp(buffer).metadata();
  if (metadata.width !== 1024 || metadata.height !== 1024 || metadata.channels !== 4) {
    throw new Error(`${label} must be a 1024x1024 RGBA PNG.`);
  }
}

async function removeResidualKeyFringe(buffer) {
  const raw = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let index = 0; index < raw.data.length; index += 4) {
    const red = raw.data[index];
    const green = raw.data[index + 1];
    const blue = raw.data[index + 2];
    const alpha = raw.data[index + 3];
    if (alpha < 64 && green > red * 1.18 && green > blue * 1.18 && green > 80) {
      raw.data[index] = 0;
      raw.data[index + 1] = 0;
      raw.data[index + 2] = 0;
      raw.data[index + 3] = 0;
    }
  }
  return sharp(raw.data, { raw: raw.info }).png({ compressionLevel: 9 }).toBuffer();
}

const master = await readFile(masterPath);
const masterMetadata = await sharp(master).metadata();
if (masterMetadata.format !== "png" || masterMetadata.channels !== 4 || !masterMetadata.width || !masterMetadata.height) {
  throw new Error(`${path.basename(masterPath)} must be a readable RGBA PNG.`);
}

const rendered = [];
for (let frameIndex = 0; frameIndex < bodyTop.length; frameIndex += 1) {
  const body = await normalizedBody(master, bodyTop[frameIndex]);
  const composited = await sharp(trailSvg(frameIndex))
    .composite([{ input: body, blend: "over" }])
    .png({ compressionLevel: 9 })
    .toBuffer();
  const left = await removeResidualKeyFringe(composited);
  const right = await sharp(left).flop().png({ compressionLevel: 9 }).toBuffer();
  await validatePng(left, `walk_left_${sequence(frameIndex + 1)}.png`);
  await validatePng(right, `walk_right_${sequence(frameIndex + 1)}.png`);
  rendered.push({ frameIndex, left, right });
}

for (const { frameIndex, left, right } of rendered) {
  const number = sequence(frameIndex + 1);
  await writeFile(path.join(leftRoot, `walk_left_${number}.png`), left);
  await writeFile(path.join(rightRoot, `walk_right_${number}.png`), right);
}

const digest = createHash("sha256");
for (const frame of rendered) {
  digest.update(frame.left);
  digest.update(frame.right);
}
console.log(`Generated ${rendered.length * 2} directional floating frames from ${path.relative(root, masterPath)}.`);
console.log(`Combined SHA-256: ${digest.digest("hex").toUpperCase()}`);
