import { generateKBSync } from './storeAgent';

// This local interpreter receives only GUID and DSID, never account credentials.
function notify(value: Record<string, unknown>): void {
  (window as any).webkit.messageHandlers.kbsync.postMessage(value);
}
(window as any).ssstoreGenerate = (guid: string, dsid: string): string => {
  void (async () => {
    try {
      const account = Number(dsid);
      if (!/^[0-9a-fA-F]{12}$/.test(guid) || !Number.isSafeInteger(account) || account <= 0) {
        throw new Error('Invalid kbsync identity');
      }
      notify({ type: 'phase', phase: 'resources' });
      const resources: Uint8Array[] = [];
      for (const name of ['CommerceKit', 'CommerceCore', 'CoreFP', 'CoreFP.icxs', 'storeagent', 'unicorn.wasm']) {
        const response = await fetch(name);
        if (!response.ok) throw new Error('Missing bundled kbsync resource');
        resources.push(new Uint8Array(await response.arrayBuffer()));
      }
      const [commerceKit, commerceCore, coreFP, coreFPICXS, storeAgent, wasm] = resources;
      const hardware = Uint8Array.from(guid.match(/../g)!, (byte) => parseInt(byte, 16));
      notify({ type: 'phase', phase: 'engine' });
      const blob = await generateKBSync({ commerceKit, commerceCore, coreFP, coreFPICXS, storeAgent },
        hardware, account, { wasmBinary: wasm.buffer as ArrayBuffer });
      if (blob.length === 0 || blob.length > 1024 * 1024) throw new Error('Invalid kbsync output');
      let binary = '';
      for (const byte of blob) binary += String.fromCharCode(byte);
      notify({ type: 'result', blob: btoa(binary) });
    } catch {
      notify({ type: 'error' });
    }
  })();
  return 'started';
};
notify({ type: 'ready' });
