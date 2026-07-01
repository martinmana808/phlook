import { useState, useEffect } from 'react'
import { Thumbnail } from './components/Thumbnail'
import './App.css'

interface FileItem {
  name: string;
  path: string;
  relativePath: string;
}

function App() {
  const [files, setFiles] = useState<FileItem[]>([]);

  useEffect(() => {
    const scan = async () => {
      console.log("Scanning...");
      try {
        const result = await window.electron.scanDirectory();
        console.log("Found:", result.length);
        setFiles(result);
      } catch (e) {
        console.error("Scan failed", e);
      }
    };
    scan();
  }, []);

  return (
    <div className="container">
      <h1>Phlook MVP</h1>
      <p>Found {files.length} items</p>
      <div className="grid">
        {files.slice(0, 100).map((file) => (
          <div key={file.path} className="item">
            <Thumbnail path={file.path} name={file.name} />
            <span className="caption">{file.name}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

export default App
