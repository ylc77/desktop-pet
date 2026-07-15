import { readFile, readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { PNG } from "pngjs";

const root = path.resolve("public/characters");
const stateName = /^[a-z][a-z0-9_-]*$/;
const characterId = /^[a-z0-9_][a-z0-9_-]*$/;
const frameName = /^([a-z][a-z0-9_-]*)_(\d{4})\.png$/;
const errors = [];
const warnings = [];
const ids = new Set();
const index = [];
const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const MAX_FRAMES_PER_ANIMATION = 240;
const MAX_CANVAS_EDGE = 4096;

async function exists(file) { try { await readFile(file); return true; } catch { return false; } }

const characterEntries = (await readdir(root, { withFileTypes: true })).sort((left, right) => left.name.localeCompare(right.name, "en"));
for (const entry of characterEntries) {
  if (!entry.isDirectory()) continue;
  const characterRoot = path.join(root, entry.name);
  const manifestFile = path.join(characterRoot, "manifest.json");
  if (!(await exists(manifestFile))) { warnings.push(`${entry.name}: 缺少 manifest.json，已忽略`); continue; }
  let manifest;
  try { manifest = JSON.parse(await readFile(manifestFile, "utf8")); } catch (error) { errors.push(`${entry.name}: manifest.json 无法解析: ${error.message}`); continue; }
  if (manifest.schemaVersion !== 1) errors.push(`${entry.name}: 不支持 schemaVersion ${manifest.schemaVersion}`);
  if (manifest.id !== entry.name) errors.push(`${entry.name}: manifest id 必须与目录名一致`);
  if (!characterId.test(manifest.id ?? "")) errors.push(`${entry.name}: 角色 ID 只能使用小写英文、数字、下划线和连字符`);
  if (ids.has(manifest.id)) errors.push(`${entry.name}: 重复角色 ID ${manifest.id}`);
  ids.add(manifest.id);
  if (!manifest.animations?.idle) errors.push(`${entry.name}: 缺少必需 idle 动画`);
  if (!Number.isFinite(manifest.defaultScale) || manifest.defaultScale <= 0 || manifest.defaultScale > 4) errors.push(`${entry.name}: defaultScale 必须为 0-4 范围内的正数`);
  if (!Number.isInteger(manifest.frameSize?.width) || !Number.isInteger(manifest.frameSize?.height) || manifest.frameSize.width < 16 || manifest.frameSize.height < 16 || manifest.frameSize.width > MAX_CANVAS_EDGE || manifest.frameSize.height > MAX_CANVAS_EDGE) errors.push(`${entry.name}: frameSize 必须为 16-${MAX_CANVAS_EDGE} 的整数`);
  if (!Number.isFinite(manifest.anchor?.x) || !Number.isFinite(manifest.anchor?.y) || manifest.anchor.x < 0 || manifest.anchor.x > 1 || manifest.anchor.y < 0 || manifest.anchor.y > 1) errors.push(`${entry.name}: anchor 必须位于 0-1 范围内`);
  if (manifest.hitbox) {
    const box = manifest.hitbox;
    if (![box.x, box.y, box.width, box.height].every(Number.isFinite) || box.x < 0 || box.y < 0 || box.width <= 0 || box.height <= 0 || box.x + box.width > 1 || box.y + box.height > 1) errors.push(`${entry.name}: hitbox 必须是画布内的归一化矩形`);
  }
  for (const asset of ["preview", "icon"]) {
    const relative = manifest[asset];
    if (!relative) continue;
    if (path.isAbsolute(relative) || relative.includes("..")) errors.push(`${entry.name}: ${asset} 路径越出角色目录`);
    else if (!(await exists(path.resolve(characterRoot, relative)))) errors.push(`${entry.name}: ${asset} 文件不存在: ${relative}`);
  }
  const frameIndex = { animations: {} };
  for (const [state, animation] of Object.entries(manifest.animations ?? {})) {
    if (!stateName.test(state)) { errors.push(`${entry.name}/${state}: 动作名无效`); continue; }
    if (!animation.path || path.isAbsolute(animation.path) || animation.path.includes("..")) { errors.push(`${entry.name}/${state}: 动画路径越出角色目录`); continue; }
    if (!(animation.fps >= 1 && animation.fps <= 60)) errors.push(`${entry.name}/${state}: FPS 必须为 1-60`);
    if (animation.minDelayMs !== undefined && animation.maxDelayMs !== undefined && animation.minDelayMs > animation.maxDelayMs) errors.push(`${entry.name}/${state}: minDelayMs 不能大于 maxDelayMs`);
    const directory = path.resolve(characterRoot, animation.path);
    if (!directory.startsWith(characterRoot + path.sep)) { errors.push(`${entry.name}/${state}: 路径越出角色目录`); continue; }
    let files = [];
    try { files = (await readdir(directory)).filter((file) => file.toLowerCase().endsWith(".png")).sort(); }
    catch { errors.push(`${entry.name}/${state}: 动画目录不存在`); continue; }
    if (files.length === 0) { errors.push(`${entry.name}/${state}: 没有 PNG 帧`); continue; }
    if (files.length > MAX_FRAMES_PER_ANIMATION) errors.push(`${entry.name}/${state}: 帧数 ${files.length} 超过上限 ${MAX_FRAMES_PER_ANIMATION}`);
    const dimensions = new Set();
    for (let i = 0; i < files.length; i += 1) {
      const match = frameName.exec(files[i]);
      if (!match || match[1] !== state) errors.push(`${entry.name}/${state}/${files[i]}: 帧名应为 ${state}_0001.png 格式`);
      else if (Number(match[2]) !== i + 1) errors.push(`${entry.name}/${state}: 帧编号不连续，发现 ${files[i]}`);
      try {
        const framePath = path.join(directory, files[i]);
        const frameStat = await stat(framePath);
        if (frameStat.size > MAX_FRAME_BYTES) { errors.push(`${entry.name}/${state}/${files[i]}: 文件超过 16 MiB 上限`); continue; }
        const frameBuffer = await readFile(framePath);
        if (frameBuffer.length < 26 || frameBuffer.toString("ascii", 1, 4) !== "PNG") { errors.push(`${entry.name}/${state}/${files[i]}: PNG 文件头无效`); continue; }
        const headerWidth = frameBuffer.readUInt32BE(16);
        const headerHeight = frameBuffer.readUInt32BE(20);
        const colorType = frameBuffer[25];
        if (headerWidth > MAX_CANVAS_EDGE || headerHeight > MAX_CANVAS_EDGE) { errors.push(`${entry.name}/${state}/${files[i]}: 画布超过 ${MAX_CANVAS_EDGE}px 上限`); continue; }
        if (colorType !== 6) errors.push(`${entry.name}/${state}/${files[i]}: 必须使用 RGBA PNG（color type 6）`);
        const png = PNG.sync.read(frameBuffer);
        dimensions.add(`${png.width}x${png.height}`);
        if (png.width !== manifest.frameSize?.width || png.height !== manifest.frameSize?.height) errors.push(`${entry.name}/${state}/${files[i]}: 尺寸 ${png.width}x${png.height} 与 manifest 不一致`);
        let hasTransparentPixel = false;
        for (let alpha = 3; alpha < png.data.length; alpha += 4) { if (png.data[alpha] < 255) { hasTransparentPixel = true; break; } }
        if (!hasTransparentPixel) errors.push(`${entry.name}/${state}/${files[i]}: 未检测到透明背景`);
      } catch (error) { errors.push(`${entry.name}/${state}/${files[i]}: PNG 损坏: ${error.message}`); }
    }
    if (dimensions.size > 1) errors.push(`${entry.name}/${state}: 同一动作画布尺寸不一致`);
    frameIndex.animations[state] = files.map((file) => path.posix.join(animation.path.replaceAll("\\", "/"), file));
  }
  await writeFile(path.join(characterRoot, "frames.json"), JSON.stringify(frameIndex, null, 2) + "\n");
  index.push({ id: manifest.id, name: manifest.name, manifest: `/characters/${manifest.id}/manifest.json` });
  console.log(`✓ ${manifest.id}: ${Object.keys(frameIndex.animations).length} 个动作`);
}

const indexPath = path.join(root, "index.json");
let currentIndex = null;
try {
  currentIndex = JSON.parse(await readFile(indexPath, "utf8"));
} catch {
  // A missing or malformed generated index is replaced after validation succeeds.
}

if (JSON.stringify(currentIndex?.characters) !== JSON.stringify(index)) {
  await writeFile(
    indexPath,
    JSON.stringify({ generatedAt: new Date().toISOString(), characters: index }, null, 2) + "\n",
  );
}
console.log(`发现 ${index.length} 个角色。`);
for (const warning of warnings) console.warn(`警告: ${warning}`);
if (errors.length) { for (const error of errors) console.error(`错误: ${error}`); process.exitCode = 1; }
else console.log("角色资源校验通过。");
