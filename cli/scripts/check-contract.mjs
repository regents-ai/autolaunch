import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
// Each reviewed copy the CLI ships, beside the platform contract it is copied from.
for (const name of ["api-contract.openapiv3.yaml", "covered-calls.openapiv3.yaml"]) {
  const copy = await readFile(new URL(`../docs/${name}`, import.meta.url));
  const source = await readFile(new URL(`../../platform/contracts/${name}`, import.meta.url));
  assert.deepEqual(copy, source, `Refresh the CLI's reviewed copy of ${name} from the owning platform contract.`);
}
console.log("CLI API copies match the product contracts.");
