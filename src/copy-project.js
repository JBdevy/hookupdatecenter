const fs = require('fs')
const path = require('path')
const os = require('os')
const http = require('http')
const dgram = require('dgram')
const crypto = require('crypto')

const COPY_PROJECT_VERSION = 1
const COPY_PROJECT_HTTP_PORT = 47835
const COPY_PROJECT_DISCOVERY_PORT = 47836
const COPY_PROJECT_MAGIC = 'VS_HOOK_COPY_PROJECT_V1'
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
  return name || 'Copy Project'
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

async function sha256File(filename, expectedSize = -1, onProgress = null) {
  const before = await regularFileStat(filename, expectedSize)
  const hash = crypto.createHash('sha256')
  let bytes = 0
  await new Promise((resolve, reject) => {
    const stream = fs.createReadStream(filename)
    stream.on('data', (chunk) => {
      hash.update(chunk)
      bytes += chunk.length
      if (onProgress) onProgress(chunk.length)
    })
    stream.once('error', reject)
    stream.once('end', resolve)
  })
  const after = await regularFileStat(filename, before.size)
  if (before.size !== after.size || before.mtimeMs !== after.mtimeMs ||
      before.ctimeMs !== after.ctimeMs || bytes !== before.size) {
    throw new Error(`O arquivo mudou durante a leitura: ${path.basename(filename)}`)
  }
  return hash.digest('hex')
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
          reject(new Error(data?.error || `Falha de rede (${res.statusCode}).`))
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
      path: '/copy-project/file',
      method: 'POST',
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': buffer.length,
        'x-copy-token': options.token,
        'x-copy-file-id': options.fileId,
        'x-copy-offset': String(options.offset),
        'x-copy-chunk-sha256': crypto.createHash('sha256')
          .update(buffer).digest('hex'),
      },
    }, (res) => {
      const chunks = []
      res.on('data', (chunk) => chunks.push(chunk))
      res.on('end', () => {
        let data = null
        try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch (_) {}
        if (res.statusCode < 200 || res.statusCode >= 300 || !data?.ok) {
          reject(new Error(data?.error || `Falha ao enviar bloco (${res.statusCode}).`))
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
          sha256: '',
        })
      }
    }
  }
  await walk(sourceRoot, '')
  let hashedBytes = 0
  for (let index = 0; index < files.length; index += 1) {
    isActive()
    const file = files[index]
    file.sha256 = await sha256File(file.absolutePath, file.size, (amount) => {
      hashedBytes += amount
      update({ phase: 'preparing', bytesDone: hashedBytes,
        totalBytes, fileIndex: index + 1, fileCount: files.length,
        currentFile: file.relativePath })
    })
  }
  return { files, directories, totalBytes }
}

