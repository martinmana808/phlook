"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const electron_1 = require("electron");
const path_1 = __importDefault(require("path"));
process.env.DIST = path_1.default.join(__dirname, '../dist');
process.env.PUBLIC = electron_1.app.isPackaged ? process.env.DIST : path_1.default.join(__dirname, '../public');
let win;
const VITE_DEV_SERVER_URL = process.env['VITE_DEV_SERVER_URL'];
function createWindow() {
    win = new electron_1.BrowserWindow({
        width: 1200,
        height: 800,
        webPreferences: {
            preload: path_1.default.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true,
        },
        titleBarStyle: 'hiddenInset', // Mac-like feel
        vibrancy: 'under-window', // Mac blur effect
        visualEffectState: 'active',
    });
    if (VITE_DEV_SERVER_URL) {
        win.loadURL(VITE_DEV_SERVER_URL);
    }
    else {
        win.loadFile(path_1.default.join(process.env.DIST || path_1.default.join(__dirname, '../dist'), 'index.html'));
    }
    // Open the DevTools.
    // win.webContents.openDevTools();
}
electron_1.app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        electron_1.app.quit();
    }
});
electron_1.app.whenReady().then(() => {
    const { protocol } = require('electron');
    protocol.registerFileProtocol('phlook', (request, callback) => {
        const url = request.url.replace('phlook://', '');
        try {
            return callback(decodeURIComponent(url));
        }
        catch (error) {
            console.error(error);
            return callback('404');
        }
    });
    createWindow();
    // IPC Handlers
    electron_1.ipcMain.handle('ping', () => 'pong');
    electron_1.ipcMain.handle('scan-directory', async (_event, scanPath) => {
        const fs = require('fs/promises');
        const path = require('path');
        const os = require('os');
        // Default to Pictures if no path provided
        const targetPath = scanPath || path.join(os.homedir(), 'Pictures');
        try {
            console.log(`Scanning: ${targetPath}`);
            // Recursive read (Node 20+ feature, Electron 33 supports it)
            const files = await fs.readdir(targetPath, { recursive: true, withFileTypes: true });
            const VALID_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.heic', '.mov', '.mp4']);
            return files
                .filter((dirent) => dirent.isFile() && VALID_EXTENSIONS.has(path.extname(dirent.name).toLowerCase()))
                .map((dirent) => ({
                name: dirent.name,
                path: path.join(dirent.parentPath || targetPath, dirent.name), // parentPath is available in recent Node
                relativePath: 'TODO' // simplified for now
            }));
        }
        catch (error) {
            console.error("Scan failed:", error);
            return [];
        }
    });
    electron_1.ipcMain.handle('get-thumbnail', async (_event, filePath) => {
        const sharp = require('sharp');
        try {
            const buffer = await sharp(filePath)
                .resize(300, 300, { fit: 'cover' })
                .jpeg({ quality: 80 })
                .toBuffer();
            return `data:image/jpeg;base64,${buffer.toString('base64')}`;
        }
        catch (error) {
            console.error(`Failed to generate thumbnail for ${filePath}:`, error);
            return null;
        }
    });
});
