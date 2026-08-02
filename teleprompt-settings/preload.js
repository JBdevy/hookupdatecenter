const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('vsHookRecados', {
  chooseImage(slot) {
    return ipcRenderer.invoke('recados:choose-image', Number(slot));
  },
  cleanupImages(slot, keepPath = '') {
    return ipcRenderer.invoke(
      'recados:cleanup-images',
      Number(slot),
      String(keepPath || '')
    );
  }
});
