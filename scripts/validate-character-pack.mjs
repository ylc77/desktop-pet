import { randomUUID } from "node:crypto";
import { lstat, open, readFile, readdir, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { PNG } from "pngjs";

const rootArgumentIndex = process.argv.indexOf("--root");
const requestedRoot = rootArgumentIndex >= 0 ? process.argv[rootArgumentIndex + 1] : "public/characters";
if (!requestedRoot) throw new Error("--root requires a directory path");
const root = path.resolve(requestedRoot);
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
const MAX_ENTRIES = 2_500;
const MAX_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAX_DECODED_FRAME_PIXELS = 256 * 1024 * 1024;
const PUBLIC_CHARACTER_ROOT = path.resolve("public/characters");
const isPublicCharacterRoot = root === PUBLIC_CHARACTER_ROOT;
const prohibitedPackageExtensions = new Set([
  "exe", "dll", "com", "scr", "msi", "msp", "bat", "cmd", "ps1", "psm1", "psd1",
  "vbs", "vbe", "js", "mjs", "cjs", "html", "htm", "hta", "svg", "jar", "lnk",
  "url", "reg", "chm",
]);
const assetRules = {
  preview: { maxBytes: 8 * 1024 * 1024, minWidth: 64, minHeight: 64, maxWidth: 2048, maxHeight: 2048, square: false },
  icon: { maxBytes: 2 * 1024 * 1024, minWidth: 32, minHeight: 32, maxWidth: 512, maxHeight: 512, square: true },
};

async function exists(file) { try { await readFile(file); return true; } catch { return false; } }

async function hasNonEmptyText(file) {
  try {
    const fileStat = await stat(file);
    return fileStat.isFile() && (await readFile(file, "utf8")).trim().length > 0;
  } catch {
    return false;
  }
}

function optionalIndexValue(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function asciiLower(value) {
  return value.replace(/[A-Z]/gu, (character) => String.fromCharCode(character.charCodeAt(0) + 32));
}

function asciiUpper(value) {
  return value.replace(/[a-z]/gu, (character) => String.fromCharCode(character.charCodeAt(0) - 32));
}

function isReservedWindowsComponent(component) {
  const base = asciiUpper(component.split(".", 1)[0]);
  return ["CON", "PRN", "AUX", "NUL"].includes(base) || /^(?:COM|LPT)[1-9]$/u.test(base);
}

function isSafePackageRelativePath(value) {
  if (typeof value !== "string" || !value || Buffer.byteLength(value, "utf8") > 240 || value.startsWith("/") || value.includes("\\")) return false;
  const components = value.split("/");
  return components.every((component) => component
    && component !== "."
    && component !== ".."
    && !component.endsWith(".")
    && !component.endsWith(" ")
    && !/[<>:"|?*\p{Cc}]/u.test(component)
    && !isReservedWindowsComponent(component));
}

async function inspectGeneratedFileTarget(file, label) {
  let metadata;
  try {
    metadata = await lstat(file);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new Error(`${label} 无法检查 (${error.message})`);
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} 必须为非链接的普通文件`);
  }
  if (Number.isInteger(metadata.nlink) && metadata.nlink > 1) {
    throw new Error(`${label} 不能为硬链接`);
  }
  return {
    dev: metadata.dev,
    ino: metadata.ino,
    nlink: metadata.nlink,
    size: metadata.size,
    mtimeMs: metadata.mtimeMs,
  };
}

function generatedFileTargetUnchanged(before, after) {
  if (before === null || after === null) return before === after;
  return before.dev === after.dev
    && before.ino === after.ino
    && before.nlink === after.nlink
    && before.size === after.size
    && before.mtimeMs === after.mtimeMs;
}

async function writeGeneratedFileAtomically(file, content, label) {
  const directory = path.dirname(file);
  const directoryMetadata = await lstat(directory);
  if (directoryMetadata.isSymbolicLink() || !directoryMetadata.isDirectory()) {
    throw new Error(`${label} 的父目录必须为非链接的普通目录`);
  }
  const before = await inspectGeneratedFileTarget(file, label);
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${randomUUID()}.tmp`);
  let handle;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(content, "utf8");
    await handle.sync();
    await handle.close();
    handle = null;
    const after = await inspectGeneratedFileTarget(file, label);
    if (!generatedFileTargetUnchanged(before, after)) {
      throw new Error(`${label} 在生成期间被替换，已拒绝覆盖`);
    }
    await rename(temporary, file);
  } finally {
    if (handle) await handle.close().catch(() => {});
    await unlink(temporary).catch(() => {});
  }
}

let rootMetadata;
try {
  rootMetadata = await lstat(root);
} catch (error) {
  throw new Error(`角色根目录无法检查 (${error.message})`);
}
if (rootMetadata.isSymbolicLink() || !rootMetadata.isDirectory()) {
  throw new Error("角色根目录必须为非链接的普通目录");
}

const indexPath = path.join(root, "index.json");
let currentIndex = null;
try {
  const indexMetadata = await inspectGeneratedFileTarget(indexPath, "index.json");
  if (indexMetadata) {
    try {
      currentIndex = JSON.parse(await readFile(indexPath, "utf8"));
    } catch {
      // A malformed generated index is safely replaced only after validation succeeds.
    }
  }
} catch (error) {
  errors.push(`index.json 不安全: ${error.message}`);
}

async function validateDeclaredFileSet(characterRoot, entryName, manifest, preview, icon, frameIndex) {
  const initialErrorCount = errors.length;
  let fileCount = 0;
  let totalBytes = 0;
  let framesExistingBytes = null;
  const allowed = new Set([
    "manifest.json",
    "frames.json",
    "metadata/source.md",
    "metadata/license.md",
  ]);
  for (const relative of [preview, icon]) if (relative) allowed.add(asciiLower(relative));
  for (const frames of Object.values(frameIndex.animations)) {
    for (const relative of frames) allowed.add(asciiLower(relative));
  }
  if (manifest.skins !== undefined) {
    if (!manifest.skins || typeof manifest.skins !== "object" || Array.isArray(manifest.skins)) {
      errors.push(`${entryName}: skins 必须为对象`);
    } else {
      for (const id of Object.keys(manifest.skins)) {
        const relative = `skins/${id}/skin.json`;
        if (!isSafePackageRelativePath(relative)) errors.push(`${entryName}: skins.${id} 路径无效`);
        else allowed.add(asciiLower(relative));
      }
    }
  }

  async function visit(directory) {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      errors.push(`${entryName}: 角色目录无法读取 (${error.message})`);
      return;
    }
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      const relative = path.relative(characterRoot, absolute).split(path.sep).join("/");
      if (!isSafePackageRelativePath(relative)) {
        errors.push(`${entryName}: 包含无效文件路径 ${relative}`);
        continue;
      }
      let entryStat;
      try {
        entryStat = await lstat(absolute);
      } catch (error) {
        errors.push(`${entryName}: 角色包文件无法检查: ${relative} (${error.message})`);
        continue;
      }
      if (entry.isSymbolicLink() || entryStat.isSymbolicLink()) {
        errors.push(`${entryName}: 角色包不能包含符号链接或重解析点: ${relative}`);
      } else if (entryStat.isDirectory()) {
        await visit(absolute);
      } else if (entryStat.isFile()) {
        fileCount += 1;
        totalBytes += entryStat.size;
        if (asciiLower(relative) === "frames.json") framesExistingBytes = entryStat.size;
        if (Number.isInteger(entryStat.nlink) && entryStat.nlink > 1) {
          errors.push(`${entryName}: 角色包不能包含硬链接: ${relative}`);
          continue;
        }
        const extension = path.posix.extname(relative).slice(1).toLowerCase();
        if (prohibitedPackageExtensions.has(extension)) {
          errors.push(`${entryName}: 角色包包含禁止的可执行或脚本文件: ${relative}`);
        } else if (!allowed.has(asciiLower(relative))) {
          errors.push(`${entryName}: 角色包包含未声明文件: ${relative}`);
        }
      } else {
        errors.push(`${entryName}: 角色包包含非常规文件: ${relative}`);
      }
    }
  }
  await visit(characterRoot);
  return {
    safe: errors.length === initialErrorCount,
    fileCount,
    totalBytes,
    framesExistingBytes,
  };
}

