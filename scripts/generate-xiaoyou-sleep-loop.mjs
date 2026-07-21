import { copyFile, mkdir, rename, rm } from "node:fs/promises";
import { resolve } from "node:path";
import sharp from "sharp";

const root = resolve(import.meta.dirname, "..");
const sleepDirectory = resolve(root, "public/characters/qijiang-xiaoyou/animations/sleep");
const masterPath = resolve(sleepDirectory, "sleep_0001.png");
const wakeStartPath = resolve(
  root,
  "public/characters/qijiang-xiaoyou/animations/sleep_wake/sleep_wake_0001.png",
);
const temporaryDirectory = resolve(sleepDirectory, ".generated-sleep-loop");
const frameHeights = [495, 497, 499, 499, 497, 495];
const expectedCanvasSize = 1024;

const master = sharp(masterPath);
const metadata = await master.metadata();
if (
  metadata.width !== expectedCanvasSize ||
  metadata.height !== expectedCanvasSize ||
  metadata.channels !== 4
) {
  throw new Error("Xiaoyou sleep master must be a 1024x1024 RGBA PNG.");
}

const { data, info } = await master.ensureAlpha().raw().toBuffer({ resolveWithObject: true });
let minX = info.width;
let minY = info.height;
let maxX = -1;
let maxY = -1;

for (let y = 0; y < info.height; y += 1) {
  for (let x = 0; x < info.width; x += 1) {
    if (data[(y * info.width + x) * info.channels + 3] === 0) continue;
    minX = Math.min(minX, x);
    minY = Math.min(minY, y);
    maxX = Math.max(maxX, x);
    maxY = Math.max(maxY, y);
  }
}

if (maxX < minX || maxY < minY) {
  throw new Error("Xiaoyou sleep master is fully transparent.");
}

const sourceWidth = maxX - minX + 1;
const sourceHeight = maxY - minY + 1;
if (sourceWidth !== 721 || sourceHeight !== 495 || maxY !== 856) {
  throw new Error(
    `Unexpected Xiaoyou sleep master bounds: ${minX},${minY}-${maxX},${maxY}.`,
  );
}

await rm(temporaryDirectory, { recursive: true, force: true });
await mkdir(temporaryDirectory, { recursive: true });

try {
  for (let index = 0; index < frameHeights.length; index += 1) {
    const sequence = String(index + 1).padStart(4, "0");
    const destination = resolve(temporaryDirectory, `sleep_${sequence}.png`);
    const targetHeight = frameHeights[index];

    if (targetHeight === sourceHeight) {
      await copyFile(index === frameHeights.length - 1 ? wakeStartPath : masterPath, destination);
      continue;
    }

    const resizedSubject = await sharp(masterPath)
      .extract({ left: minX, top: minY, width: sourceWidth, height: sourceHeight })
      .resize(sourceWidth, targetHeight, {
        fit: "fill",
        kernel: sharp.kernel.lanczos3,
      })
      .png()
      .toBuffer();

    await sharp({
      create: {
        width: expectedCanvasSize,
        height: expectedCanvasSize,
        channels: 4,
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      },
    })
      .composite([
        {
          input: resizedSubject,
          left: minX,
          top: maxY - targetHeight + 1,
        },
      ])
      .png()
      .toFile(destination);
  }

  for (let index = 0; index < frameHeights.length; index += 1) {
    const sequence = String(index + 1).padStart(4, "0");
    const generated = resolve(temporaryDirectory, `sleep_${sequence}.png`);
    const destination = resolve(sleepDirectory, `sleep_${sequence}.png`);
    await rm(destination, { force: true });
    await rename(generated, destination);
  }
} finally {
  await rm(temporaryDirectory, { recursive: true, force: true });
}

console.log("Generated Xiaoyou sleep loop with a fixed ground line and subtle breathing motion.");
