// Exercise the interpreter paths used by llhttp, tree-sitter, and Yoga.
const assert = require('node:assert/strict');
const leb = value => {
  const bytes = [];
  do { const next = value & 127; value >>>= 7; bytes.push(next | (value ? 128 : 0)); } while (value);
  return bytes;
};
const section = (id, bytes) => [id, ...leb(bytes.length), ...bytes];
const name = text => [...leb(text.length), ...Buffer.from(text)];
const body = instructions => { const bytes = [0, ...instructions, 0x0b]; return [...leb(bytes.length), ...bytes]; };

async function main() {
  assert.equal(typeof WebAssembly, 'object');
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
  console.log('PASS WASM-to-JavaScript callback with compressed pointers');
  const response = await fetch('https://example.com', {signal:AbortSignal.timeout(30000)});
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Example Domain/);
  console.log('PASS built-in Undici HTTPS with certificate verification');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
