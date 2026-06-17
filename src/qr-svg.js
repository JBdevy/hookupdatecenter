const QRCode = require('./vendor/QRCode')
const QRErrorCorrectLevel = require('./vendor/QRCode/QRErrorCorrectLevel')

function escapeXml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function createQrSvg(text, options = {}) {
  const value = String(text || '').trim() || 'VS Hook'
  const margin = Number.isFinite(Number(options.margin)) ? Math.max(0, Math.floor(Number(options.margin))) : 4
  const scale = Number.isFinite(Number(options.scale)) ? Math.max(2, Math.floor(Number(options.scale))) : 8

  const qr = new QRCode(-1, QRErrorCorrectLevel.M)
  qr.addData(value)
  qr.make()

  const count = qr.getModuleCount()
  const size = (count + margin * 2) * scale
  const rects = []

  for (let row = 0; row < count; row += 1) {
    let start = -1
    for (let col = 0; col <= count; col += 1) {
      const dark = col < count && qr.isDark(row, col)
      if (dark && start < 0) start = col
      if ((!dark || col === count) && start >= 0) {
        const x = (start + margin) * scale
        const y = (row + margin) * scale
        const w = (col - start) * scale
        rects.push(`<rect x="${x}" y="${y}" width="${w}" height="${scale}"/>`)
        start = -1
      }
    }
  }

  return `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" role="img" aria-label="QR Code">` +
    `<title>${escapeXml(value)}</title>` +
    `<rect width="100%" height="100%" fill="#ffffff"/>` +
    `<g fill="#000000">${rects.join('')}</g>` +
    `</svg>`
}

module.exports = { createQrSvg }