async function validateDisplayAsset(characterRoot, entryName, assetName, relative) {
  if (relative === undefined) return null;
  if (typeof relative !== "string" || !relative.trim()) {
    errors.push(`${entryName}: ${assetName} 必须为角色目录内的非空相对路径`);
    return null;
  }
  if (!isSafePackageRelativePath(relative)) {
    errors.push(`${entryName}: ${assetName} 路径越出角色目录`);
    return null;
  }
  if (!relative.endsWith(".png")) {
    errors.push(`${entryName}: ${assetName} 必须使用小写 .png 扩展名`);
    return null;
  }
  const assetPath = path.resolve(characterRoot, relative);
  if (!assetPath.startsWith(`${characterRoot}${path.sep}`)) {
    errors.push(`${entryName}: ${assetName} 路径越出角色目录`);
    return null;
  }
  let assetStat;
  let buffer;
  try {
    assetStat = await stat(assetPath);
    if (!assetStat.isFile()) throw new Error("不是普通文件");
    buffer = await readFile(assetPath);
  } catch (error) {
    errors.push(`${entryName}: ${assetName} 文件无法读取: ${relative} (${error.message})`);
    return null;
  }
  const rules = assetRules[assetName];
  if (assetStat.size > rules.maxBytes) {
    errors.push(`${entryName}: ${assetName} 文件超过 ${rules.maxBytes / 1024 / 1024} MiB 上限`);
    return null;
  }
  const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (buffer.length < 26 || !buffer.subarray(0, 8).equals(pngSignature)) {
    errors.push(`${entryName}: ${assetName} 必须为有效 PNG 文件`);
    return null;
  }
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  if (width < rules.minWidth || height < rules.minHeight || width > rules.maxWidth || height > rules.maxHeight) {
    errors.push(`${entryName}: ${assetName} 尺寸 ${width}x${height} 超出 ${rules.minWidth}x${rules.minHeight} 至 ${rules.maxWidth}x${rules.maxHeight} 范围`);
    return null;
  }
  if (rules.square && width !== height) {
    errors.push(`${entryName}: icon 必须为正方形 PNG，当前为 ${width}x${height}`);
    return null;
  }
  try {
    PNG.sync.read(buffer);
  } catch (error) {
    errors.push(`${entryName}: ${assetName} PNG 损坏: ${error.message}`);
    return null;
  }
  return relative.replaceAll("\\", "/");
}