function createCopyProjectService({ getDeviceName, onState } = {}) {
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
  let operationGeneration = 0
  const discovered = new Map()

  function publicState() {
    return { ...state, receiving: !!receiverCode, protocolVersion: COPY_PROJECT_VERSION }
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

  async function uniqueConflictPath(target) {
    const extension = path.extname(target)
    const base = target.slice(0, target.length - extension.length)
    for (let index = 1; index <= 9999; index += 1) {
      const candidate = `${base} (recebido ${index})${extension}`
      try { await fs.promises.lstat(candidate) } catch (error) {
        if (error?.code === 'ENOENT') return candidate
        throw error
      }
    }
    throw new Error('Não foi possível criar um nome livre no destino.')
  }

  async function prepareInbound(manifest, remoteAddress) {
    if (!receiverCode || !receiverRoot) throw new Error('O recebimento não está ativo.')
    if (inbound && [...inbound.files.values()].some((file) => !file.complete)) {
      throw new Error('Aguarde a transferência atual terminar.')
    }
    if (!manifest || manifest.schemaVersion !== 1 ||
        safeCode(manifest.code) !== receiverCode ||
        !Array.isArray(manifest.files) || !Array.isArray(manifest.directories) ||
        manifest.files.length > COPY_PROJECT_MAX_FILES) {
      throw new Error('Manifesto de transferência inválido.')
    }
    const rootName = safeRootName(manifest.rootName)
    const targetRoot = path.join(receiverRoot, rootName)
    await ensureSafeDirectory(receiverRoot, targetRoot)
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
      const sha256 = safeToken(raw?.sha256)
      if (!/^file-[1-9][0-9]*$/.test(id) || files.has(id) || !relativePath ||
          !Number.isSafeInteger(size) || size < 0 || !sha256) {
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
      try {
        const stat = await regularFileStat(target)
        if (stat.size === size && await sha256File(target, size) === sha256) {
          complete = true
        } else {
          target = await uniqueConflictPath(target)
        }
      } catch (error) {
        if (error?.code !== 'ENOENT' &&
            error?.message !== 'Arquivo ausente, alterado ou inseguro.') throw error
        if (error?.message === 'Arquivo ausente, alterado ou inseguro.') {
          throw error
        }
      }
      if (!complete && size === 0) {
        const handle = await fs.promises.open(target, 'wx')
        await handle.close()
        complete = true
      }
      const partial = `${target}.vshook-${token.slice(0, 12)}.partial`
      files.set(id, { id, relativePath, size, sha256, target, partial,
        offset: complete ? size : 0, complete })
      if (!complete) missing.push(id)
    }
    inbound = {
      token, remoteAddress, rootName, targetRoot, files,
      totalBytes, bytesDone: totalBytes - missing.reduce((sum, id) =>
        sum + files.get(id).size, 0),
    }
    update({ mode: 'receive', phase: missing.length ? 'receiving' : 'completed',
      rootName, peerName: String(manifest.senderName || ''),
      destinationPath: receiverRoot, totalBytes, bytesDone: inbound.bytesDone,
      fileCount: files.size, fileIndex: files.size - missing.length,
      currentFile: '', error: '',
      result: missing.length ? '' : `Todos os arquivos já existiam em ${targetRoot}` })
    return { token, missing, targetRoot }
  }

  async function handleHttp(req, res) {
    const remoteAddress = normalizeAddress(req.socket.remoteAddress)
    const url = new URL(req.url, 'http://127.0.0.1')
    try {
      if (req.method === 'GET' && url.pathname === '/copy-project/status') {
        const code = safeCode(url.searchParams.get('code'))
        jsonResponse(res, 200, { ok: true, version: COPY_PROJECT_VERSION,
          available: !!receiverCode && code === receiverCode,
          name: String(getDeviceName?.() || os.hostname()) })
        return
      }
      if (req.method === 'POST' && url.pathname === '/copy-project/start') {
        const body = await readBody(req, COPY_PROJECT_MAX_MANIFEST_BYTES)
        const manifest = JSON.parse(body.toString('utf8'))
        const prepared = await prepareInbound(manifest, remoteAddress)
        jsonResponse(res, 200, { ok: true, ...prepared })
        return
      }
      if (req.method === 'POST' && url.pathname === '/copy-project/file') {
        const token = safeToken(req.headers['x-copy-token'])
        const fileId = String(req.headers['x-copy-file-id'] || '')
        const offset = Number(req.headers['x-copy-offset'])
        const chunkSha = safeToken(req.headers['x-copy-chunk-sha256'])
        if (!inbound || token !== inbound.token ||
            remoteAddress !== inbound.remoteAddress) {
          jsonResponse(res, 403, { ok: false, error: 'Sessão de recebimento inválida.' })
          return
        }
        const file = inbound.files.get(fileId)
        if (!file || file.complete || !Number.isSafeInteger(offset) ||
            offset !== file.offset || !chunkSha) {
          jsonResponse(res, 409, { ok: false, error: 'Bloco fora de sequência.' })
          return
        }
        const maximum = Math.min(COPY_PROJECT_CHUNK_BYTES, file.size - offset)
        const body = await readBody(req, maximum)
        if (body.length === 0 && file.size !== 0 ||
            body.length > maximum ||
            crypto.createHash('sha256').update(body).digest('hex') !== chunkSha) {
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
          if (await sha256File(file.partial, file.size) !== file.sha256) {
            await fs.promises.unlink(file.partial).catch(() => {})
            file.offset = 0
            throw new Error(`SHA-256 inválido: ${file.relativePath}`)
          }
          try { await fs.promises.lstat(file.target); file.target = await uniqueConflictPath(file.target) } catch (error) {
            if (error?.code !== 'ENOENT') throw error
          }
          await fs.promises.rename(file.partial, file.target)
          file.complete = true
        }
        const completed = [...inbound.files.values()].filter((item) => item.complete).length
        update({ phase: 'receiving', bytesDone: inbound.bytesDone,
          totalBytes: inbound.totalBytes, fileIndex: completed,
          fileCount: inbound.files.size, currentFile: file.relativePath })
        jsonResponse(res, 200, { ok: true, offset: file.offset, complete: file.complete })
        return
      }
      if (req.method === 'POST' && url.pathname === '/copy-project/finish') {
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
        inbound = null
        jsonResponse(res, 200, { ok: true, targetRoot })
        return
      }
      jsonResponse(res, 404, { ok: false, error: 'Rota Copy Project não encontrada.' })
    } catch (error) {
      update({ phase: 'error', error: error?.message || 'Falha ao receber arquivos.' })
      jsonResponse(res, 400, { ok: false, error: error?.message || 'Falha na transferência.' })
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
    receiverCode = randomCode()
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

  async function sendFolder(sourcePath, codeValue) {
    const code = safeCode(codeValue)
    if (!code) throw new Error('Digite o código de 6 dígitos do PC receptor.')
    const sourceRoot = path.resolve(String(sourcePath || ''))
    const sourceStat = await fs.promises.lstat(sourceRoot)
    if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink()) {
      throw new Error('Escolha uma pasta válida para enviar.')
    }
    const generation = ++operationGeneration
    update({ mode: 'send', phase: 'discovering', code, sourcePath: sourceRoot,
      destinationPath: '', rootName: path.basename(sourceRoot), peerName: '',
      bytesDone: 0, totalBytes: 0, fileIndex: 0, fileCount: 0,
      currentFile: '', error: '', result: '', receivedPath: '' })
    try {
      const peer = await findReceiver(code, generation)
      activeGeneration(generation)
      update({ phase: 'preparing', peerName: peer.name || peer.address })
      const collected = await collectFolder(sourceRoot,
        (patch) => update(patch), () => activeGeneration(generation))
      const manifest = {
        schemaVersion: 1,
        code,
        rootName: safeRootName(path.basename(sourceRoot)),
        senderName: String(getDeviceName?.() || os.hostname()).slice(0, 120),
        directories: collected.directories,
        files: collected.files.map(({ absolutePath, mtimeMs, ...file }) => file),
        totalBytes: collected.totalBytes,
      }
      const start = await requestJson({
        hostname: peer.address, port: peer.port,
        path: '/copy-project/start', method: 'POST',
      }, manifest, 120000)
      activeGeneration(generation)
      const token = safeToken(start.token)
      const missing = new Set(Array.isArray(start.missing) ? start.missing : [])
      if (!token) throw new Error('O PC receptor não criou uma sessão segura.')
      const transferTotal = collected.files
        .filter((file) => missing.has(file.id))
        .reduce((sum, file) => sum + file.size, 0)
      let bytesDone = 0
      let transferredFiles = 0
      update({ phase: 'sending', bytesDone: 0, totalBytes: transferTotal,
        fileIndex: 0, fileCount: missing.size })
      for (const file of collected.files) {
        if (!missing.has(file.id)) continue
        activeGeneration(generation)
        const before = await regularFileStat(file.absolutePath, file.size)
        const handle = await fs.promises.open(file.absolutePath, 'r')
        try {
          let offset = 0
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
            update({ phase: 'sending', bytesDone, totalBytes: transferTotal,
              fileIndex: transferredFiles + 1, fileCount: missing.size,
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
        port: peer.port, path: '/copy-project/finish', method: 'POST' }, { token })
      activeGeneration(generation)
      return update({ phase: 'completed', bytesDone: transferTotal,
        totalBytes: transferTotal, fileIndex: missing.size,
        fileCount: missing.size, currentFile: '',
        result: missing.size
          ? `${missing.size} arquivo(s) enviado(s) para ${peer.name || peer.address}.`
          : 'Nenhum arquivo precisou ser enviado; todos já existiam no destino.',
        destinationPath: String(finished.targetRoot || '') })
    } catch (error) {
      if (generation !== operationGeneration) {
        return publicState()
      }
      update({ phase: 'error', error: error?.message || 'Falha ao enviar a pasta.' })
      throw error
    }
  }

  async function cancel() {
    ++operationGeneration
    if (state.mode === 'receive') return stopReceiver()
    return update({ mode: '', phase: 'idle', code: '', bytesDone: 0,
      totalBytes: 0, fileIndex: 0, fileCount: 0, currentFile: '', error: '',
      result: '', receivedPath: '' })
  }

  async function stop() {
    ++operationGeneration
    receiverCode = ''
    receiverRoot = ''
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
    sendFolder, cancel, stop }
}

module.exports = { createCopyProjectService }
