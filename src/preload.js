const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('hookUpdateCenter', {
  getState: () => ipcRenderer.invoke('get-state'),
  checkUpdates: () => ipcRenderer.invoke('check-updates'),
  downloadUpdate: () => ipcRenderer.invoke('download-update'),
  installUpdate: () => ipcRenderer.invoke('install-update'),
  activateLicense: (payload) => ipcRenderer.invoke('activate-license', payload),
  checkLicenseStatus: () => ipcRenderer.invoke('check-license-status'),
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  openSupport: () => ipcRenderer.invoke('open-support'),
  onUpdateStatus: (callback) => ipcRenderer.on('update-status', (_event, data) => callback(data)),
  onLicenseStatus: (callback) => ipcRenderer.on('license-status', (_event, data) => callback(data)),
  onUpdateError: (callback) => ipcRenderer.on('update-error', (_event, message) => callback(message)),
  onDownloadProgress: (callback) => ipcRenderer.on('download-progress', (_event, progress) => callback(progress))
});
