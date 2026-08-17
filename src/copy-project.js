const fs = require('fs')
const path = require('path')
const os = require('os')
const http = require('http')
const dgram = require('dgram')
const crypto = require('crypto')

const COPY_PROJECT_VERSION = 2
const COPY_PROJECT_HTTP_PORT = 47835
const COPY_PROJECT_DISCOVERY_PORT = 47836
const COPY_PROJECT_MAGIC = 'VS_HOOK_TRANSFER_HOOK_V2'
const COPY_PROJECT_CHUNK_BYTES = 1024 * 1024
const COPY_PROJECT_MAX_FILES = 100000
const COPY_PROJECT_MAX_TOTAL_BYTES = 512 * 1024 * 1024 * 1024
const COPY_PROJECT_MAX_MANIFEST_BYTES = 32 * 1024 * 1024

function normalizeAddress(value) {
  return String(value || '').replace(/^::ffff:/i, '').trim()
}

function randomCode() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, '0')
}

function safeToken(value) {
  const token = String(value || '').trim()
  return /^[a-f0-9]{64}$/i.test(token) ? token.toLowerCase() : ''
}

function safeTransferId(value) {
  const id = String(value || '').trim().toLowerCase()
  return /^[a-f0-9]{64}$/.test(id) ? id : ''
}

function waitMs(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

function responseError(message, statusCode) {
  const error = new Error(message)
  error.statusCode = Number(statusCode) || 0
  return error
}

function isRetryableNetworkError(error) {
  if (Number(error?.statusCode) > 0) return false
  return ['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EHOSTUNREACH',
    'ENETUNREACH', 'ENETDOWN', 'EPIPE', 'EAI_AGAIN'].includes(error?.code) ||
    /tempo de rede|tempo de envio|socket hang up|network|fetch failed|pc receptor não encontrado/i
      .test(String(error?.message || ''))
}

function safeCode(value) {
  const code = String(value || '').replace(/\D/g, '').slice(0, 6)
  return code.length === 6 ? code : ''
}

function safeRelativePath(value) {
  const raw = String(value || '').replace(/\\/g, '/').trim()
  if (!raw || raw.length > 4096 || raw.startsWith('/') ||
      /^[A-Za-z]:/.test(raw) || /[\u0000-\u001f\u007f]/.test(raw)) return ''
  const parts = raw.split('/')
  if (parts.some((part) => !part || part === '.' || part === '..' ||
      part.length > 255 || /[. ]$/.test(part) ||
      /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) return ''
  return parts.join('/')
}

function safeRootName(value) {
  const name = String(value || '').replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
    .replace(/[. ]+$/g, '').trim().slice(0, 180)
  return name || 'Transfer Hook'
}

function pathIdentity(value) {
  const resolved = path.resolve(value)
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved
}

function resolveInside(root, relative) {
  const safe = safeRelativePath(relative)
  if (!safe) return ''
  const base = path.resolve(root)
  const target = path.resolve(base, ...safe.split('/'))
  const rel = path.relative(base, target)
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return ''
  return target
}

async function ensureSafeDirectory(root, directory) {
  const base = path.resolve(root)
  const target = path.resolve(directory)
  const rel = path.relative(base, target)
  if (rel.startsWith('..') || path.isAbsolute(rel)) {
    throw new Error('A pasta de destino saiu da raiz escolhida.')
  }
  let current = base
  const baseStat = await fs.promises.lstat(base)
  if (!baseStat.isDirectory() || baseStat.isSymbolicLink()) {
    throw new Error('A pasta escolhida não é um diretório seguro.')
  }
  for (const part of rel.split(path.sep).filter(Boolean)) {
    current = path.join(current, part)
    try {
      const stat = await fs.promises.lstat(current)
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new Error('O destino contém um link ou item inseguro.')
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
      await fs.promises.mkdir(current)
    }
  }
}

async function regularFileStat(filename, expectedSize = -1) {
  const before = await fs.promises.lstat(filename)
  if (!before.isFile() || before.isSymbolicLink() ||
      (expectedSize >= 0 && before.size !== expectedSize)) {
    throw new Error('Arquivo ausente, alterado ou inseguro.')
  }
  const real = await fs.promises.realpath(filename)
  if (pathIdentity(real) !== pathIdentity(filename)) {
    throw new Error('Links simbólicos não são aceitos na transferência.')
  }
  return before
}

function broadcastAddresses() {
  const result = new Set(['255.255.255.255'])
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family !== 'IPv4' || entry.internal || !entry.address ||
          !entry.netmask) continue
      const ip = entry.address.split('.').map(Number)
      const mask = entry.netmask.split('.').map(Number)
      if (ip.length !== 4 || mask.length !== 4) continue
      result.add(ip.map((part, index) =>
        ((part & mask[index]) | (~mask[index] & 255)) >>> 0).join('.'))
    }
  }
  return [...result]
}

function jsonResponse(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8')
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'content-type, range, x-copy-token, x-copy-file-id, x-copy-offset',
  })
  res.end(body)
}

