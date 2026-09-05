const fs = require('fs');
const path = require('path');
const { Readable, Transform } = require('stream');
const { pipeline } = require('stream/promises');

function strongEtag(value) {
  const tag = String(value || '').trim();
  return /^"[^"\r\n]*"$/.test(tag) ? tag : '';
}

// A partial belongs to the GET representation that produced its bytes, never
// to a version label, URL or an earlier HEAD response alone.
async function downloadArtifact(requestUrl, destPath, onProgress = () => {}, options = {}) {
  const metadataPath = `${destPath}.resume.json`;
  let partial = null;
  let offset = 0;
  if (options.resume === true) {
    try {
      partial = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
      const stat = fs.statSync(destPath);
      if (stat.isFile() && partial.url === requestUrl && strongEtag(partial.etag) &&
          stat.size > 0 && Number.isSafeInteger(partial.total) && partial.total > stat.size) {
        offset = stat.size;
      }
    } catch (_) {}
  }
  const controller = new AbortController();
  const inactivityMs = Math.max(5000, Number(options.timeoutMs) || 120000);
  let timer;
  const armTimeout = () => {
    clearTimeout(timer);
    timer = setTimeout(() => controller.abort(), inactivityMs);
  };
  armTimeout();
  try {
    const headers = { ...options.headers, 'Accept-Encoding': 'identity' };
    if (offset) {
      headers.Range = `bytes=${offset}-`;
      headers['If-Range'] = partial.etag;
    }
    const response = await (options.fetch || fetch)(requestUrl, { headers, signal: controller.signal });
    const etag = strongEtag(response.headers.get('etag'));
    const encoding = String(response.headers.get('content-encoding') || '').toLowerCase();
    const encoded = encoding && encoding !== 'identity';
    const range = String(response.headers.get('content-range') || '').match(/^bytes\s+(\d+)-(\d+)\/(\d+)$/i);
    const length = Number(response.headers.get('content-length')) || 0;
    const resumed = Boolean(offset && response.status === 206 && range &&
      etag === partial.etag && !encoded && Number(range[1]) === offset &&
      Number(range[3]) === partial.total && Number(range[2]) === partial.total - 1 &&
      (!length || length === partial.total - offset));
    if (offset && (response.status === 416 || (response.status === 206 && !resumed))) {
      await response.body?.cancel().catch(() => {});
      controller.abort();
      clearTimeout(timer);
      return downloadArtifact(requestUrl, destPath, onProgress, { ...options, resume: false });
    }
    if (!response.ok) throw new Error(`Falha ao baixar o arquivo: HTTP ${response.status}`);
    // An unsolicited 206 cannot safely be saved as a complete file.
    if (response.status === 206 && !resumed) throw new Error('O servidor devolveu uma faixa inválida do download.');
    if (!resumed) offset = 0;
    const total = resumed ? partial.total : (encoded ? 0 : length);
    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    if (!resumed) {
      // Truncate before changing the validator: a crash must never relabel old
      // bytes with the ETag of the next publication.
      fs.writeFileSync(destPath, Buffer.alloc(0));
      fs.rmSync(metadataPath, { force: true });
      if (etag && total > 0 && !encoded) {
        fs.writeFileSync(metadataPath, JSON.stringify({ url: requestUrl, etag, total }), 'utf8');
      }
    }
    let downloaded = offset;
    const report = () => onProgress(total ? Math.min(99, Math.round(downloaded / total * 100)) : 0,
      { downloaded, total, resumed });
    report();
    const progress = new Transform({
      transform(chunk, _encoding, callback) {
        downloaded += chunk.length;
        armTimeout();
        if (total && downloaded > total) return callback(new Error('O servidor enviou mais dados que o tamanho esperado.'));
        try { report(); callback(null, chunk); } catch (error) { callback(error); }
      }
    });
    const source = response.body && typeof response.body.getReader === 'function'
      ? Readable.fromWeb(response.body)
      : Readable.from([Buffer.from(await response.arrayBuffer())]);
    await pipeline(source, progress, fs.createWriteStream(destPath, { flags: 'a' }), { signal: controller.signal });
    if (!downloaded || (total && downloaded !== total)) throw new Error('O download terminou incompleto.');
    fs.rmSync(metadataPath, { force: true });
    onProgress(100, { downloaded, total: total || downloaded, resumed });
    return { downloaded, total };
  } catch (error) {
    if (error?.name === 'AbortError') throw new Error('O download ficou sem resposta e foi interrompido.');
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { downloadArtifact };
