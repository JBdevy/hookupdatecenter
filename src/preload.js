const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('hookUpdateCenter', {
  getState: () => ipcRenderer.invoke('get-state'),
  checkUpdates: () => ipcRenderer.invoke('check-updates'),
  downloadUpdate: (payload) => ipcRenderer.invoke('download-update', payload),
  getPreviousUpdates: () => ipcRenderer.invoke('get-previous-updates'),
  installUpdate: () => ipcRenderer.invoke('install-update'),
  checkHookCenterUpdate: () => ipcRenderer.invoke('check-hook-center-update'),
  installHookCenterUpdate: () => ipcRenderer.invoke('install-hook-center-update'),
  activateLicense: (payload) => ipcRenderer.invoke('activate-license', payload),
  checkLicenseStatus: () => ipcRenderer.invoke('check-license-status'),
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  openSupport: () => ipcRenderer.invoke('open-support'),
  getBridgeState: () => ipcRenderer.invoke('get-bridge-state'),
  restartBridge: () => ipcRenderer.invoke('restart-bridge'),
  onUpdateStatus: (callback) => ipcRenderer.on('update-status', (_event, data) => callback(data)),
  onLicenseStatus: (callback) => ipcRenderer.on('license-status', (_event, data) => callback(data)),
  onBridgeStatus: (callback) => ipcRenderer.on('bridge-status', (_event, data) => callback(data)),
  onUpdateError: (callback) => ipcRenderer.on('update-error', (_event, message) => callback(message)),
  onDownloadProgress: (callback) => ipcRenderer.on('download-progress', (_event, progress) => callback(progress))
});