async function readBody(req, maximumBytes) {
  const chunks = []
  let total = 0
  for await (const chunk of req) {
    total += chunk.length
    if (total > maximumBytes) throw new Error('Pacote grande demais.')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks, total)
}

async function requestJson(options, payload, timeoutMs = 10000) {
  const body = Buffer.from(JSON.stringify(payload || {}), 'utf8')
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: options.hostname,
      port: options.port,
      path: options.path,
      method: options.method || 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': body.length,
        'cache-control': 'no-store',
      },
    }, (res) => {
      const chunks = []
      let total = 0
      res.on('data', (chunk) => {
        total += chunk.length
        if (total <= COPY_PROJECT_MAX_MANIFEST_BYTES) chunks.push(chunk)
      })
      res.on('end', () => {
        if (total > COPY_PROJECT_MAX_MANIFEST_BYTES) {
          reject(new Error('Resposta grande demais.'))
          return
        }
        let data = null
        try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch (_) {}
        if (res.statusCode < 200 || res.statusCode >= 300 || !data?.ok) {
          reject(responseError(data?.error || `Falha de rede (${res.statusCode}).`, res.statusCode))
          return
        }
        resolve(data)
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(new Error('Tempo de rede esgotado.')))
    req.once('error', reject)
    req.end(body)
  })
}

async function postChunk(options, buffer, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: options.hostname,
      port: options.port,
      path: '/transfer-hook/file',
      method: 'POST',
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': buffer.length,
        'x-copy-token': options.token,
        'x-copy-file-id': options.fileId,
        'x-copy-offset': String(options.offset),
      },
    }, (res) => {
      const chunks = []
      res.on('data', (chunk) => chunks.push(chunk))
      res.on('end', () => {
        let data = null
        try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch (_) {}
        if (res.statusCode < 200 || res.statusCode >= 300 || !data?.ok) {
          reject(responseError(data?.error || `Falha ao enviar bloco (${res.statusCode}).`, res.statusCode))
          return
        }
        resolve(data)
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(new Error('Tempo de envio esgotado.')))
    req.once('error', reject)
    req.end(buffer)
  })
}

async function collectFolder(sourceRoot, update, isActive) {
  const files = []
  const directories = []
  let totalBytes = 0
  async function walk(directory, relativeBase) {
    isActive()
    const entries = await fs.promises.readdir(directory, { withFileTypes: true })
    entries.sort((a, b) => a.name.localeCompare(b.name))
    for (const entry of entries) {
      isActive()
      const relative = safeRelativePath(relativeBase
        ? `${relativeBase}/${entry.name}` : entry.name)
      if (!relative) throw new Error(`Nome de arquivo incompatível: ${entry.name}`)
      const absolute = path.join(directory, entry.name)
      if (entry.isSymbolicLink()) {
        throw new Error(`Links simbólicos não são transferidos: ${relative}`)
      }
      if (entry.isDirectory()) {
        directories.push(relative)
        await walk(absolute, relative)
      } else if (entry.isFile()) {
        const stat = await regularFileStat(absolute)
        if (files.length >= COPY_PROJECT_MAX_FILES) {
          throw new Error('A pasta possui arquivos demais para uma transferência.')
        }
        totalBytes += stat.size
        if (totalBytes > COPY_PROJECT_MAX_TOTAL_BYTES) {
          throw new Error('A pasta excede o limite de 512 GB por transferência.')
        }
        files.push({
          id: `file-${files.length + 1}`,
          relativePath: relative,
          absolutePath: absolute,
          size: stat.size,
          mtimeMs: stat.mtimeMs,
          ctimeMs: stat.ctimeMs,
        })
        if (files.length === 1 || files.length % 25 === 0) {
          update({ phase: 'preparing', fileIndex: files.length,
            fileCount: files.length, currentFile: relative,
            totalBytes, bytesDone: 0 })
        }
      }
    }
  }
  await walk(sourceRoot, '')
  return { files, directories, totalBytes }
}

async function collectTransferSource(sourcePath, update, isActive) {
  const sourceRoot = path.resolve(String(sourcePath || ''))
  const sourceStat = await fs.promises.lstat(sourceRoot)
  if (sourceStat.isSymbolicLink()) {
    throw new Error('Links simbólicos não são aceitos na transferência.')
  }
  if (sourceStat.isDirectory()) {
    return { ...(await collectFolder(sourceRoot, update, isActive)), sourceKind: 'folder' }
  }
  if (!sourceStat.isFile()) {
    throw new Error('Escolha um arquivo ou uma pasta válida para transferir.')
  }
  isActive()
  const stat = await regularFileStat(sourceRoot)
  if (stat.size > COPY_PROJECT_MAX_TOTAL_BYTES) {
    throw new Error('O arquivo excede o limite de 512 GB por transferência.')
  }
  const relativePath = safeRelativePath(path.basename(sourceRoot))
  if (!relativePath) throw new Error('O nome do arquivo não é compatível com a transferência.')
  update({ phase: 'preparing', fileIndex: 1, fileCount: 1,
    currentFile: relativePath, totalBytes: stat.size, bytesDone: 0 })
  return {
    sourceKind: 'file',
    directories: [],
    totalBytes: stat.size,
    files: [{
      id: 'file-1', relativePath, absolutePath: sourceRoot,
      size: stat.size, mtimeMs: stat.mtimeMs, ctimeMs: stat.ctimeMs,
    }],
  }
}

