export {};

declare global {
  interface Window {
    electron: {
      ping: () => Promise<string>;
      scanDirectory: (path?: string) => Promise<Array<{ name: string; path: string; relativePath: string }>>;
      getThumbnail: (path: string) => Promise<string | null>;
    };
  }
}