const pendingFrameWrites = [];
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
  if (typeof manifest.name !== "string" || !manifest.name.trim()) errors.push(`${entry.name}: name 必须为非空字符串`);
  for (const field of ["version", "author", "license"]) {
    if (typeof manifest[field] !== "string" || !manifest[field].trim()) errors.push(`${entry.name}: ${field} 必须为非空字符串`);
  }
  if (isPublicCharacterRoot && entry.name !== "_placeholder") {
    for (const metadataFile of ["metadata/source.md", "metadata/license.md"]) {
      const metadataPath = path.join(characterRoot, ...metadataFile.split("/"));
      if (!(await hasNonEmptyText(metadataPath))) errors.push(`${entry.name}: 公开内置角色必须提供非空的 ${metadataFile}`);
    }
  }
  if (!manifest.animations?.idle) errors.push(`${entry.name}: 缺少必需 idle 动画`);
  if (!Number.isFinite(manifest.defaultScale) || manifest.defaultScale <= 0 || manifest.defaultScale > 4) errors.push(`${entry.name}: defaultScale 必须为 0-4 范围内的正数`);
  if (!Number.isInteger(manifest.frameSize?.width) || !Number.isInteger(manifest.frameSize?.height) || manifest.frameSize.width < 16 || manifest.frameSize.height < 16 || manifest.frameSize.width > MAX_CANVAS_EDGE || manifest.frameSize.height > MAX_CANVAS_EDGE) errors.push(`${entry.name}: frameSize 必须为 16-${MAX_CANVAS_EDGE} 的整数`);
  if (!Number.isFinite(manifest.anchor?.x) || !Number.isFinite(manifest.anchor?.y) || manifest.anchor.x < 0 || manifest.anchor.x > 1 || manifest.anchor.y < 0 || manifest.anchor.y > 1) errors.push(`${entry.name}: anchor 必须位于 0-1 范围内`);
  if (manifest.hitbox) {
    const box = manifest.hitbox;
    if (![box.x, box.y, box.width, box.height].every(Number.isFinite) || box.x < 0 || box.y < 0 || box.width <= 0 || box.height <= 0 || box.x + box.width > 1 || box.y + box.height > 1) errors.push(`${entry.name}: hitbox 必须是画布内的归一化矩形`);
  }
  if (manifest.visual !== undefined) {
    const visual = manifest.visual;
    if (!visual || typeof visual !== "object" || Array.isArray(visual)) errors.push(`${entry.name}: visual 必须为对象`);
    else {
      if (visual.dropShadow !== undefined && typeof visual.dropShadow !== "boolean") errors.push(`${entry.name}: visual.dropShadow 必须为布尔值`);
      if (visual.groundShadow !== undefined) {
        const shadow = visual.groundShadow;
        if (!shadow || typeof shadow !== "object" || Array.isArray(shadow)) errors.push(`${entry.name}: visual.groundShadow 必须为对象`);
        else {
          if (typeof shadow.enabled !== "boolean") errors.push(`${entry.name}: visual.groundShadow.enabled 必须为布尔值`);
          if (shadow.width !== undefined && (!Number.isFinite(shadow.width) || shadow.width <= 0 || shadow.width > 2)) errors.push(`${entry.name}: visual.groundShadow.width 必须为 0-2 范围内的正数`);
          if (shadow.height !== undefined && (!Number.isFinite(shadow.height) || shadow.height <= 0 || shadow.height > 1)) errors.push(`${entry.name}: visual.groundShadow.height 必须为 0-1 范围内的正数`);
          if (shadow.opacity !== undefined && (!Number.isFinite(shadow.opacity) || shadow.opacity < 0 || shadow.opacity > 0.5)) errors.push(`${entry.name}: visual.groundShadow.opacity 必须为 0-0.5`);
          if (shadow.blur !== undefined && (!Number.isFinite(shadow.blur) || shadow.blur < 0 || shadow.blur > 32)) errors.push(`${entry.name}: visual.groundShadow.blur 必须为 0-32`);
        }
      }
    }
  }
  const preview = await validateDisplayAsset(characterRoot, entry.name, "preview", manifest.preview);
  const icon = await validateDisplayAsset(characterRoot, entry.name, "icon", manifest.icon);
  const frameIndex = { animations: {} };
  let decodedFramePixels = 0;
  let decodedPixelLimitExceeded = false;
  for (const [state, animation] of Object.entries(manifest.animations ?? {})) {
    if (!stateName.test(state)) { errors.push(`${entry.name}/${state}: 动作名无效`); continue; }
    if (!isSafePackageRelativePath(animation.path)) { errors.push(`${entry.name}/${state}: 动画路径越出角色目录`); continue; }
    if (!(animation.fps >= 1 && animation.fps <= 60)) errors.push(`${entry.name}/${state}: FPS 必须为 1-60`);
    if (typeof animation.loop !== "boolean") errors.push(`${entry.name}/${state}: loop 必须为布尔值`);
    if (animation.priority !== undefined && (!Number.isInteger(animation.priority) || animation.priority < 0 || animation.priority > 1000)) errors.push(`${entry.name}/${state}: priority 必须为 0-1000 的整数`);
    if (animation.weight !== undefined && (!Number.isFinite(animation.weight) || animation.weight < 0 || animation.weight > 1000)) errors.push(`${entry.name}/${state}: weight 必须为 0-1000`);
    for (const field of ["minDelayMs", "maxDelayMs"]) if (animation[field] !== undefined && (!Number.isInteger(animation[field]) || animation[field] < 0)) errors.push(`${entry.name}/${state}: ${field} 必须为非负整数`);
    if (animation.minDelayMs !== undefined && animation.maxDelayMs !== undefined && animation.minDelayMs > animation.maxDelayMs) errors.push(`${entry.name}/${state}: minDelayMs 不能大于 maxDelayMs`);
    if (animation.minDurationMs !== undefined && animation.maxDurationMs !== undefined && animation.minDurationMs > animation.maxDurationMs) errors.push(`${entry.name}/${state}: minDurationMs 不能大于 maxDurationMs`);
    for (const field of ["minDurationMs", "maxDurationMs"]) {
      if (animation[field] !== undefined && (!Number.isInteger(animation[field]) || animation[field] < 100 || animation[field] > 120000)) errors.push(`${entry.name}/${state}: ${field} 必须为 100-120000 ms`);
    }
    for (const field of ["anticipation", "recovery"]) {
      if (animation[field] !== undefined && !stateName.test(animation[field])) errors.push(`${entry.name}/${state}: ${field} 动作名无效`);
    }
    if (animation.movement) {
      const movement = animation.movement;
      if (!Number.isFinite(movement.speed) || movement.speed <= 0 || movement.speed > 500) errors.push(`${entry.name}/${state}: movement.speed 必须为 0-500 范围内的正数`);
      for (const field of ["acceleration", "deceleration"]) if (movement[field] !== undefined && (!Number.isFinite(movement[field]) || movement[field] <= 0 || movement[field] > 2000)) errors.push(`${entry.name}/${state}: movement.${field} 必须为 0-2000 范围内的正数`);
      if (movement.edgePadding !== undefined && (!Number.isFinite(movement.edgePadding) || movement.edgePadding < 0 || movement.edgePadding > 512)) errors.push(`${entry.name}/${state}: movement.edgePadding 必须为 0-512`);
      if (movement.direction !== undefined && !["left", "right"].includes(movement.direction)) errors.push(`${entry.name}/${state}: movement.direction 必须为 left 或 right`);
      if (movement.reverseTo !== undefined && !stateName.test(movement.reverseTo)) errors.push(`${entry.name}/${state}: movement.reverseTo 动作名无效`);
    }
    for (const field of ["offsetX", "offsetY"]) if (animation[field] !== undefined && !Number.isFinite(animation[field])) errors.push(`${entry.name}/${state}: ${field} 必须为有限数值`);
    if (animation.scale !== undefined && (!Number.isFinite(animation.scale) || animation.scale <= 0 || animation.scale > 10)) errors.push(`${entry.name}/${state}: scale 必须为 0-10 范围内的正数`);
    if (animation.flipXAllowed !== undefined && typeof animation.flipXAllowed !== "boolean") errors.push(`${entry.name}/${state}: flipXAllowed 必须为布尔值`);
    const directory = path.resolve(characterRoot, animation.path);
    if (!directory.startsWith(characterRoot + path.sep)) { errors.push(`${entry.name}/${state}: 路径越出角色目录`); continue; }
    let files = [];
    try { files = (await readdir(directory)).filter((file) => file.toLowerCase().endsWith(".png")).sort(); }
    catch { errors.push(`${entry.name}/${state}: 动画目录不存在`); continue; }
    if (files.length === 0) { errors.push(`${entry.name}/${state}: 没有 PNG 帧`); continue; }
    if (files.length > MAX_FRAMES_PER_ANIMATION) errors.push(`${entry.name}/${state}: 帧数 ${files.length} 超过上限 ${MAX_FRAMES_PER_ANIMATION}`);
    if (!decodedPixelLimitExceeded
      && Number.isInteger(manifest.frameSize?.width)
      && Number.isInteger(manifest.frameSize?.height)) {
      decodedFramePixels += manifest.frameSize.width * manifest.frameSize.height * files.length;
      if (decodedFramePixels > MAX_DECODED_FRAME_PIXELS) {
        decodedPixelLimitExceeded = true;
        errors.push(`${entry.name}: 角色帧总解码像素超过 ${MAX_DECODED_FRAME_PIXELS} 上限`);
      }
    }
    const dimensions = new Set();
    for (let i = 0; i < files.length; i += 1) {
      const match = frameName.exec(files[i]);
      if (!match || match[1] !== state) errors.push(`${entry.name}/${state}/${files[i]}: 帧名应为 ${state}_0001.png 格式`);
      else if (Number(match[2]) !== i + 1) errors.push(`${entry.name}/${state}: 帧编号不连续，发现 ${files[i]}`);
      if (decodedPixelLimitExceeded) continue;
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
  for (const [state, animation] of Object.entries(manifest.animations ?? {})) {
    for (const field of ["returnTo", "anticipation", "recovery"]) {
      const target = animation?.[field];
      if (target && !manifest.animations?.[target]) warnings.push(`${entry.name}/${state}: ${field} 指向缺失动作 ${target}`);
    }
    const reverseTarget = animation?.movement?.reverseTo;
    if (reverseTarget && !manifest.animations?.[reverseTarget]) warnings.push(`${entry.name}/${state}: movement.reverseTo 指向缺失动作 ${reverseTarget}`);
  }
  const generatedFrames = JSON.stringify(frameIndex, null, 2) + "\n";
  const packageFileSet = await validateDeclaredFileSet(characterRoot, entry.name, manifest, preview, icon, frameIndex);
  let resourceLimitExceeded = decodedPixelLimitExceeded;
  const projectedEntries = packageFileSet.fileCount + (packageFileSet.framesExistingBytes === null ? 1 : 0);
  if (projectedEntries > MAX_ENTRIES) {
    errors.push(`${entry.name}: 角色包文件数 ${projectedEntries} 超过上限 ${MAX_ENTRIES}`);
    resourceLimitExceeded = true;
  }
  const projectedBytes = packageFileSet.totalBytes
    - (packageFileSet.framesExistingBytes ?? 0)
    + Buffer.byteLength(generatedFrames, "utf8");
  if (projectedBytes > MAX_ARCHIVE_BYTES) {
    errors.push(`${entry.name}: 角色包文件总大小超过 512 MiB 上限`);
    resourceLimitExceeded = true;
  }
  if (packageFileSet.safe && !resourceLimitExceeded) {
    pendingFrameWrites.push({
      file: path.join(characterRoot, "frames.json"),
      content: generatedFrames,
      label: `${entry.name}/frames.json`,
    });
  }
  index.push({
    id: manifest.id,
    name: manifest.name,
    version: optionalIndexValue(manifest.version),
    author: optionalIndexValue(manifest.author),
    license: optionalIndexValue(manifest.license),
    preview: preview ? `/characters/${manifest.id}/${preview}` : null,
    icon: icon ? `/characters/${manifest.id}/${icon}` : null,
    manifest: `/characters/${manifest.id}/manifest.json`,
  });
  console.log(`✓ ${manifest.id}: ${Object.keys(frameIndex.animations).length} 个动作`);
}

if (errors.length === 0) {
  try {
    for (const pending of pendingFrameWrites) {
      await writeGeneratedFileAtomically(pending.file, pending.content, pending.label);
    }
    if (JSON.stringify(currentIndex?.characters) !== JSON.stringify(index)) {
      await writeGeneratedFileAtomically(
        indexPath,
        JSON.stringify({ generatedAt: new Date().toISOString(), characters: index }, null, 2) + "\n",
        "index.json",
      );
    }
  } catch (error) {
    errors.push(`生成文件安全写入失败: ${error.message}`);
  }
}
console.log(`发现 ${index.length} 个角色。`);
for (const warning of warnings) console.warn(`警告: ${warning}`);
if (errors.length) { for (const error of errors) console.error(`错误: ${error}`); process.exitCode = 1; }
else console.log("角色资源校验通过。");