function createCopyProjectService({ getDeviceName, getFixedCode, onState } = {}) {
  let state = {
    mode: '', phase: 'idle', code: '', sourcePath: '', destinationPath: '',
    rootName: '', peerName: '', bytesDone: 0, totalBytes: 0,
    fileIndex: 0, fileCount: 0, currentFile: '', error: '', result: '',
    receivedPath: '',
  }
  let httpServer = null
  let udpSocket = null
  let beaconTimer = null
  let receiverRoot = ''
  let receiverCode = ''
  let inbound = null
  let sharedFolder = null
  let shareCode = ''
  let operationGeneration = 0
  const fixedCode = (() => {
    try { return safeCode(getFixedCode?.()) || randomCode() } catch (_) { return randomCode() }
  })()
  const discovered = new Map()

  function publicState() {
    return { ...state, receiving: !!receiverCode, sharing: !!shareCode,
      shareCode, fixedCode, protocolVersion: COPY_PROJECT_VERSION }
  }

  function update(patch) {
    state = { ...state, ...patch }
    if (typeof onState === 'function') onState(publicState())
    return publicState()
  }

  function activeGeneration(generation) {
    if (generation !== operationGeneration) throw new Error('Transferência cancelada.')
  }

  async function cleanupInboundPartials() {
    const current = inbound
    inbound = null
    if (!current?.files) return
    await Promise.allSettled([...current.files.values()].map(async (file) => {
      if (!file?.partial) return
      try { await fs.promises.unlink(file.partial) } catch (error) {
        if (error?.code !== 'ENOENT') throw error
      }
    }))
  }

  function beaconPayload() {
    return Buffer.from(JSON.stringify({
      magic: COPY_PROJECT_MAGIC,
      version: COPY_PROJECT_VERSION,
      role: 'receiver',
      code: receiverCode,
      port: COPY_PROJECT_HTTP_PORT,
      name: String(getDeviceName?.() || os.hostname() || 'Hook Center').slice(0, 120),
      timestamp: Date.now(),
    }), 'utf8')
  }

  function sendBeacon(address = '') {
    if (!udpSocket || !receiverCode) return
    const payload = beaconPayload()
    const targets = address ? [address] : broadcastAddresses()
    for (const target of targets) {
      try { udpSocket.send(payload, COPY_PROJECT_DISCOVERY_PORT, target) } catch (_) {}
    }
  }

  async function ensureUdp() {
    if (udpSocket) return
    udpSocket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    udpSocket.on('message', (message, remote) => {
      if (message.length > 8192) return
      let payload
      try { payload = JSON.parse(message.toString('utf8')) } catch (_) { return }
      if (payload?.magic !== COPY_PROJECT_MAGIC ||
          Number(payload.version) !== COPY_PROJECT_VERSION) return
      if (payload.role === 'query') {
        if (receiverCode && safeCode(payload.code) === receiverCode) {
          sendBeacon(normalizeAddress(remote.address))
        }
        return
      }
      if (payload.role !== 'receiver') return
      const code = safeCode(payload.code)
      const address = normalizeAddress(remote.address)
      const port = Number(payload.port)
      if (!code || !address || port !== COPY_PROJECT_HTTP_PORT) return
      discovered.set(code, { address, port, name: String(payload.name || ''), at: Date.now() })
    })
    udpSocket.on('error', () => {})
    await new Promise((resolve, reject) => {
      udpSocket.once('error', reject)
      udpSocket.bind(COPY_PROJECT_DISCOVERY_PORT, '0.0.0.0', () => {
        udpSocket.removeListener('error', reject)
        try { udpSocket.setBroadcast(true) } catch (_) {}
        resolve()
      })
    })
  }

  async function findReceiver(code, generation) {
    await ensureUdp()
    const deadline = Date.now() + 8000
    while (Date.now() < deadline) {
      activeGeneration(generation)
      const peer = discovered.get(code)
      if (peer && Date.now() - peer.at < 10000) return peer
      const query = Buffer.from(JSON.stringify({
        magic: COPY_PROJECT_MAGIC,
        version: COPY_PROJECT_VERSION,
        role: 'query', code,
      }), 'utf8')
      for (const target of broadcastAddresses()) {
        try { udpSocket.send(query, COPY_PROJECT_DISCOVERY_PORT, target) } catch (_) {}
      }
      await new Promise((resolve) => setTimeout(resolve, 400))
    }
    throw new Error('PC receptor não encontrado. Confira o código e a rede.')
  }

  async function replaceFromPartial(partial, target, token) {
    const backup = `${target}.vshook-${token.slice(0, 12)}.replaced`
    let hadTarget = false
    await fs.promises.unlink(backup).catch((error) => {
      if (error?.code !== 'ENOENT') throw error
    })
    try {
      await regularFileStat(target)
      await fs.promises.rename(target, backup)
      hadTarget = true
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
    try {
      await fs.promises.rename(partial, target)
    } catch (error) {
      if (hadTarget) {
        await fs.promises.rename(backup, target).catch(() => {})
      }
      throw error
    }
    if (hadTarget) await fs.promises.unlink(backup).catch(() => {})
  }

  async function prepareInbound(manifest, remoteAddress) {
    if (!receiverCode || !receiverRoot) throw new Error('O recebimento não está ativo.')
    const transferId = safeTransferId(manifest?.transferId) ||
      crypto.createHash('sha256').update(JSON.stringify({
        code: safeCode(manifest?.code),
        rootName: String(manifest?.rootName || ''),
        files: Array.isArray(manifest?.files) ? manifest.files : [],
        directories: Array.isArray(manifest?.directories) ? manifest.directories : []
      })).digest('hex')
    if (!manifest || manifest.schemaVersion !== 1 ||
        safeCode(manifest.code) !== receiverCode ||
        !Array.isArray(manifest.files) || !Array.isArray(manifest.directories) ||
        manifest.files.length > COPY_PROJECT_MAX_FILES) {
      throw new Error('Manifesto de transferência inválido.')
    }
    if (inbound && inbound.transferId === transferId &&
        [...inbound.files.values()].every((file) => file.complete)) {
      inbound.remoteAddress = remoteAddress
      return { token: inbound.token, missing: [], offsets: {},
        targetRoot: inbound.targetRoot, resumed: true, completed: true }
    }
    if (inbound && [...inbound.files.values()].some((file) => !file.complete)) {
      if (inbound.transferId !== transferId) {
        throw new Error('Aguarde a transferência atual terminar.')
      }
      inbound.remoteAddress = remoteAddress
      const pending = [...inbound.files.values()].filter((file) => !file.complete)
      update({ mode: 'receive', phase: 'receiving', error: '',
        result: '', bytesDone: inbound.bytesDone,
        totalBytes: inbound.totalBytes,
        fileIndex: inbound.files.size - pending.length,
        fileCount: inbound.files.size,
        currentFile: pending[0]?.relativePath || '' })
      return {
        token: inbound.token,
        missing: pending.map((file) => file.id),
        offsets: Object.fromEntries(pending.map((file) => [file.id, file.offset])),
        targetRoot: inbound.targetRoot,
        resumed: true,
      }
    }
    const rootName = safeRootName(manifest.rootName)
    const targetRoot = receiverRoot
    for (const relative of manifest.directories) {
      const directory = resolveInside(targetRoot, relative)
      if (!directory) throw new Error('O manifesto contém uma pasta inválida.')
      await ensureSafeDirectory(targetRoot, directory)
    }
    const token = crypto.randomBytes(32).toString('hex')
    const files = new Map()
    const missing = []
    let totalBytes = 0
    update({ mode: 'receive', phase: 'checking', rootName,
      peerName: String(manifest.senderName || ''),
      destinationPath: receiverRoot, bytesDone: 0,
      totalBytes: Number(manifest.totalBytes) || 0,
      fileIndex: 0, fileCount: manifest.files.length,
      currentFile: '', error: '', result: '' })
    for (let manifestIndex = 0;
      manifestIndex < manifest.files.length; manifestIndex += 1) {
      const raw = manifest.files[manifestIndex]
      const id = String(raw?.id || '')
      const relativePath = safeRelativePath(raw?.relativePath)
      const size = Number(raw?.size)
      if (!/^file-[1-9][0-9]*$/.test(id) || files.has(id) || !relativePath ||
          !Number.isSafeInteger(size) || size < 0) {
        throw new Error('O manifesto contém um arquivo inválido.')
      }
      totalBytes += size
      if (totalBytes > COPY_PROJECT_MAX_TOTAL_BYTES) {
        throw new Error('A transferência excede o limite de 512 GB.')
      }
      let target = resolveInside(targetRoot, relativePath)
      if (!target) throw new Error('O arquivo saiu da pasta de destino.')
      await ensureSafeDirectory(targetRoot, path.dirname(target))
      update({ phase: 'checking', fileIndex: manifestIndex + 1,
        fileCount: manifest.files.length, currentFile: relativePath })
      let complete = false
      const partial = `${target}.vshook-${token.slice(0, 12)}.partial`
      if (!complete && size === 0) {
        await fs.promises.unlink(partial).catch((error) => {
          if (error?.code !== 'ENOENT') throw error
        })
        const handle = await fs.promises.open(partial, 'wx')
        await handle.close()
        await replaceFromPartial(partial, target, token)
        complete = true
      }
      files.set(id, { id, relativePath, size, target, partial,
        offset: complete ? size : 0, complete })
      if (!complete) missing.push(id)
    }
    inbound = {
      token, transferId, remoteAddress, rootName, targetRoot, files,
      totalBytes, bytesDone: totalBytes - missing.reduce((sum, id) =>
        sum + files.get(id).size, 0),
    }
    update({ mode: 'receive', phase: missing.length ? 'receiving' : 'completed',
      rootName, peerName: String(manifest.senderName || ''),
      destinationPath: receiverRoot, totalBytes, bytesDone: inbound.bytesDone,
      fileCount: files.size, fileIndex: files.size - missing.length,
      currentFile: '', error: '',
      result: missing.length ? '' : `Transferência concluída em ${targetRoot}` })
    return { token, missing,
      offsets: Object.fromEntries(missing.map((id) => [id, files.get(id).offset])),
      targetRoot }
  }

  async function handleHttp(req, res) {
    const remoteAddress = normalizeAddress(req.socket.remoteAddress)
    const url = new URL(req.url, 'http://127.0.0.1')
    try {
      if (req.method === 'OPTIONS') {
        res.writeHead(204, {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type, range, x-copy-token, x-copy-file-id, x-copy-offset',
          'access-control-max-age': '600',
        })
        res.end()
        return
      }
      if (req.method === 'GET' &&
          ['/transfer-hook/status', '/copy-project/status'].includes(url.pathname)) {
        const code = safeCode(url.searchParams.get('code'))
        jsonResponse(res, 200, { ok: true, version: COPY_PROJECT_VERSION,
          available: !!receiverCode && code === receiverCode,
          name: String(getDeviceName?.() || os.hostname()) })
        return
      }
      if (req.method === 'GET' && url.pathname === '/transfer-hook/share/status') {
        const code = safeCode(url.searchParams.get('code'))
        jsonResponse(res, 200, { ok: true, version: COPY_PROJECT_VERSION,
          available: !!sharedFolder && code === shareCode,
          preparing: !!shareCode && !sharedFolder && code === shareCode,
          name: String(getDeviceName?.() || os.hostname()) })
        return
      }
      if (req.method === 'GET' && url.pathname === '/transfer-hook/share/manifest') {
        const code = safeCode(url.searchParams.get('code'))
        if (!sharedFolder || code !== shareCode) {
          jsonResponse(res, 403, { ok: false, error: 'Código do Transfer Hook inválido.' })
          return
        }
        jsonResponse(res, 200, { ok: true, schemaVersion: 1,
          rootName: sharedFolder.rootName,
          directories: sharedFolder.directories,
          files: sharedFolder.files.map(({ absolutePath, mtimeMs, ctimeMs, ...file }) => file),
          totalBytes: sharedFolder.totalBytes,
          senderName: String(getDeviceName?.() || os.hostname()).slice(0, 120) })
        return
      }
      if (req.method === 'GET' && url.pathname === '/transfer-hook/share/file') {
        const code = safeCode(url.searchParams.get('code'))
        const id = String(url.searchParams.get('id') || '')
        const file = sharedFolder?.files.find((entry) => entry.id === id)
        if (!sharedFolder || code !== shareCode || !file) {
          jsonResponse(res, 403, { ok: false, error: 'Arquivo ou código inválido.' })
          return
        }
        const stat = await regularFileStat(file.absolutePath, file.size)
        if (stat.mtimeMs !== file.mtimeMs || stat.ctimeMs !== file.ctimeMs) {
          throw new Error(`O arquivo mudou depois de ser disponibilizado: ${file.relativePath}`)
        }
        const rangeMatch = String(req.headers.range || '').match(/^bytes=(\d+)-$/)
        const rangeStart = rangeMatch ? Number(rangeMatch[1]) : 0
        if (!Number.isSafeInteger(rangeStart) || rangeStart < 0 || rangeStart >= file.size && file.size > 0) {
          res.writeHead(416, { 'content-range': `bytes */${file.size}`,
            'access-control-allow-origin': '*' })
          res.end()
          return
        }
        const responseSize = Math.max(0, file.size - rangeStart)
        res.writeHead(rangeStart > 0 ? 206 : 200, {
          'content-type': 'application/octet-stream',
          'content-length': responseSize,
          'accept-ranges': 'bytes',
          ...(rangeStart > 0
            ? { 'content-range': `bytes ${rangeStart}-${file.size - 1}/${file.size}` }
            : {}),
          'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(path.basename(file.relativePath))}`,
          'cache-control': 'no-store',
          'access-control-allow-origin': '*',
          'access-control-expose-headers': 'content-length, content-range, accept-ranges',
        })
        const stream = fs.createReadStream(file.absolutePath,
          rangeStart > 0 ? { start: rangeStart } : undefined)
        stream.once('error', () => res.destroy())
        stream.pipe(res)
        return
      }
      if (req.method === 'POST' &&
          ['/transfer-hook/start', '/copy-project/start'].includes(url.pathname)) {
        const body = await readBody(req, COPY_PROJECT_MAX_MANIFEST_BYTES)
        const manifest = JSON.parse(body.toString('utf8'))
        const prepared = await prepareInbound(manifest, remoteAddress)
        jsonResponse(res, 200, { ok: true, ...prepared })
        return
      }
      if (req.method === 'POST' &&
          ['/transfer-hook/file', '/copy-project/file'].includes(url.pathname)) {
        const token = safeToken(req.headers['x-copy-token'])
        const fileId = String(req.headers['x-copy-file-id'] || '')
        const offset = Number(req.headers['x-copy-offset'])
        if (!inbound || token !== inbound.token ||
            remoteAddress !== inbound.remoteAddress) {
          jsonResponse(res, 403, { ok: false, error: 'Sessão de recebimento inválida.' })
          return
        }
        const file = inbound.files.get(fileId)
        if (!file || file.complete || !Number.isSafeInteger(offset) ||
            offset !== file.offset) {
          jsonResponse(res, 409, { ok: false, error: 'Bloco fora de sequência.' })
          return
        }
        const maximum = Math.min(COPY_PROJECT_CHUNK_BYTES, file.size - offset)
        const body = await readBody(req, maximum)
        if (body.length === 0 && file.size !== 0 ||
            body.length > maximum) {
          throw new Error('Bloco recebido está corrompido.')
        }
        const handle = await fs.promises.open(file.partial, offset === 0 ? 'w' : 'r+')
        try {
          const written = await handle.write(body, 0, body.length, offset)
          if (written.bytesWritten !== body.length) throw new Error('Gravação incompleta.')
        } finally {
          await handle.close()
        }
        file.offset += body.length
        inbound.bytesDone += body.length
        if (file.offset === file.size) {
          await regularFileStat(file.partial, file.size)
          await replaceFromPartial(file.partial, file.target, token)
          file.complete = true
        }
        const completed = [...inbound.files.values()].filter((item) => item.complete).length
        update({ phase: 'receiving', bytesDone: inbound.bytesDone,
          totalBytes: inbound.totalBytes, fileIndex: completed,
          fileCount: inbound.files.size, currentFile: file.relativePath })
        jsonResponse(res, 200, { ok: true, offset: file.offset, complete: file.complete })
        return
      }
      if (req.method === 'POST' &&
          ['/transfer-hook/finish', '/copy-project/finish'].includes(url.pathname)) {
        const body = JSON.parse((await readBody(req, 4096)).toString('utf8'))
        if (!inbound || safeToken(body.token) !== inbound.token ||
            remoteAddress !== inbound.remoteAddress ||
            [...inbound.files.values()].some((file) => !file.complete)) {
          jsonResponse(res, 409, { ok: false, error: 'A transferência ainda não terminou.' })
          return
        }
        const targetRoot = inbound.targetRoot
        update({ phase: 'completed', bytesDone: inbound.totalBytes,
          totalBytes: inbound.totalBytes, fileIndex: inbound.files.size,
          fileCount: inbound.files.size, currentFile: '',
          result: `Pasta recebida em ${targetRoot}`,
          receivedPath: targetRoot })
        jsonResponse(res, 200, { ok: true, targetRoot })
        return
      }
      jsonResponse(res, 404, { ok: false, error: 'Rota Transfer Hook não encontrada.' })
    } catch (error) {
      const interrupted = !!inbound && [...inbound.files.values()]
        .some((file) => !file.complete) &&
        (req.aborted || isRetryableNetworkError(error))
      update(interrupted
        ? { phase: 'paused', error: '', result: '',
            currentFile: 'Rede desconectada. Aguardando reconexão...' }
        : { phase: 'error', error: error?.message || 'Falha ao receber arquivos.' })
      if (!res.headersSent && !res.destroyed) {
        jsonResponse(res, interrupted ? 503 : 400, { ok: false,
          error: interrupted ? 'Transferência pausada aguardando reconexão.'
            : (error?.message || 'Falha na transferência.') })
      }
    }
  }

  async function ensureHttpServer() {
    if (httpServer) return
    httpServer = http.createServer((req, res) => { handleHttp(req, res).catch(() => {}) })
    await new Promise((resolve, reject) => {
      httpServer.once('error', reject)
      httpServer.listen(COPY_PROJECT_HTTP_PORT, '0.0.0.0', () => {
        httpServer.removeListener('error', reject)
        resolve()
      })
    })
  }

  async function startReceiver(destinationPath) {
    const destination = path.resolve(String(destinationPath || ''))
    const stat = await fs.promises.lstat(destination)
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('Escolha uma pasta de destino válida.')
    }
    receiverRoot = destination
    receiverCode = fixedCode
    shareCode = ''
    sharedFolder = null
    await cleanupInboundPartials()
    ++operationGeneration
    await Promise.all([ensureUdp(), ensureHttpServer()])
    if (beaconTimer) clearInterval(beaconTimer)
    beaconTimer = setInterval(() => sendBeacon(), 1000)
    beaconTimer.unref?.()
    sendBeacon()
    return update({ mode: 'receive', phase: 'waiting', code: receiverCode,
      destinationPath: receiverRoot, sourcePath: '', rootName: '', peerName: '',
      bytesDone: 0, totalBytes: 0, fileIndex: 0, fileCount: 0,
      currentFile: '', error: '', result: '', receivedPath: '' })
  }

  async function stopReceiver() {
    receiverCode = ''
    receiverRoot = ''
    await cleanupInboundPartials()
    if (beaconTimer) clearInterval(beaconTimer)
    beaconTimer = null
    ++operationGeneration
    return update({ mode: '', phase: 'idle', code: '', destinationPath: '',
      bytesDone: 0, totalBytes: 0, fileIndex: 0, fileCount: 0,
      currentFile: '', error: '', result: '', receivedPath: '' })
  }

  async function startShare(sourcePath) {
    const sourceRoot = path.resolve(String(sourcePath || ''))
    const sourceStat = await fs.promises.lstat(sourceRoot)
    if ((!sourceStat.isDirectory() && !sourceStat.isFile()) ||
        sourceStat.isSymbolicLink()) {
      throw new Error('Escolha um arquivo ou uma pasta válida para disponibilizar.')
    }
    const generation = ++operationGeneration
    receiverCode = ''
    receiverRoot = ''
    await cleanupInboundPartials()
    if (beaconTimer) clearInterval(beaconTimer)
    beaconTimer = null
    shareCode = fixedCode
    sharedFolder = null
    update({ mode: 'share', phase: 'preparing', code: shareCode, sourcePath: sourceRoot,
      destinationPath: '', rootName: path.basename(sourceRoot), peerName: '',
      bytesDone: 0, totalBytes: 0, fileIndex: 0, fileCount: 0,
      currentFile: 'Preparando os arquivos...', error: '', result: '', receivedPath: '' })
    try {
      await ensureHttpServer()
      const collected = await collectTransferSource(sourceRoot,
        (patch) => update({ ...patch, code: shareCode }),
        () => activeGeneration(generation))
      activeGeneration(generation)
      sharedFolder = {
        rootName: safeRootName(path.basename(sourceRoot)),
        sourceKind: collected.sourceKind,
        files: collected.files,
        directories: collected.directories,
        totalBytes: collected.totalBytes,
      }
      return update({ mode: 'share', phase: 'sharing', code: shareCode,
        sourcePath: sourceRoot, totalBytes: collected.totalBytes,
        bytesDone: 0, fileIndex: 0, fileCount: collected.files.length,
        currentFile: '', error: '',
        result: `${collected.sourceKind === 'file' ? 'Arquivo' : 'Pasta'} disponível para o celular nesta rede local.` })
    } catch (error) {
      if (generation === operationGeneration) {
        shareCode = ''
        sharedFolder = null
        update({ mode: 'share', phase: 'error', code: '',
          currentFile: '', error: error?.message ||
            'Não foi possível disponibilizar os arquivos.' })
      }
      throw error
    }
  }

  async function stopShare() {
    ++operationGeneration
    shareCode = ''
    sharedFolder = null
    return update({ mode: '', phase: 'idle', code: '', sourcePath: '',
      bytesDone: 0, totalBytes: 0, fileIndex: 0, fileCount: 0,
      currentFile: '', error: '', result: '' })
  }

  async function sendFolder(sourcePath, codeValue) {
    const code = safeCode(codeValue)
    if (!code) throw new Error('Digite o código de 6 dígitos do PC receptor.')
    const sourceRoot = path.resolve(String(sourcePath || ''))
    const sourceStat = await fs.promises.lstat(sourceRoot)
    if ((!sourceStat.isDirectory() && !sourceStat.isFile()) ||
        sourceStat.isSymbolicLink()) {
      throw new Error('Escolha um arquivo ou uma pasta válida para enviar.')
    }
    const generation = ++operationGeneration
    update({ mode: 'send', phase: 'discovering', code, sourcePath: sourceRoot,
      destinationPath: '', rootName: path.basename(sourceRoot), peerName: '',
      bytesDone: 0, totalBytes: 0, fileIndex: 0, fileCount: 0,
      currentFile: '', error: '', result: '', receivedPath: '' })
    try {
      let peer = await findReceiver(code, generation)
      activeGeneration(generation)
      update({ phase: 'preparing', peerName: peer.name || peer.address })
      const collected = await collectTransferSource(sourceRoot,
        (patch) => update(patch), () => activeGeneration(generation))
      const transferId = crypto.randomBytes(32).toString('hex')
      const manifest = {
        schemaVersion: 1,
        transferId,
        code,
        rootName: safeRootName(path.basename(sourceRoot)),
        senderName: String(getDeviceName?.() || os.hostname()).slice(0, 120),
        directories: collected.directories,
        files: collected.files.map(({ absolutePath, mtimeMs, ctimeMs, ...file }) => file),
        totalBytes: collected.totalBytes,
      }
      let sessionEstablished = false
      while (true) {
        activeGeneration(generation)
        try {
          if (!peer) peer = await findReceiver(code, generation)
          // A partir daqui o código/receptor já foi localizado. Se a rede cair
          // durante o handshake, a mesma transferência será retomada.
          sessionEstablished = true
          const start = await requestJson({
            hostname: peer.address, port: peer.port,
            path: '/transfer-hook/start', method: 'POST',
          }, manifest, 120000)
          activeGeneration(generation)
          const token = safeToken(start.token)
          const missing = new Set(Array.isArray(start.missing) ? start.missing : [])
          const offsets = start.offsets && typeof start.offsets === 'object'
            ? start.offsets : {}
          if (!token) throw new Error('O PC receptor não criou uma sessão segura.')
          let bytesDone = collected.files.reduce((sum, file) => {
            if (!missing.has(file.id)) return sum + file.size
            const offset = Number(offsets[file.id]) || 0
            return sum + Math.max(0, Math.min(file.size, offset))
          }, 0)
          let transferredFiles = collected.files.length - missing.size
          update({ phase: 'sending', error: '', result: '', bytesDone,
            totalBytes: collected.totalBytes, fileIndex: transferredFiles,
            fileCount: collected.files.length })
          for (const file of collected.files) {
            if (!missing.has(file.id)) continue
            activeGeneration(generation)
            const before = await regularFileStat(file.absolutePath, file.size)
            const handle = await fs.promises.open(file.absolutePath, 'r')
            try {
              let offset = Math.max(0, Math.min(file.size,
                Number(offsets[file.id]) || 0))
              while (offset < file.size) {
                activeGeneration(generation)
                const length = Math.min(COPY_PROJECT_CHUNK_BYTES, file.size - offset)
                const buffer = Buffer.allocUnsafe(length)
                const read = await handle.read(buffer, 0, length, offset)
                if (read.bytesRead !== length) throw new Error(`Leitura incompleta: ${file.relativePath}`)
                await postChunk({ hostname: peer.address, port: peer.port,
                  token, fileId: file.id, offset }, buffer)
                offset += length
                bytesDone += length
                update({ phase: 'sending', bytesDone,
                  totalBytes: collected.totalBytes,
                  fileIndex: transferredFiles + 1,
                  fileCount: collected.files.length,
                  currentFile: file.relativePath })
              }
            } finally {
              await handle.close()
            }
            const after = await regularFileStat(file.absolutePath, file.size)
            if (before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
              throw new Error(`O arquivo mudou durante o envio: ${file.relativePath}`)
            }
            transferredFiles += 1
          }
          const finished = await requestJson({ hostname: peer.address,
            port: peer.port, path: '/transfer-hook/finish', method: 'POST' }, { token })
          activeGeneration(generation)
          return update({ phase: 'completed', bytesDone: collected.totalBytes,
            totalBytes: collected.totalBytes, fileIndex: collected.files.length,
            fileCount: collected.files.length, currentFile: '',
            result: `${collected.files.length} arquivo(s) enviado(s) para ${peer.name || peer.address}.`,
            destinationPath: String(finished.targetRoot || start.targetRoot || '') })
        } catch (error) {
          if (generation !== operationGeneration) return publicState()
          const canResume = sessionEstablished &&
            (isRetryableNetworkError(error) || Number(error?.statusCode) === 409)
          if (!canResume) throw error
          update({ phase: 'paused', error: '', result: '',
            currentFile: 'Rede desconectada. Aguardando reconexão...' })
          discovered.delete(code)
          peer = null
          await waitMs(1000)
        }
      }
    } catch (error) {
      if (generation !== operationGeneration) {
        return publicState()
      }
      update({ phase: 'error', error: error?.message || 'Falha ao enviar os arquivos.' })
      throw error
    }
  }

  async function cancel() {
    ++operationGeneration
    if (state.mode === 'receive') return stopReceiver()
    if (state.mode === 'share') return stopShare()
    return update({ mode: '', phase: 'idle', code: '', bytesDone: 0,
      totalBytes: 0, fileIndex: 0, fileCount: 0, currentFile: '', error: '',
      result: '', receivedPath: '' })
  }

  async function stop() {
    ++operationGeneration
    receiverCode = ''
    receiverRoot = ''
    shareCode = ''
    sharedFolder = null
    await cleanupInboundPartials()
    if (beaconTimer) clearInterval(beaconTimer)
    beaconTimer = null
    if (udpSocket) {
      try { udpSocket.close() } catch (_) {}
      udpSocket = null
    }
    if (httpServer) {
      const server = httpServer
      httpServer = null
      await new Promise((resolve) => server.close(() => resolve()))
    }
  }

  return { getState: publicState, startReceiver, stopReceiver,
    startShare, stopShare, sendFolder, cancel, stop }
}

module.exports = { createCopyProjectService }
