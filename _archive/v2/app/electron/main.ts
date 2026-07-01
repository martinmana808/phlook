import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'path';

process.env.DIST = path.join(__dirname, '../dist');
process.env.PUBLIC = app.isPackaged ? process.env.DIST : path.join(__dirname, '../public');

let win: BrowserWindow | null;
const VITE_DEV_SERVER_URL = process.env['VITE_DEV_SERVER_URL'];

function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
    titleBarStyle: 'hiddenInset', // Mac-like feel
    vibrancy: 'under-window',     // Mac blur effect
    visualEffectState: 'active',
  });

  if (VITE_DEV_SERVER_URL) {
    win.loadURL(VITE_DEV_SERVER_URL);
  } else {
    win.loadFile(path.join(process.env.DIST || path.join(__dirname, '../dist'), 'index.html'));
  }

  // Open the DevTools.
  // win.webContents.openDevTools();
}

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.whenReady().then(() => {
  const { protocol } = require('electron');
  protocol.registerFileProtocol('phlook', (request: any, callback: any) => {
    const url = request.url.replace('phlook://', '');
    try {
      return callback(decodeURIComponent(url));
    } catch (error) {
      console.error(error);
      return callback('404');
    }
  });

  createWindow();

  // IPC Handlers
  ipcMain.handle('ping', () => 'pong');

  ipcMain.handle('scan-directory', async (_event, scanPath: string) => {
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
        .filter((dirent: any) => dirent.isFile() && VALID_EXTENSIONS.has(path.extname(dirent.name).toLowerCase()))
        .map((dirent: any) => ({
          name: dirent.name,
          path: path.join(dirent.parentPath || targetPath, dirent.name), // parentPath is available in recent Node
          relativePath: 'TODO' // simplified for now
        }));
    } catch (error) {
       console.error("Scan failed:", error);
       return [];
    }
  });

  ipcMain.handle('get-thumbnail', async (_event, filePath: string) => {
    const sharp = require('sharp');
    try {
      const buffer = await sharp(filePath)
        .resize(300, 300, { fit: 'cover' })
        .jpeg({ quality: 80 })
        .toBuffer();
      return `data:image/jpeg;base64,${buffer.toString('base64')}`;
    } catch (error) {
      console.error(`Failed to generate thumbnail for ${filePath}:`, error);
      return null;
    }
  });
});
