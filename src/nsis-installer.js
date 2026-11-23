const fs = require('node:fs');

const blockSize = 512;
const headerSize = 28;
const signature = Buffer.from('\xef\xbe\xad\xdeNullsoftInst', 'latin1');
const crcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  }
  return value;
});

async function readFully(file, buffer, length, position) {
  let offset = 0;
  while (offset < length) {
    const { bytesRead } = await file.read(buffer, offset, length - offset, position + offset);
    if (!bytesRead) break;
    offset += bytesRead;
  }
  return offset;
}

async function readNsisHeader(file, size) {
  const buffer = Buffer.allocUnsafe(64 * 1024);
  for (let start = 0; start < size; start += buffer.length) {
    const length = await readFully(file, buffer, Math.min(buffer.length, size - start), start);
    if (start === 0 && (length < 2 || buffer.readUInt16LE(0) !== 0x5a4d)) break;
    for (let offset = 0; offset + headerSize <= length; offset += blockSize) {
      const flags = buffer.readUInt32LE(offset);
      if (flags <= 15 && buffer.subarray(offset + 4, offset + 20).equals(signature)) {
        return { flags, start: start + offset, length: buffer.readUInt32LE(offset + 24) };
      }
    }
  }
  throw new Error('O arquivo baixado não contém um instalador válido do Hook Center. Baixe novamente.');
}

async function validateNsisInstaller(filename, size) {
  const file = await fs.promises.open(filename, 'r');
  try {
    const header = await readNsisHeader(file, size);
    const end = header.start + header.length;
    // NSIS permits signing data after its payload and excludes the first 512 bytes from CRC.
    const hasCrc = (header.flags & 8) !== 0 || (header.flags & 4) === 0;
    if (end > size || header.length < headerSize + (hasCrc ? 4 : 0)) {
      throw new Error('O instalador do Hook Center está incompleto. Baixe novamente.');
    }
    if (!hasCrc) return;

    const checksumOffset = end - 4;
    let crc = 0xffffffff;
    const stream = file.createReadStream({ start: blockSize, end: checksumOffset - 1, autoClose: false });
    for await (const chunk of stream) {
      for (let index = 0; index < chunk.length; index += 1) {
        crc = crcTable[(crc ^ chunk[index]) & 0xff] ^ (crc >>> 8);
      }
    }
    const expected = Buffer.alloc(4);
    if (await readFully(file, expected, expected.length, checksumOffset) !== expected.length ||
        ((crc ^ 0xffffffff) >>> 0) !== expected.readUInt32LE(0)) {
      throw new Error('O instalador do Hook Center falhou na verificação de integridade. Baixe novamente.');
    }
  } finally {
    await file.close();
  }
}

module.exports = { validateNsisInstaller };
