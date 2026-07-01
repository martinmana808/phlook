import { useState, useEffect } from 'react';

interface ThumbnailProps {
  path: string;
  name: string;
}

export const Thumbnail = ({ path, name }: ThumbnailProps) => {
  const [src, setSrc] = useState<string>(''); // Start empty
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    
    // Simple intersection observer behavior can be mimicked by just fetching on mount
    // For a list of 100, this is fine. For 1000s we need virtualization.
    
    const load = async () => {
      // Small delay to allow initial layout
      try {
        const thumb = await window.electron.getThumbnail(path);
        if (active && thumb) {
          setSrc(thumb);
        } else if (active) {
            // Fallback to full load if thumb fails (or placeholder)
             setSrc(`phlook://${path}`);
        }
      } catch (e) {
          console.error(e);
      } finally {
        if (active) setLoading(false);
      }
    };

    load();

    return () => { active = false; };
  }, [path]);

  return (
    <div className="thumbnail-container">
        {loading && <div className="skeleton" />}
        {src && <img src={src} alt={name} className={loading ? 'hidden' : 'visible'} />}
    </div>
  );
};
