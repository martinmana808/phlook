import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electron', {
  ping: () => ipcRenderer.invoke('ping'),
  scanDirectory: (path: string) => ipcRenderer.invoke('scan-directory', path),
  getThumbnail: (path: string) => ipcRenderer.invoke('get-thumbnail', path),
});
