import { generateKBSync } from './storeAgent';

self.onmessage = async (event) => {
  try {
    const [commerceKit, commerceCore, coreFP, coreFPICXS, storeAgent, wasm] = event.data.resources as ArrayBuffer[];
    const blob = await generateKBSync({
      commerceKit: new Uint8Array(commerceKit), commerceCore: new Uint8Array(commerceCore),
      coreFP: new Uint8Array(coreFP), coreFPICXS: new Uint8Array(coreFPICXS), storeAgent: new Uint8Array(storeAgent),
    }, new Uint8Array(event.data.hardware), event.data.dsid, { wasmBinary: wasm });
    const buffer = blob.slice().buffer;
    self.postMessage({ type: 'result', blob: buffer }, { transfer: [buffer] });
  } catch (error) {
    self.postMessage({ type: 'error', message: error instanceof Error ? error.message : 'Interpreter failed' });
  }
};
