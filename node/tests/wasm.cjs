// Exercise the interpreter paths used by llhttp, tree-sitter, and Yoga.
const assert = require('node:assert/strict');
const leb = value => {
  const bytes = [];
  do { const next = value & 127; value >>>= 7; bytes.push(next | (value ? 128 : 0)); } while (value);
  return bytes;
};
const section = (id, bytes) => [id, ...leb(bytes.length), ...bytes];
const name = text => [...leb(text.length), ...Buffer.from(text)];
const body = (instructions, locals = [0]) => { const bytes = [...locals, ...instructions, 0x0b]; return [...leb(bytes.length), ...bytes]; };

async function main() {
  assert.equal(typeof WebAssembly, 'object');
  // A truncated Smi makes both exports call function zero. The second export
  // also exercises the ARM64 wrapper's result count for a JS callback.
  const indices = new Uint8Array([
    0,97,115,109,1,0,0,0,
    ...section(1,[2,0x60,0,2,0x7f,0x7f,0x60,0,1,0x7f]),
    ...section(2,[1,...name('env'),...name('pair'),0,0]),
    ...section(3,[2,1,1]),
    ...section(7,[2,...name('first'),0,1,...name('sum'),0,2]),
    ...section(10,[2,...body([0x41,7]),...body([0x10,0,0x6a])]),
  ]);
  const functions = (await WebAssembly.instantiate(indices,{env:{pair:()=>[19,23]}})).instance.exports;
  assert.equal(functions.first(),7);
  assert.equal(functions.sum(),42);
  console.log('PASS distinct WASM exports and multi-value JS callback');
  // memory.init copies passive data, data.drop prevents another nonempty copy.
  const bytes = new Uint8Array([
    0,97,115,109,1,0,0,0,
    ...section(1, [1,0x60,0,0]),
    ...section(3, [2,0,0]),
    ...section(5, [1,0,1]),
    ...section(7, [3,...name('memory'),2,0,...name('init'),0,0,...name('drop'),0,1]),
    ...section(12, [1]),
    ...section(10, [2,...body([0x41,0,0x41,0,0x41,3,0xfc,8,0,0]),...body([0xfc,9,0])]),
    ...section(11, [1,1,3,65,66,67]),
  ]);
  for (let n = 0; n < 3; ++n) {
    const { instance } = await WebAssembly.instantiate(bytes);
    instance.exports.init();
    assert.deepEqual([...new Uint8Array(instance.exports.memory.buffer,0,3)], [65,66,67]);
    instance.exports.drop();
    assert.throws(() => instance.exports.init(), WebAssembly.RuntimeError);
  }
  console.log('PASS WASM passive data, memory.init, data.drop, bounds trap, repeated instantiation');
  const callbackModule = new Uint8Array([
    0,97,115,109,1,0,0,0,
    ...section(1,[1,0x60,1,0x7f,1,0x7f]),
    ...section(2,[1,...name('env'),...name('id'),0,0]),
    ...section(3,[1,0]),
    ...section(7,[1,...name('call'),0,1]),
    ...section(10,[1,...body([0x20,0,0x10,0])]),
  ]);
  const callback = await WebAssembly.instantiate(callbackModule,{env:{id:value=>value+1}});
  assert.equal(callback.instance.exports.call(41),42);
  console.log('PASS WASM-to-JavaScript callback');
  // Keep the same JS object through an imported function, a Wasm GC struct,
  // and a mutable reference array. Truncating a full-width pointer breaks this.
  const externref = 0x6f;
  const refs = new Uint8Array([
    0,97,115,109,1,0,0,0,
    ...section(1,[4, 0x5f,1,externref,1, 0x5e,externref,1,
      0x60,1,externref,1,externref, 0x60,1,0x7f,1,0x7f]),
    ...section(2,[1,...name('env'),...name('id'),0,2]),
    ...section(3,[3,2,2,3]),
    ...section(7,[3,...name('struct'),0,1,...name('fill'),0,2,...name('signed'),0,3]),
    ...section(10,[3,
      ...body([0x20,0,0x10,0,0xfb,0,0,0xfb,2,0,0]),
      // local 1 holds the array. Fill only its second element, then read it.
      ...body([0x41,2,0xfb,7,1,0x22,1,0x41,1,0x20,0,0x41,1,0xfb,16,1,
        0x20,1,0x41,1,0xfb,11,1], [1,1,0x63,1]),
      ...body([0x20,0,0xfb,0x1c,0xfb,0x1d])]),
  ]);
  const {instance:{exports}} = await WebAssembly.instantiate(refs, {env:{id:value=>value}});
  for (const value of [null, {answer:42}]) {
    assert.equal(exports.struct(value), value);
    assert.equal(exports.fill(value), value);
  }
  assert.equal(exports.signed(0x7fffffff), -1);
  console.log('PASS WASM reference fields, array fill, JS reference returns and signed i31');
  const response = await fetch('https://example.com', {signal:AbortSignal.timeout(30000)});
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Example Domain/);
  console.log('PASS built-in Undici HTTPS with certificate verification');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
