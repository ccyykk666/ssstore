// The bundled page only moves data; expensive work runs in a dedicated worker,
// matching AssppWeb. Only GUID and DSID enter this local interpreter.
function notify(value: Record<string, unknown>): void {
  (window as any).webkit.messageHandlers.kbsync.postMessage(value);
}
let runningWorker: Worker | undefined;
(window as any).ssstoreCancel = () => runningWorker?.terminate();
(window as any).ssstoreGenerate = (guid: string, dsid: string, diagnostic = false): string => {
  void (async () => {
    let workerURL: string | undefined;
    try {
      const account = Number(dsid);
      if (!/^[0-9a-fA-F]{12}$/.test(guid) || !Number.isSafeInteger(account) || account <= 0) {
        throw new Error('Invalid kbsync identity');
      }
      notify({ type: 'phase', phase: 'resources' });
      const resources: ArrayBuffer[] = [];
      for (const name of ['CommerceKit', 'CommerceCore', 'CoreFP', 'CoreFP.icxs', 'storeagent', 'unicorn.wasm']) {
        const response = await fetch(name);
        if (!response.ok) throw new Error('Missing bundled kbsync resource');
        resources.push(await response.arrayBuffer());
      }
      const sourceResponse = await fetch('worker.js');
      if (!sourceResponse.ok) throw new Error('Missing interpreter worker');
      workerURL = URL.createObjectURL(new Blob([await sourceResponse.text()], { type: 'application/javascript' }));
      const worker = new Worker(workerURL);
      runningWorker = worker;
      const hardware = Uint8Array.from(guid.match(/../g)!, (byte) => parseInt(byte, 16));
      notify({ type: 'phase', phase: 'engine' });
      const blob = await new Promise<ArrayBuffer>((resolve, reject) => {
        worker.onmessage = (event) => {
          if (event.data.type === 'result') resolve(event.data.blob);
          else reject(new Error(event.data.message ?? 'Interpreter failed'));
        };
        worker.onerror = () => reject(new Error('Interpreter worker failed'));
        worker.postMessage({ resources, hardware: hardware.buffer, dsid: account }, [...resources, hardware.buffer]);
      });
      const bytes = new Uint8Array(blob);
      if (bytes.length === 0 || bytes.length > 1024 * 1024) throw new Error('Invalid kbsync output');
      let binary = '';
      for (const byte of bytes) binary += String.fromCharCode(byte);
      notify({ type: 'result', blob: btoa(binary) });
    } catch (error) {
      notify({ type: 'error', message: diagnostic && error instanceof Error ? error.message : undefined });
    } finally {
      runningWorker?.terminate();
      runningWorker = undefined;
      if (workerURL) URL.revokeObjectURL(workerURL);
    }
  })();
  return 'started';
};
notify({ type: 'ready' });
