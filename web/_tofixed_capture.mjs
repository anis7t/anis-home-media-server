// Capture JavaScript's toFixed for a compact, committed set of values.
const seeds = [
  0, 1, -1, 0.5, -0.5, 0.125, -0.125, 0.005, -0.005, 0.015, 0.995, 1.005,
  87.475, 87.47499999999999, 12.524999999999998, 0.145, -0.145, 0.615,
  0.0004999999999999999, 0.0005, 99.995, -99.995, 1e-7, -1e-7, 1e-9,
  3.14159265358979, -3.14159265358979, 2.71828182845905, 1 / 3, -1 / 3,
  0.1 + 0.2, 0.3 - 0.1, 1234.5678, -1234.5678, 0.000123456, 9.999999999,
];
let seed = 987654321;
const rnd = () => {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
};
const values = [...seeds];
for (let i = 0; i < 120; i++) {
  const kind = i % 4;
  if (kind === 0) values.push(rnd() * 20 - 10);
  else if (kind === 1) values.push((rnd() * 1e6 - 5e5) / 1000);
  else if (kind === 2) values.push(Math.round(rnd() * 10000) / 100);
  else values.push(rnd() * 1e-6);
}
const out = {};
for (const places of [1, 2, 3, 4]) {
  out[places] = values.map((v) => [v, v.toFixed(places)]);
}
console.log(JSON.stringify(out));
