const { app, BrowserWindow, dialog, ipcMain } = require('electron');
const fs = require('fs');
const http = require('http');
const path = require('path');

let settingsWindow = null;
let recadosWindow = null;
let bridgeMonitor = null;
let bridgeWasConnected = false;
let bridgeMisses = 0;
let bridgeCheckInFlight = false;
const recadosImageExtensions = new Set([
  '.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'
]);

function normalizedRecadosSlot(value) {
  const slot = Number(value);
  return Number.isInteger(slot) && slot >= 0 && slot <= 2
    ? slot
    : -1;
}

function recadosImagesDirectory() {
  return path.join(app.getPath('userData'), 'recados-images');
}

function isStoredRecadosImage(filePath, slot = -1) {
  if (!filePath) return false;
  const resolved = path.resolve(String(filePath));
  const directory = path.resolve(recadosImagesDirectory());
  if (path.dirname(resolved) !== directory) return false;
  if (slot < 0) return true;
  return path.basename(resolved).startsWith(`recado-${slot + 1}-`);
}

async function cleanupRecadosImages(slot, keepPath = '') {
  const normalizedSlot = normalizedRecadosSlot(slot);
  if (normalizedSlot < 0) {
    return { ok: false, error: 'Recado inválido.' };
  }
  const directory = recadosImagesDirectory();
  const keep = isStoredRecadosImage(keepPath, normalizedSlot)
    ? path.resolve(keepPath)
    : '';
  await fs.promises.mkdir(directory, { recursive: true });
  const files = await fs.promises.readdir(directory);
  const prefix = `recado-${normalizedSlot + 1}-`;
  await Promise.all(files
    .filter((name) => name.startsWith(prefix))
    .map(async (name) => {
      const candidate = path.resolve(directory, name);
      if (candidate === keep) return;
      await fs.promises.unlink(candidate).catch(() => {});
    }));
  return { ok: true };
}

ipcMain.handle('recados:choose-image', async (_event, slot) => {
  const normalizedSlot = normalizedRecadosSlot(slot);
  if (normalizedSlot < 0) {
    return { ok: false, error: 'Selecione o Recado 1, 2 ou 3.' };
  }
  const options = {
    title: `Escolher imagem do Recado ${normalizedSlot + 1}`,
    properties: ['openFile'],
    filters: [
      {
        name: 'Imagens',
        extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp']
      }
    ]
  };
  const result = recadosWindow && !recadosWindow.isDestroyed()
    ? await dialog.showOpenDialog(recadosWindow, options)
    : await dialog.showOpenDialog(options);
  if (result.canceled || !result.filePaths?.[0]) {
    return { ok: true, cancelled: true };
  }
  const sourcePath = path.resolve(result.filePaths[0]);
  const extension = path.extname(sourcePath).toLowerCase();
  if (!recadosImageExtensions.has(extension)) {
    return { ok: false, error: 'Escolha apenas um arquivo de imagem.' };
  }
  const sourceInfo = await fs.promises.stat(sourcePath).catch(() => null);
  if (!sourceInfo?.isFile()) {
    return { ok: false, error: 'A imagem selecionada não foi encontrada.' };
  }
  const directory = recadosImagesDirectory();
  await fs.promises.mkdir(directory, { recursive: true });
  const destinationPath = path.join(
    directory,
    `recado-${normalizedSlot + 1}-${Date.now()}${extension}`
  );
  await fs.promises.copyFile(sourcePath, destinationPath);
  return {
    ok: true,
    cancelled: false,
    path: destinationPath,
    name: path.basename(sourcePath)
  };
});

ipcMain.handle(
  'recados:cleanup-images',
  async (_event, slot, keepPath) => {
    try {
      return await cleanupRecadosImages(slot, keepPath);
    } catch (error) {
      return {
        ok: false,
        error: String(error?.message || 'Não foi possível atualizar a imagem.')
      };
    }
  }
);

function hasOpenWindow() {
  return Boolean(
    (settingsWindow && !settingsWindow.isDestroyed()) ||
    (recadosWindow && !recadosWindow.isDestroyed())
  );
}

function checkReaperBridge() {
  if (bridgeCheckInFlight) return;
  bridgeCheckInFlight = true;
  const finishCheck = () => {
    bridgeCheckInFlight = false;
  };
  const request = http.get(
    'http://127.0.0.1:47830/health',
    { timeout: 3000 },
    (response) => {
      response.resume();
      response.once('end', finishCheck);
      response.once('close', finishCheck);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        bridgeWasConnected = true;
        bridgeMisses = 0;
        return;
      }
      bridgeMisses += 1;
    }
  );
  request.on('timeout', () => {
    finishCheck();
    request.destroy();
  });
  request.on('error', () => {
    finishCheck();
    if (!bridgeWasConnected) return;
    bridgeMisses += 1;
    if (bridgeMisses >= 5) {
      if (settingsWindow && !settingsWindow.isDestroyed()) {
        settingsWindow.close();
      }
      if (recadosWindow && !recadosWindow.isDestroyed()) {
        recadosWindow.close();
      }
    }
  });
}

function startBridgeMonitor() {
  clearInterval(bridgeMonitor);
  bridgeWasConnected = false;
  bridgeMisses = 0;
  bridgeCheckInFlight = false;
  checkReaperBridge();
  bridgeMonitor = setInterval(checkReaperBridge, 1000);
}

function createSettingsWindow() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    if (settingsWindow.isMinimized()) settingsWindow.restore();
    settingsWindow.show();
    settingsWindow.focus();
    return settingsWindow;
  }
  settingsWindow = new BrowserWindow({
    width: 980,
    height: 700,
    minWidth: 480,
    minHeight: 360,
    useContentSize: true,
    backgroundColor: '#080d15',
    title: 'VS Hook - Configurações do Teleprompt',
    icon: path.join(__dirname, 'build', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  settingsWindow.loadFile(path.join(__dirname, 'settings.html'));
  startBridgeMonitor();
  settingsWindow.on('closed', () => {
    settingsWindow = null;
    if (!hasOpenWindow()) {
      clearInterval(bridgeMonitor);
      bridgeMonitor = null;
    }
  });
  return settingsWindow;
}

function createRecadosWindow() {
  if (recadosWindow && !recadosWindow.isDestroyed()) {
    if (recadosWindow.isMinimized()) recadosWindow.restore();
    recadosWindow.show();
    recadosWindow.focus();
    return recadosWindow;
  }
  recadosWindow = new BrowserWindow({
    width: 520,
    height: 800,
    minWidth: 420,
    minHeight: 620,
    useContentSize: true,
    backgroundColor: '#05070a',
    title: 'VS Hook - Recados',
    icon: path.join(__dirname, 'build', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  recadosWindow.loadFile(path.join(__dirname, 'recados.html'));
  startBridgeMonitor();
  recadosWindow.on('closed', () => {
    recadosWindow = null;
    if (!hasOpenWindow()) {
      clearInterval(bridgeMonitor);
      bridgeMonitor = null;
    }
  });
  return recadosWindow;
}

function wantsRecados(argv = process.argv) {
  return Array.isArray(argv) && argv.some(
    (value) => String(value || '').toLowerCase() === '--recados'
  );
}

function showRequestedWindow(argv = process.argv) {
  if (wantsRecados(argv)) return createRecadosWindow();
  return createSettingsWindow();
}

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => {
    showRequestedWindow(argv);
  });
  app.whenReady().then(() => showRequestedWindow(process.argv));
}

app.on('window-all-closed', () => app.quit());
