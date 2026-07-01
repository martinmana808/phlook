"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const electron_1 = require("electron");
electron_1.contextBridge.exposeInMainWorld('electron', {
    ping: () => electron_1.ipcRenderer.invoke('ping'),
    scanDirectory: (path) => electron_1.ipcRenderer.invoke('scan-directory', path),
    getThumbnail: (path) => electron_1.ipcRenderer.invoke('get-thumbnail', path),
});
